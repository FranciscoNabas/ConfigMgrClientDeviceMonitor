[CmdletBinding()]
param ()

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
    FalseProceedWithInstall
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
        [string]$Path = $Global:cmch_log_file_path
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
    $log_file_size = (Get-ChildItem -Path $Global:cmch_log_file_path).Length
    switch ($Global:cmch_config.Log.SizeUnit) {
        1 { $max_file_size = $Global:cmch_config.Log.MaxLogFileSize * 1Mb }
        Default { $max_file_size = $Global:cmch_config.Log.MaxLogFileSize * 1Kb }
    }
    if ($log_file_size -gt $max_file_size) {
        $log_file_base_name = [System.IO.Path]::GetFileNameWithoutExtension($Global:cmch_log_file_path)
        Rename-Item -Path $Global:cmch_log_file_path -NewName "$log_file_base_name-$([datetime]::Now.ToString('yyyyMMdd-HHmmss')).log" -Force
    }

    # Writting log to file.
    Write-Log -Path $Path -Message $Message -Level $Level
}

function Write-ErrorRecord([ref]$error_record) {
    Invoke-CMCHWriteLog "0x($('{0:X}' -f $error_record.Value.Exception.HResult)) $($error_record.Value.Exception.Message)." Error
}

function New-ClientInstallAfterRebootTask {

    Unregister-ScheduledTask -TaskName 'Config Manager Client Device Monitor - Client Install' -Confirm:$false -ErrorAction SilentlyContinue

    [System.Collections.ArrayList]$disposables = @()
    $scheduler = New-Object -ComObject 'Schedule.Service'
    [void]$disposables.Add($scheduler)
    try {
        $scheduler.Connect()
        $root = $scheduler.GetFolder('\')
        [void]$disposables.Add($root)

        $definition = $scheduler.NewTask(0)
        [void]$disposables.Add($root)
        
        $definition.Principal.UserId = 'NT AUTHORITY\SYSTEM'
        $definition.Principal.LogonType = 5
        $definition.Principal.RunLevel = 1

        $definition.Settings.AllowDemandStart = $true
        $definition.Settings.StartWhenAvailable = $true
        $definition.Settings.DisallowStartIfOnBatteries = $false
        $definition.Settings.DisallowStartOnRemoteAppSession = $false
        $definition.Settings.StopIfGoingOnBatteries = $false
        
        $registration_trigger = $definition.Triggers.Create(7)
        [void]$disposables.Add($registration_trigger)
        $registration_trigger.Delay = 'PT1H'
        $registration_trigger.Repetition.Interval = 'PT1H'
        $registration_trigger.Repetition.Duration = 'PT1H'

        $logon_trigger = $definition.Triggers.Create(9)
        [void]$disposables.Add($logon_trigger)
        $logon_trigger.Delay = 'PT15M'
        $logon_trigger.Repetition.Interval = 'PT1H'
        $logon_trigger.Repetition.Duration = 'PT1H'

        $action = $definition.Actions.Create(0)
        $action.Path = 'powershell.exe'
        $action.Arguments = "-ExecutionPolicy Bypass -File ""$PSScriptRoot\Installer.ps1"""

        [void]$root.RegisterTaskDefinition('Config Manager Client Device Monitor - Client Install', $definition, 6, $null, $null, 5)
    }
    catch {
        Invoke-CMCHWriteLog 'Error creating the downloader scheduled task.' Error
        Write-ErrorRecord([ref]$_)
    }
    finally {
        foreach ($object in $disposables) {
            try {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($object)
            }
            catch { }
        }
    }
}
#endregion 

#region Import config
if (Test-Path -Path "$PSSCriptRoot\appsettings.jsonc" -PathType Leaf) {
    try {
        $Global:cmch_config = Get-Content -Path "$PSSCriptRoot\appsettings.jsonc" -Raw | ConvertFrom-Json -ErrorAction Stop
        $Global:cmch_log_file_path = $Global:cmch_config.Log.Installer
        $is_config = $true
    }
    catch {
        $Global:cmch_log_file_path = "$PSSCriptRoot\Logs\Installer.log"
        Invoke-CMCHWriteLog 'Error importing config.' Error
        Write-ErrorRecord([ref]$_)
        $is_config = $false
    }
}

Invoke-CMCHWriteLog 'Importing registry settings.'
$Global:cmcg_registry_path = 'HKLM:\SOFTWARE\ConfigMgrClientDeviceMonitor'
try {
    $app_information = Get-ItemProperty -Path $Global:cmcg_registry_path -ErrorAction Stop
}
catch {
    Invoke-CMCHWriteLog 'Failed to import registry settings. Execution cannot continue.' Error
    Write-ErrorRecord([ref]$_)
}

$abort_reason_list = @(
    [AbortReason]::DownloadedFileNotFound
    [AbortReason]::DownloaderDestination
    [AbortReason]::DownloaderGetInstallerMetadata
    [AbortReason]::Downloading
    [AbortReason]::FalseProceedWithInstall
    [AbortReason]::FileHashNotMatch
    [AbortReason]::SourcePathWaitTimeout
    [AbortReason]::RebootPending
)

if ($app_information.AbortReason -in $abort_reason_list) {
    Invoke-CMCHWriteLog "Current abort state triggers an abort. '$(([AbortReason]$app_information.AbortReason).ToString())'." Warning
        
    # ERROR_OPERATION_ABORTED
    exit 995
}

if ($is_config) {
    $config_share = $Global:cmch_config.Client.Share
    $config_source_param = $Global:cmch_config.Client.InstallParameters.'/source'
}
#endregion

#region Managing retries
Invoke-CMCHWriteLog 'Managing retries.'
if (!$app_information.InstallRetryNumber -or $app_information.InstallRetryNumber -eq 0) {
    Set-ItemProperty -Path $Global:cmcg_registry_path -Name 'InstallRetryNumber' -Value 1
    Invoke-CMCHWriteLog 'Installation running for the first time.'
}
else {
    $current_retry_number = $app_information.InstallRetryNumber++
    if ($current_retry_number -gt $Global:cmch_config.Client.InstallRetries) {
        Invoke-CMCHWriteLog "Installation attempts exceeds the maximum required of $($Global:cmch_config.Client.InstallRetries). Aborting installation permanently." Error
        
        # Setting installation completion to true so the main script can run its registry cleanup, and start all over.
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\ConfigMgrClientDeviceMonitor' -Name 'IsInstallationComplete' -Value $true -Force

        # Removing the retry task, if existent.
        Unregister-ScheduledTask -TaskName 'Config Manager Client Device Monitor - Client Install' -Confirm:$false

        exit -1
    }
    else {
        Invoke-CMCHWriteLog "Installation attempt number $current_retry_number."
    }
}
#endregion

#region Installer setup
Invoke-CMCHWriteLog 'Validating installation parameters.'
if (![string]::IsNullOrEmpty($app_information.InstallerParameters)) {
    $installer_parameters = $app_information.InstallerParameters
    Invoke-CMCHWriteLog 'Using parameters from the registry.'
}
else {
    if ($is_config) {
        Invoke-CMCHWriteLog 'Using parameters from config.'
        $installer_parameters = ''
        foreach ($parameter in $Global:cmch_config.Client.InstallParameters.PSObject.Properties) {
            if ($parameter.Name -like '/*') {
                if (![string]::IsNullOrEmpty($parameter.Value)) {
                    $installer_parameters += [string]::Join(':', @($parameter.Name, "$($parameter.Value) "))
                }
            }
            else {
                if (![string]::IsNullOrEmpty($parameter.Value)) {
                    $installer_parameters += [string]::Join('=', @($parameter.Name, "$($parameter.Value) "))
                }
            }
        }
    }
    else {
        Invoke-CMCHWriteLog "No parameters found. Installing only with '/forceinstall'." Warning
    }
}

# Trying to get installer path.
Invoke-CMCHWriteLog 'Trying to get installer path.'
$try_from_config = $false
if (![string]::IsNullOrEmpty($app_information.InstallerLocation) -or ![string]::IsNullOrEmpty($app_information.ClientShareLocation)) {
    if (![string]::IsNullOrEmpty($app_information.InstallerLocation)) {
        if (!(Test-Path -Path "$($app_information.InstallerLocation)\ccmsetup.exe" -PathType Leaf)) {
            Invoke-CMCHWriteLog "Installer file not found. '$($app_information.InstallerLocation)'." Error

            if (!(Test-Path -Path "$($app_information.ClientShareLocation)\ccmsetup.exe" -PathType Leaf)) {
                Invoke-CMCHWriteLog "Client share installer not found. '$($app_information.InstallerLocation)'." Error
                $try_from_config = $true
            }
            else {
                $ccmsetup_file = "$($app_information.ClientShareLocation)\ccmsetup.exe"
                Invoke-CMCHWriteLog "Installing from '$($app_information.ClientShareLocation)'."
            }
        }
        else {
            $ccmsetup_file = "$($app_information.InstallerLocation)\ccmsetup.exe"
            Invoke-CMCHWriteLog "Installing from '$($app_information.InstallerLocation)'."
        }
    }
    else {
        if (!(Test-Path -Path "$($app_information.ClientShareLocation)\ccmsetup.exe" -PathType Leaf)) {
            Invoke-CMCHWriteLog "Client share installer not found. '$($app_information.InstallerLocation)'." Error
            $try_from_config = $true
        }
        else {
            $ccmsetup_file = "$($app_information.ClientShareLocation)\ccmsetup.exe"
            Invoke-CMCHWriteLog "Installing from '$($app_information.ClientShareLocation)'."
        }
    }
}
else {
    $try_from_config = $true
}

if ($try_from_config) {
    if ([string]::IsNullOrEmpty($config_share) -and [string]::IsNullOrEmpty($config_source_param)) {
        Invoke-CMCHWriteLog 'Cannot find installer from registry or config file. Cannot continue.' Error
        
        # ERROR_FILE_NOT_FOUND
        exit 2
    }
    else {
        if (![string]::IsNullOrEmpty($config_share)) {
            if (!(Test-Path -Path "$config_share\ccmsetup.exe" -PathType Leaf)) {
                Invoke-CMCHWriteLog 'Installer not found on client share.' Error
    
                if (!(Test-Path -Path "$config_source_param\ccmsetup.exe" -PathType Leaf)) {
                    Invoke-CMCHWriteLog 'Cannot find installer from registry or config file. Cannot continue.' Error
            
                    # ERROR_FILE_NOT_FOUND
                    exit 2
                }
                else {
                    $ccmsetup_file = "$config_source_param\ccmsetup.exe"
                    Invoke-CMCHWriteLog "Installing from '$config_source_param'."
                }
            }
            else {
                $ccmsetup_file = "$config_share\ccmsetup.exe"
                Invoke-CMCHWriteLog "Installing from '$config_share'."
            }
        }
        else {
            if (!(Test-Path -Path "$config_source_param\ccmsetup.exe" -PathType Leaf)) {
                Invoke-CMCHWriteLog 'Cannot find installer from registry or config file. Cannot continue.' Error
        
                # ERROR_FILE_NOT_FOUND
                exit 2
            }
            else {
                $ccmsetup_file = "$config_source_param\ccmsetup.exe"
                Invoke-CMCHWriteLog "Installing from '$config_source_param'."
            }
        }
    }
}

if ([string]::IsNullOrEmpty($ccmsetup_file)) {
    Invoke-CMCHWriteLog 'Cannot find installer from registry or config file. Cannot continue.' Error
        
    # ERROR_FILE_NOT_FOUND
    exit 2
}
#endregion

#region Test / wait for installer availability
if (!(Test-Path -Path $ccmsetup_file)) {
    Invoke-CMCHWriteLog "Cannot reach path '$ccmsetup_file'. Retrying every minute, for $($Global:cmch_config.Client.WaitForShareTime) minutes." Error
    
    $timeout = $false
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 60

        if ($stopwatch.Elapsed.TotalMinutes -ge $Global:cmch_config.Client.WaitForShareTime) {
            $timeout = $true
            break
        }

    } while (!(Test-Path -Path $ccmsetup_file))
    $stopwatch.Stop()

    if ($timeout) {
        Invoke-CMCHWriteLog 'Timed out waiting for path to be available. Creating installation scheduled task.' Error
        New-ClientInstallAfterRebootTask

        #WAIT_TIMEOUT
        exit 258
    }
}
#endregion

#region Installing
if ([string]::IsNullOrEmpty($installer_parameters)) {
    $proc_splat = @{
        FilePath = $ccmsetup_file
        ArgumentList = '/forceinstall'
        NoNewWindow = $true
        Wait = $true
    }
}
else {
    $proc_splat = @{
        FilePath = $ccmsetup_file
        ArgumentList = "$installer_parameters /forceinstall"
        NoNewWindow = $true
        Wait = $true
    }
}

Invoke-CMCHWriteLog 'Starting installation.'
Invoke-CMCHWriteLog "Installation command line: '$ccmsetup_file $installer_parameters /forceinstall'"
try {
    Start-Process @proc_splat
    do {
        $ccmsetup_service = Get-Service -Name 'ccmsetup'
        $ccmsetup_process = Get-Process -Name 'ccmsetup'

        Start-Sleep -Seconds 3
    } while ($ccmsetup_service -or $ccmsetup_process)

    # There are times where 'ccmsetup.exe' installs itself at '$env:SystemRoot\ccmsetup' and then
    # launches itself from there. There's a brief moment where there is no 'ccmsetup' service or process
    # so we wait a little.
    Invoke-CMCHWriteLog 'Checking if installation finished or if there is another bootstrap operation pending.'
    Start-Sleep -Seconds 60

    do {
        $ccmsetup_service = Get-Service -Name 'ccmsetup'
        $ccmsetup_process = Get-Process -Name 'ccmsetup'

        Start-Sleep -Seconds 3
    } while ($ccmsetup_service -or $ccmsetup_process)

    if (Get-Service -Name 'CcmExec') {
        Invoke-CMCHWriteLog "Installation process finished. For more details see 'ccmsetup.log'."
    }
    else {
        Invoke-CMCHWriteLog "Installation process finished, but the SMS Agent Host service was not found. For more details see 'ccmsetup.log'." Warning
    }
}
catch {
    Invoke-CMCHWriteLog 'Failed to start installation.' Error
    Write-ErrorRecord([ref]$_)
}
#endregion

#region State
Set-ItemProperty -Path 'HKLM:\SOFTWARE\ConfigMgrClientDeviceMonitor' -Name 'IsInstallationComplete' -Value $true -Force
Unregister-ScheduledTask -TaskName 'Config Manager Client Device Monitor - Client Install' -Confirm:$false
#endregion