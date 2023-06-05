[CmdletBinding()]
param (
    [Parameter()]
    [ValidateRange(1, 59)]
    [int]$WaitForSourceTimeoutMinutes = 30,

    # In case the downloader is called by the main script,
    # this parameter points to the thread safe object to
    # notify download completion.
    [Parameter()]
    [hashtable]$Messenger
)

#requires -RunAsAdministrator

$ErrorActionPreference = 'SilentlyContinue'

enum AbortReason {
    ConfigImport
    Downloading
    InstallPending
    RebootPending
    DownloaderGetInstallerMetadata
    DownloaderDestination
    FileHashNotMatch
    DownloadedFileNotFound
    SourcePathWaitTimeout
}

#region Functions
function Write-Log {

    [CmdletBinding()]
    param (

        [Parameter(
            Position = 0,
            ValueFromPipeline = $false,
            ValueFromPipelineByPropertyName = $false,
            HelpMessage = 'Log file full name.'
        )]
        [ValidateNotNullOrEmpty()]
        [string]$Path = "$PSScriptRoot\Log-$($MyInvocation.MyCommand.Name)-$(Get-Date -Format 'yyyyMMdd-hhmmss').log",

        [Parameter(
            Mandatory,
            Position = 1,
            HelpMessage = 'The log message.')]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter(
            Mandatory,
            Position = 2,
            HelpMessage = 'The log level. Informational, Warning or Error.')]
        [LogLevel]$Level = [LogLevel]::Informational,

        [Parameter(
            Position = 3,
            HelpMessage = 'The component logging the information.')]
        [string]$Component = $MyInvocation.InvocationName

    )

    enum LogLevel {
        Informational = 1
        Warning = 2
        Error = 3
    }

    $logText = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="{4}" type="{5}" thread="{6}" file="{7}:{8}">'
    $context = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $thread = [Threading.Thread]::CurrentThread.ManagedThreadId
    $time = [datetime]::Now.ToString('HH:mm:ss.ffff', [System.Globalization.CultureInfo]::InvariantCulture)
    $date = [datetime]::Now.ToString('MM-dd-yyyy', [System.Globalization.CultureInfo]::InvariantCulture)

    $content = [string]::Format($logText, $Message, $time, $date, $Component, $context, $Level.value__, $thread, $MyInvocation.ScriptName, $MyInvocation.ScriptLineNumber)

    try {
        Add-Content -Path $Path -Value $content -Force -ErrorAction Stop
    }
    catch {
        Start-Sleep -Milliseconds 700
        Add-Content -Path $Path -Value $content -Force
    }

}

# Function to make log invocation using the least parameter number as possible, and including verbose.
function Invoke-CMCHWriteLog {

    [CmdletBinding(DefaultParameterSetName = 'write_error')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet('Informational', 'Warning', 'Error')]
        [string]$Level = 'Informational',

        [Parameter()]
        [string]$Path = $Global:cmch_downloader_log
    )

    # Managing console output.
    switch ($Level) {
        'Informational' {
            if ($PSCmdlet.MyInvocation.BoundParameters.Verbose.IsPresent) {
                Write-Verbose $Message
            }
        }
        Default { Write-Warning $Message }
    }

    # Managing file size.
    $log_file_size = (Get-ChildItem -Path $Global:cmch_downloader_log).Length
    switch ($Global:cmch_config.Log.SizeUnit) {
        1 { $max_file_size = $Global:cmch_config.Log.MaxLogFileSize * 1Mb }
        Default { $max_file_size = $Global:cmch_config.Log.MaxLogFileSize * 1Kb }
    }
    if ($log_file_size -gt $max_file_size) {
        $log_file_base_name = [System.IO.Path]::GetFileNameWithoutExtension($Global:cmch_downloader_log)
        Rename-Item -Path $Global:cmch_downloader_log -NewName "$log_file_base_name-$([datetime]::Now.ToString('yyyyMMdd-HHmmss')).log" -Force
    }

    # Writting log to file.
    Write-Log -Path $Path -Message $Message -Level $Level
}

function Write-ErrorRecord([ref]$error_record) {
    Invoke-CMCHWriteLog "(0x$('{0:X}' -f $error_record.Value.Exception.HResult)) $($error_record.Value.Exception.Message)." Error
}
#endregion

#region Importing config
$Global:cmch_registry_location = 'HKLM:\SOFTWARE\ConfigMgrClientDeviceMonitor\'
if (Test-Path -Path "$PSSCriptRoot\appsettings.jsonc" -PathType Leaf) {
    try {
        $Global:cmch_config = Get-Content -Path "$PSSCriptRoot\appsettings.jsonc" -Raw | ConvertFrom-Json -ErrorAction Stop
        $Global:cmch_log_file_path = $Global:cmch_config.Log.DownloaderPath
    }
    catch {
        $Global:cmch_log_file_path = "$PSScriptRoot\ConfigMgrClientDeviceMonitor-Downloader.log"
        Invoke-CMCHWriteLog 'Failed importing configuration from file.' Error
        Write-ErrorRecord([ref]$_)
        Set-ItemProperty -Path $Global:cmch_registry_location -Name 'AbortReason' -Value ([AbortReason]::ConfigImport)
        exit ([AbortReason]::ConfigImport.value__)
    }
}

try {
    
    $registry_info = Get-ItemProperty -Path $Global:cmch_registry_location -ErrorAction Stop
}
catch {
    Invoke-CMCHWriteLog 'Failed importing information from the registry. Cannot continue.' Error
    Write-ErrorRecord([ref]$_)
    exit -1
}


# Aborting if the retry number is expired.
if ($Global:cmch_config.Client.DownloadRetries -gt [int]$registry_info.DownloadAttempts) {
    Invoke-CMCHWriteLog 'Download attempts exceeds the maximum required. Disabling download.' Error
    Set-ItemProperty -Path $Global:cmch_registry_location -Name 'DisableDownload' -Value 1
    Unregister-ScheduledTask -TaskName 'Config Manager Client Device Monitor - Downloader' -Confirm:$false
    exit -1
}
#endregion

#region Initial setup
Invoke-CMCHWriteLog 'Importing external resources.'
Add-Type -Path "$PSSCriptRoot\bin\Windows.Utilities.dll"
Import-Module -Name 'BitsTransfer'
#endregion

#region Collecting registry information
Invoke-CMCHWriteLog 'Getting the installer metadata file path.'
try {
    $file_metadata_path = $registry_info.InstallerFileMetadata
    if (!$file_metadata_path) {
        Invoke-CMCHWriteLog 'Failed to get installer file metadata path from the registry.' Error
        Set-ItemProperty -Path $Global:cmch_registry_location -Name 'AbortReason' -Value ([AbortReason]::DownloaderGetInstallerMetadata)
        exit ([AbortReason]::DownloaderGetInstallerMetadata.value__)
    }
}
catch {
    Invoke-CMCHWriteLog 'Failed to get installer file metadata path from the registry.' Error
    Write-ErrorRecord([ref]$_)
    Set-ItemProperty -Path $Global:cmch_registry_location -Name 'AbortReason' -Value ([AbortReason]::DownloaderGetInstallerMetadata)
    exit ([AbortReason]::DownloaderGetInstallerMetadata.value__)
}
#endregion

#region Inventory
# Importing metadata.
Invoke-CMCHWriteLog 'Importing installer file metadata.'
try {
    $installer_metadata = Get-Content -Path $file_metadata_path -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction Stop
    $destination = $registry_info.InstallerDestinationFolder
    Invoke-CMCHWriteLog "Download destination path is '$destination'."
}
catch {
    Invoke-CMCHWriteLog 'Failed to import installer file metadata.' Error
    Write-ErrorRecord([ref]$_)
    Set-ItemProperty -Path $Global:cmch_registry_location -Name 'AbortReason' -Value ([AbortReason]::DownloaderGetInstallerMetadata)
    exit ([AbortReason]::DownloaderGetInstallerMetadata.value__)
}

# Checking connection with source.
$source_root = [Windows.Utilities.FileSystem.Path]::GetpathCommonRoot($installer_metadata.FullName)
if (!(Test-Path -Path $source_root)) {
    Invoke-CMCHWriteLog "Source path not accessible. trying $WaitForSourceTimeoutMinutes more times." Error
}
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
while (!(Test-Path -Path $source_root)) {
    Start-Sleep -Seconds 60
    if ($stopwatch.Elapsed.TotalMinutes -gt $WaitForSourceTimeoutMinutes) {
        Invoke-CMCHWriteLog 'Timed out waiting the source path to be available. Ending execution.' Error
        Set-ItemProperty -Path $Global:cmch_registry_location -Name 'AbortReason' -Value ([AbortReason]::SourcePathWaitTimeout)
        exit ([AbortReason]::SourcePathWaitTimeout.value__)
    }
}
$stopwatch.Stop()

# Listing files already downloaded.
Set-ItemProperty -Path $Global:cmch_registry_location -Name 'IsDownloadComplete' -Value $false

Invoke-CMCHWriteLog 'Checking if there are files in the destination.'
if (!(Test-Path -Path $destination)) {
    Invoke-CMCHWriteLog "destination folder does not exist. Creating. '$destination'." Warning
    try {
        [void](mkdir $destination -Force -ErrorAction Stop)
    }
    catch {
        Invoke-CMCHWriteLog "Failed creating destination directory '$destination'." Error
        Write-ErrorRecord([ref]$_)
        Set-ItemProperty -Path $Global:cmch_registry_location -Name 'AbortReason' -Value ([AbortReason]::DownloaderDestination)
        exit ([AbortReason]::DownloaderDestination.value__)
    }
}
else {
    Invoke-CMCHWriteLog 'Validating existing files.'
    [System.Collections.ArrayList]$valid_local_file_list = @()
    $current_files = Get-ChildItem -Path $destination -Recurse -Force -File
    foreach ($file in $current_files) {
        $remote_data = $installer_metadata.Where({ [System.IO.Path]::GetFileName($_.FullName) -eq [System.IO.Path]::GetFileName($file.FullName) })
        if ($remote_data) {
            $current_hash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash
            if ($current_hash -eq $remote_data.SHA256Hash) {
                [void]$valid_local_file_list.Add($remote_data)
                Invoke-CMCHWriteLog "Hash for file '$($file.Name)' matches with metadata. Excluding from download job."
            }
            else {
                Invoke-CMCHWriteLog "Hash for file '$($file.Name)' is NOT a match! Deleting file." Warning
                Remove-Item -Path $file.FullName -Force
            }
        }
    }
}
#endregion

#region Download
Invoke-CMCHWriteLog 'Starting download job.'
$files_to_download = $installer_metadata.Where({ $_.FullName -notin $valid_local_file_list.FullName })
foreach ($file in $files_to_download) {
    if (!(Test-Path -Path $file.DestinationPath)) {
        [void](mkdir $file.DestinationPath -Force)
    }
    try {
        # Start-BitsTransfer -Source $file.FullName -Destination $file.DestinationPath -ErrorAction Stop
        # Invoke-CMCHWriteLog "Downloaded file '$($file.FullName)'."

        # TODO:
        #   BITS is more involving than just calling 'Start-BitsTransfer' (very useful).
        #   Using the download mode with 'Copy-Item defeats the purpose, because the installer
        #   will copy the files anyways.
        #   
        #   Use either a BITS or download implementation.
        Copy-Item -Path $file.FullName -Destination $file.DestinationPath -Force
    }
    catch {
        Invoke-CMCHWriteLog "Failed to download file '$($file.FullName)'." Error
        Write-ErrorRecord([ref]$_)
    }
}
#endregion

#region Verifying download
Invoke-CMCHWriteLog 'Verifying download integrity.'
$is_download_complete = $true
foreach ($file in $installer_metadata) {
    $local_file = Get-ChildItem -Path $file.DestinationPath
    if ($local_file) {
        if ((Get-FileHash -Path $local_file -Algorithm SHA256).Hash -eq $file.SHA256) {
            Invoke-CMCHWriteLog "File '$($local_file.FullName)' consistent."
        }
        else {
            Invoke-CMCHWriteLog "File is NOT a match for file '$($local_file.FullName)' Halting execution." Error
            Set-ItemProperty -Path $Global:cmch_registry_location -Name 'AbortReason' -Value ([AbortReason]::FileHashNotMatch)
            exit ([AbortReason]::FileHashNotMatch.value__)
        }
    }
    else {
        Invoke-CMCHWriteLog "File '$($file.DestinationPath)' not found. Halting execution."
        Set-ItemProperty -Path $Global:cmch_registry_location -Name 'AbortReason' -Value ([AbortReason]::DownloadedFileNotFound)
        exit ([AbortReason]::DownloadedFileNotFound.value__)
    }
}
#endregion

#region Closing up
if ($is_download_complete) {
    Invoke-CMCHWriteLog 'Downloaded finished successfully. Cleaning up.'
    Set-ItemProperty -Path $Global:cmch_registry_location -Name 'IsDownloadComplete' -Value $true
    Set-ItemProperty -Path $Global:cmch_registry_location -Name 'AbortReason' -Value ([AbortReason]::InstallPending.ToString())
    Unregister-ScheduledTask -TaskName 'Config Manager Client Device Monitor - Downloader' -Confirm:$false
    if ($Messenger) {
        $Messenger.DownloadComplete = $true
    }
}
#endregion