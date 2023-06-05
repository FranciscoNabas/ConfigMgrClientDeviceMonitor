[CmdletBinding(
    SupportsShouldProcess,
    ConfirmImpact = 'Medium'
)]
param ([switch]$TestNoInstall)

#requires -RunAsAdministrator

Begin {
    $ErrorActionPreference = 'SilentlyContinue'

    #region Objects

    # This enumeration is used to synchronize state between
    # the main script, installer and downloader.
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

    # This class represents an object that needs to be disposed by us.
    class DisposableObjects {
        [bool]$IsDisposed
        [PSObject]$Object

        DisposableObjects([PSObject]$_object) {
            $this.Object = $_object
            $this.IsDisposed = $false
        }
    }

    # This class is the base for the reusable object we will use throughout execution.
    # It contains a list of disposable objects, and the main CIM session.
    class ClientHealthReusables {
        
        [System.Collections.Generic.HashSet[DisposableObjects]]
        $DisposableObjects

        [CimSession]
        $CimSession

        ClientHealthReusables() {
            # Creating a CIM session with DCOM options keeps the engine from using WinRM.
            $this.CimSession = [CimSession]::Create('localhost', [Microsoft.Management.Infrastructure.Options.DComSessionOptions]::new())
            $this.DisposableObjects = [System.Collections.Generic.HashSet[DisposableObjects]]::new()
        }

        [void] PushDisposable([PSObject]$_object) {
            [void]$this.DisposableObjects.Add(
                [DisposableObjects]::new($_object)
            )
        }

        [void] DisposeAllInstances() {
            foreach ($object in $this.DisposableObjects) {
                if (!$object.IsDisposed) {
                    try { $object.Dispose() }
                    catch {
                        if ($_.Exception.Message -like "does not contain a method named 'Dispose'") {
                            throw [ArgumentException]::("Object does not implement IDisposable.")
                        }
                    }
                    $object.IsDisposed = $true
                }
            }
            
        }

        [void] CloseCimSession() {
            # 'Dispose' calls 'Dispose' on the safe handle.
            # 'Close' frees all session associated data and frees the safe handle.
            $this.CimSession.Close()
        }

        # 'CimSession.QueryInstances()' returns an IEnumerable<ciminstance>, which doesn't contains a 'Count' property, or method.
        # Here we cast it as a HasSet, and avoid having to type the namespace and query dialect language every time.
        # I'm trying, MS.
        [System.Collections.Generic.HashSet[ciminstance]] QueryCim([string]$query, [string]$namespace = 'Root/CIMV2') {

            # 'CimInstance' implements IDisposable, so theoretically we need to clean up.
            # We are more conserned with consistency and safety, than performance.
            $query_result = [System.Collections.Generic.HashSet[ciminstance]]$this.CimSession.QueryInstances($namespace, 'WQL', $query)
            foreach ($instance in $query_result) {
                $this.PushDisposable($instance)
            }
            return $query_result
        }

        [System.Collections.Generic.HashSet[ciminstance]] QueryCim([string]$query) {
            $namespace = 'ROOT/CIMV2'
            $query_result = [System.Collections.Generic.HashSet[ciminstance]]$this.CimSession.QueryInstances($namespace, 'WQL', $query)
            foreach ($instance in $query_result) {
                $this.PushDisposable($instance)
            }
            return $query_result
        }
    }
    #endregion

    #region Functions

    # This function writes logs to a file in the 'CMTrace.exe' standard.
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
            [string]$Component = $MyInvocation.InvocationName,

            [Parameter()]
            [int]$ScriptLineNumber = $MyInvocation.ScriptLineNumber

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

        $content = [string]::Format($logText, $Message, $time, $date, $Component, $context, $Level.value__, $thread, [System.IO.Path]::GetFileName($MyInvocation.ScriptName), $ScriptLineNumber)

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
        $log_file_size = (Get-ChildItem -Path $Global:cmch_log_file_path -ErrorAction SilentlyContinue).Length
        switch ($Global:cmch_config.Log.SizeUnit) {
            1 { $max_file_size = $Global:cmch_config.Log.MaxLogFileSize * 1Mb }
            Default { $max_file_size = $Global:cmch_config.Log.MaxLogFileSize * 1Kb }
        }
        if ($log_file_size -gt $max_file_size) {
            $log_file_base_name = [System.IO.Path]::GetFileNameWithoutExtension($Global:cmch_log_file_path)
            Rename-Item -Path $Global:cmch_log_file_path -NewName "$log_file_base_name-$([datetime]::Now.ToString('yyyyMMdd-HHmmss')).log" -Force
        }

        # Writting log to file.
        Write-Log -Path $Path -Message $Message -Level $Level -Component $Global:cmch_current_component -ScriptLineNumber $MyInvocation.ScriptLineNumber
    }

    # This function converts an 'ErrorRecord' throwed by PS to an error line in the log.
    function Write-ErrorRecord([ref]$error_record) {
        Invoke-CMCHWriteLog "(0x$('{0:X}' -f $error_record.Value.Exception.HResult)) $($error_record.Value.Exception.Message)." -Level Error
    }

    # This function tests WMI and applies fixes if auto-fix is enabled.
    # It runs 'WinMgmt.exe /verifyrepository' and checks for an instance
    # in the 'Win32_ComputerSystem'.
    function Start-WmiTestRepair {

        $is_fix_eligible = $false
        $verify_result = & "$env:SystemRoot\System32\wbem\WinMgmt.exe" /verifyrepository
        if ($verify_result -like '*inconsistent*' -or $verify_result -like '*not consistent*') {
            Invoke-CMCHWriteLog "WMI repository not consistent. Verification returned '$verify_result'." Error
            $is_fix_eligible = $true
            $Global:cmch_check_board.Rows.Find('WmiCheck').IsCompliant = $false
        }
        try {
            $computer_system_instance = $Global:cmch_reusables.QueryCim('Select * From Win32_ComputerSystem')
            if ($computer_system_instance.Count -lt 1) {
                $is_fix_eligible = $true
                $Global:cmch_check_board.Rows.Find('WmiCheck').IsCompliant = $false
                Invoke-CMCHWriteLog "WMI repository not consistent. 'Win32_ComputerSystem' have no instances.'$verify_result'." Error
            }
        }
        catch {
            $is_fix_eligible = $true
            $Global:cmch_check_board.Rows.Find('WmiCheck').IsCompliant = $false
            Invoke-CMCHWriteLog 'WMI repository check failed.' Error
            Write-ErrorRecord([ref]$_)
        }

        if ($is_fix_eligible) {
            if ($Global:cmch_config.Wmi.AutoFix) {
                Invoke-CMCHWriteLog 'Attempting to fix WMI repository.'
                Invoke-CMCHWriteLog 'Stopping services.'
                Stop-Service -Name 'Winmgmt' -Force
                Stop-Service -Name 'CcmExec' -Force -ErrorAction SilentlyContinue
    
                Invoke-CMCHWriteLog 'Registering WMI binaries.'
                $wmi_binaries = @('unsecapp.exe', 'wmiadap.exe', 'wmiapsrv.exe', 'wmiprvse.exe', 'scrcons.exe')
                foreach ($wbem_root_path in @("$env:SystemRoot\System32\wbem", "$env:SystemRoot\SysWOW64\wbem")) {
                    if (Test-Path -Path $wbem_root_path) {
                        Push-Location $wbem_root_path
                        foreach ($binary_file in $wmi_binaries) {
                            if (Test-Path -Path ".\$binary_file" -PathType Leaf) {
                                & "$wbem_root_path\$binary_file" /RegServer
                            }
                            else {
                                if ($wbem_root_path -eq "$env:SystemRoot\System32\wbem") {
                                    Invoke-CMCHWriteLog "'$binary_file' not found! WMI might not be recoverabe. Consider reimaging this computer." Warning
                                }
                            }
                        }
                        Pop-Location
                    }
                }
    
                switch ($Global:cmch_config.Wmi.FixLevel) {
                    1 { $winmgmt_argument = '/resetrepository' }
                    Default { $winmgmt_argument = '/salvagerepository' }
                }
                Invoke-CMCHWriteLog "Calling '$env:SystemRoot\System32\wbem\WinMgmt.exe $winmgmt_argument'"
                $fix_ops_result = & "$env:SystemRoot\System32\wbem\WinMgmt.exe" $winmgmt_argument
    
                if ($fix_ops_result -notlike '*repository has been reset*') {
                    Invoke-CMCHWriteLog "Repository fix failed. Recover returned '$fix_ops_result'. This computer needs to be reimaged." Error
                }
                else {
                    $verify_result = & "$env:SystemRoot\System32\wbem\WinMgmt.exe" /verifyrepository
                    if ($verify_result -like '*inconsistent*' -or $verify_result -like '*not consistent*') {
                        Invoke-CMCHWriteLog "Recover command returned success, but new check returned '$verify_result'. This computer needs to be reimaged" Error
                    }
                    else {
                        Invoke-CMCHWriteLog 'WMI repository restore succeeded.'
                        if ($Global:cmch_is_consistent_client) { $Global:cmch_is_consistent_client = $false }
                        if (!$Global:cmch_install_after_reboot) { $Global:cmch_install_after_reboot = $true }
                    }
                }
    
                Start-Service -Name 'Winmgmt'
            }
            else {
                Invoke-CMCHWriteLog 'WMI repository not consistent, but auto-fix is not enabled.' Warning
            }
        }

        if (!$is_fix_eligible) {
            $Global:cmch_check_board.Rows.Find('WmiCheck').IsCompliant = $true
            Invoke-CMCHWriteLog 'WMI repository consistent.'
        }
    }

    # This function removes all classes instances and the namespace, recursively.
    function Remove-WmiSchemaRecursively([string]$root_namespace) {

        Invoke-CMCHWriteLog "Starting WMI namespace cleaning for $root_namespace."
        try {
            $child_namespace_list = $Global:cmch_reusables.QueryCim('Select * From __NAMESPACE', $root_namespace)

            Invoke-CMCHWriteLog "Number of child namespaces is '$($child_namespace_list.Count)'."
            foreach ($namespace_name in $child_namespace_list) {
                if (!$root_namespace.EndsWith('/')) {
                    $root_namespace = "$root_namespace/"
                }
                Remove-WmiSchemaRecursively(([string]::Join('', ($root_namespace, $namespace_name.Name))))
            }
            $class_list = [System.Collections.Generic.List[cimclass]]$Global:cmch_reusables.CimSession.EnumerateClasses($root_namespace)

            Invoke-CMCHWriteLog "Number of classes is '$($class_list.Count)'."
            foreach ($class in $class_list) {
                $instance_list = [System.Collections.Generic.List[cimclass]]$Global:cmch_reusables.CimSession.EnumerateInstances($root_namespace, $class.PSBase.CimSystemProperties.ClassName)
        
                Invoke-CMCHWriteLog "Deleting '$($instance_list.Count)' instances in '$($class.PSBase.CimSystemProperties.ClassName)'."
                foreach ($instance in $instance_list) {
                    try {
                        $Global:cmch_reusables.CimSession.DeleteInstance($instance)
                    }
                    catch {
                        Invoke-CMCHWriteLog "Failed to delete instance '$($instance.__PATH)'." Error
                        Invoke-CMCHWriteLog "($($_.Exception.HResult)) $($_.Exception.Message)" Error
                    }
                    finally { $instance.Dispose() }
                }
                try {
                    $mgmt_class = [wmiclass]"$($root_namespace):$($class.PSBase.CimSystemProperties.ClassName)"
                }
                catch {
                    Invoke-CMCHWriteLog "Failed to delete class '$($class.Name)'." Error
                    Invoke-CMCHWriteLog "($($_.Exception.HResult)) $($_.Exception.Message)" Error
                }
                finally {
                    $mgmt_class.Delete()
                    $mgmt_class.Dispose()
                    $class.Dispose()
                }
            }

            Invoke-CMCHWriteLog "Deleting namespace '$root_namespace'."
            
            $namespace_split = $root_namespace.Split('/')
            $root_namespace_name = $namespace_split.Where({ ![string]::IsNullOrEmpty($_) }) | Select-Object -Last 1
            $previous_root = [string]::Join('/', $namespace_split[0..($namespace_split.IndexOf($root_namespace_name) - 1)])

            foreach ($instance in $Global:cmch_reusables.QueryCim("Select * From __NAMESPACE Where Name = '$root_namespace_name'", $previous_root)) {
                try {
                    $Global:cmch_reusables.CimSession.DeleteInstance($instance)
                }
                catch {
                    Invoke-CMCHWriteLog "Failed to delete namespace '$($instance.__PATH)'." Error
                    Invoke-CMCHWriteLog "($($_.Exception.HResult)) $($_.Exception.Message)" Error
                }
                finally { $instance.Dispose() }
            }
        }
        catch {
            Invoke-CMCHWriteLog "Failed to recursively remove namespace '$root_namespace'." Error
            Invoke-CMCHWriteLog "($($_.Exception.HResult)) $($_.Exception.Message)" Error
        }
    }

    # This function resets the components as the guide in the bellow link.
    # https://learn.microsoft.com/en-us/troubleshoot/windows-client/deployment/additional-resources-for-windows-update
    function Start-WindowsUpdateComponentReset {

        # Creating a service list so we can start it in the reverse order.
        $service_list = [System.Collections.Generic.SortedList[int, string]]::new()
        [void]$service_list.Add(0, 'CcmExec')
        [void]$service_list.Add(1, 'BITS')
        [void]$service_list.Add(2, 'wuauserv')
        [void]$service_list.Add(3, 'CryptSvc')

        Invoke-CMCHWriteLog 'Creating stop service runspace pool.'
        #region Stop services
        $pool = [runspacefactory]::CreateRunspacePool()
        $pool.ApartmentState = 'MTA'
        $pool.ThreadOptions = 'UseNewThread'
        $pool.Open()

        $messenger = [hashtable]::Synchronized(@{
            Cancel   = $false
            CcmExec  = [PSCustomObject]@{
                    OriginalStatus      = $null
                    OriginalStartupType = $null
                    StartupType         = $null
            }
            BITS     = [PSCustomObject]@{
                    OriginalStatus      = $null
                    OriginalStartupType = $null
                    StartupType         = $null
            }
            WuauServ = [PSCustomObject]@{
                    OriginalStatus      = $null
                    OriginalStartupType = $null
                    StartupType         = $null
            }
            CryptSvc = [PSCustomObject]@{
                    OriginalStatus      = $null
                    OriginalStartupType = $null
                    StartupType         = $null
            }
        })

        $service_monitor_routine = {

            param(
                [string]$ServiceName,
                [hashtable]$Messenger,
                [string]$UtilitiesAssemblyPath
            )

            $ErrorActionPreference = 'SilentlyContinue'

            try {
                Add-Type -Path $UtilitiesAssemblyPath
            }
            catch { }
            $process_api = [Windows.Utilities.ProcessAndThread]::new()

            # Saving service current configuration.
            $managed_service = [Windows.Utilities.Service]::new($ServiceName)
            $Messenger[$ServiceName].OriginalStartupType = $managed_service.StartupType
            $Messenger[$ServiceName].OriginalStatus = $managed_service.Status

            try {
                # Disabling service.
                Set-Service -Name $ServiceName -StartupType 'Disabled' -ErrorAction 'Stop'
                $Messenger[$ServiceName].StartupType = [Windows.Utilities.ServiceStartupType]::Disabled

                # Stopping service.
                Stop-Service -Name $ServiceName -Force
            }
            catch {
                $Messenger[$ServiceName].StartupType = $Messenger[$ServiceName].OriginalStartupType
            }

            # Monitoring the service to ensure it keeps stopped throughout the process.
            try {
                while (!$Messenger.Cancel) {
                    $process_id = $null
                    $managed_service = Get-Service -Name $ServiceName
                    if ($managed_service.Status -eq 'Running' -or $managed_service.Status -eq 'StartPending' -or $managed_service.Status -eq 'ContinuePending') {
                        $process_id = (Get-CimInstance -Query "Select ProcessId From Win32_Service Where Name = '$ServiceName'").ProcessId
                        if ($process_id -and $process_id -ne 0) {
                            try {
                                $process_api.TerminateProcess($process_id)
                            }
                            catch {
                                if ($_.Exception.Message -like '*Access*denied*') {
                                    $process_api.TerminateProcess($process_id, @('SeDebugPrivilege'))
                                }
                            }
                        }
                    }
                }
            }
            finally {
                $process_api.Dispose()
            }
        }

        $parameter_list = [System.Collections.IDictionary]@{
            'ServiceName' = ''
            'Messenger'   = $messenger
            'UtilitiesAssemblyPath' = $Global:cmch_utilities_library_path
        }

        Invoke-CMCHWriteLog 'Starting PowerShell instances.'
        [System.Collections.Generic.HashSet[PSCustomObject]]$thread_list = @()
        for ($i = 0; $i -lt $service_list.Count; $i++) {
            $service = $service_list[$i]
        
            $temp = [powershell]::Create()
            $temp.RunspacePool = $pool
            $parameter_list['ServiceName'] = $service
            [void]$temp.AddScript($service_monitor_routine).AddParameters($parameter_list)

            [void]$thread_list.Add([PSCustomObject]@{
                ServiceName = $service
                PowerShell  = $temp
                AsyncHandle = $temp.BeginInvoke()
            })
        }
        #endregion

        #region Item cleaning
        Invoke-CMCHWriteLog 'Starting Registry and FileSystem provider reset.'
        foreach ($item_path in @(
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies'
            'HKCU:\SOFTWARE\Microsoft\WindowsSelfHost'
            'HKCU:\SOFTWARE\Policies'
            'HKLM:\SOFTWARE\Microsoft\Policies'
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies'
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate'
            'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost'
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Policies'
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies'
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate'
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
            "$env:SystemRoot\System32\GroupPolicy\Machine\registry.pol"
            "$env:SystemRoot\System32\GroupPolicy\gpt.ini"
            "$env:SystemRoot\SoftwareDistribution"
            "$env:SystemRoot\System32\catroot2"
            "$env:ALLUSERSPROFILE\Application Data\Microsoft\Network\Downloader\qmgr*.dat"
            "$env:ProgramData\Microsoft\Network\Downloader\qmgr*.dat"
        )) {
            try {
                Remove-Item -Path $item_path -Recurse -Force -ErrorAction 'Stop'
                Invoke-CMCHWriteLog "Removed '$item_path'."
            }
            catch {
                Invoke-CMCHWriteLog "Error removing '$item_path'." Error
                Write-ErrorRecord([ref]$_)
            }
        }
        #endregion

        #region Service SDDL reset
        Invoke-CMCHWriteLog "Resetting 'wuauserv' and 'BITS' services security descriptors."
        foreach ($service in @('BITS', 'wuauserv')) {

            # TODO: Convert to Windows.Utilities.Services.SetServiceObjectSecurity()
            $sdset_result = & "$env:SystemRoot\System32\sc.exe" 'sdset' $service 'D:(A;CI;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)'
            if ($sdset_result -notlike '*SetServiceObjectSecurity SUCCESS') {
                Invoke-CMCHWriteLog "Set service object security failed for service '$service'." Error
                Invoke-CMCHWriteLog $sdset_result Error
            }
            else {
                Invoke-CMCHWriteLog "Successfully reset security descriptor for service '$service'."
            }
        }
        #endregion

        #region Registering servers.
        Invoke-CMCHWriteLog 'Registering COM server libraries.'
        foreach ($library in @(
            'atl.dll', 'urlmon.dll', 'mshtml.dll', 'shdocvw.dll', 'browseui.dll', 'jscript.dll', 'vbscript.dll',
            'scrrun.dll', 'msxml.dll', 'msxml3.dll', 'msxml6.dll', 'actxprxy.dll', 'softpub.dll', 'wintrust.dll',
            'dssenh.dll', 'rsaenh.dll', 'gpkcsp.dll', 'sccbase.dll', 'slbcsp.dll', 'cryptdlg.dll', 'oleaut32.dll',
            'ole32.dll', 'shell32.dll', 'initpki.dll', 'wuapi.dll', 'wuaueng.dll', 'wuaueng1.dll', 'wucltui.dll',
            'wups.dll', 'wups2.dll', 'wuweb.dll', 'qmgr.dll', 'qmgrprxy.dll', 'wucltux.dll', 'muweb.dll', 'wuwebv.dll'
        )) {

            # TODO: Convert to 'DllRegisterServer'.
            & "$env:SystemRoot\System32\regsvr32.exe" $library '/s'
        }
        #endregion

        #region Winsock reset
        Invoke-CMCHWriteLog 'Resetting WinSock catalog.'
        $winsck_reset = & "$env:SystemRoot\System32\netsh.exe" 'winsock' 'reset'
        if (($winsck_reset -split "`n")[1] -notlike '*Sucessfully reset the Winsock Catalog*') {
            Invoke-CMCHWriteLog "Failed resetting the WinSock catalog." Error
            Invoke-CMCHWriteLog $winsck_reset Error
        }
        else {
            Invoke-CMCHWriteLog 'Successfully reset the WinSock catalog.'
        }
        #endregion

        #region Starting services
        # Stopping threads.
        Invoke-CMCHWriteLog 'Starting services.'
        $messenger.Cancel = $true
        foreach ($thread in $thread_list) {
            if ($thread.PowerShell.InvocationStateInfo.State -eq 'Running') {
                [void]$thread.PowerShell.Stop()
            }
            $thread.InvocationStateInfo
            $thread.HadErrors
            $thread.Streams.Error
            $thread.PowerShell.Dispose()
        }
        $pool.Dispose()

        # Starting in the reverse order.
        for ($i = $service_list.Count - 1; $i -lt $service_list.Count -and $i -ge 0; $i--) {
            $service_util = [Windows.Utilities.Service]::new($service_list[$i])
            switch ($messenger[$service_list[$i]].OriginalStartupType) {
                'AutomaticDelayedStart' { $service_util.SetStartupType('AutomaticDelayedStart') }
                'Manual' { $service_util.SetStartupType('Manual') }
                'Disabled' { $service_util.SetStartupType('Disabled') }
                Default { $service_util.SetStartupType('Automatic') }
            }
            
            switch ($messenger[$service_list[$i]].OriginalStatus) {
                'Stopped' { if ($service_util.Status -ne 'Stopped') { $service_util.Stop() } }
                'StopPending' { if ($service_util.Status -ne 'Stopped') { $service_util.Stop() } }
                'Paused' { Suspend-Service -Name $service_util.Name }
                'PausePending' { Suspend-Service -Name $service_util.Name }
                Default { $service_util.Start() }
            }
        }
        #endregion

        #region Attempt to clean BITS queue
        if ($Global:cmch_bits_module_imported) {
            Invoke-CMCHWriteLog 'Clearing BITS transfer jobs.'
            [void](Get-BitsTransfer -AllUsers | Remove-BitsTransfer)
        }
        else {
            Invoke-CMCHWriteLog 'BITS module not imported. Not clearing transfer job queue.'
        }
        #endregion
    }

    # This functions check for errors in the 'WUAHandler.log', and checks the
    # age of the local group policy database file. If an issue is found, the database
    # file, and registry keys are removed.
    function Test-WinUpdateGpoError {

        param(
            [string]$CcmLogPath,
            [int]$LogLineCount
        )

        $wuahlog_content = Get-Content -Path "$CcmLogPath\WUAHandler.log" | Select-Object -Last $LogLineCount
        $error_1 = 'Group policy settings were overwritten by a higher authority'
        $error_2 = 'Unable to read existing WUA resultant policy. Error = 0x80070002'

        $is_fixed = $false
        if ($wuahlog_content -match $error_1 -or $wuahlog_content -match $error_2 -or $wuahlog_content -match '0x80004005' -or $wuahlog_content -match '0x87d00692') {
            if ($Global:cmch_config.WindowsUpdate.GpoOverwrittenHigherAuth.AutoFix) {
                Invoke-CMCHWriteLog 'Error found in log. Attempting to fix.' Error
                try {
                    # Removing files.
                    Remove-Item -Path "$env:SystemRoot\System32\GroupPolicy\Machine\registry.pol" -Force -ErrorAction Stop
                    Remove-Item -Path "$env:SystemRoot\System32\GroupPolicy\Machine\gpt.ini" -Force -ErrorAction Stop

                    $is_fixed = $true
                    $Global:cmch_check_board.Rows.Find('WindowsUpdate').IsCompliant = $true
                }
                catch {
                    $Global:cmch_check_board.Rows.Find('WindowsUpdate').IsCompliant = $false
                    Invoke-CMCHWriteLog 'Failed removing policy files.' Error
                    Invoke-CMCHWriteLog "($($_.Exception.HResult)) $($_.Exception.Message)" Error
                }
            }
            else {
                $Global:cmch_check_board.Rows.Find('WindowsUpdate').IsCompliant = $false
                Invoke-CMCHWriteLog 'Error found in log, but auto-fix is not enabled.' Warning
            }
        }
        else {
            # Checking file age.
            Invoke-CMCHWriteLog 'No errors found in the log. Checking group policy database file age.'
            $reg_last_write_time = (Get-ChildItem -Path "$env:SystemRoot\System32\GroupPolicy\Machine\registry.pol").LastWriteTime
            if ($reg_last_write_time) {
                $limit_date = [DateTime]::Now.AddDays( - $Global:cmch_config.WindowsUpdate.GpoErrors.PolicyDbFileAgeDays )
                if ($reg_last_write_time -lt $limit_date) {
                    if ($Global:cmch_config.WindowsUpdate.GpoOverwrittenHigherAuth.AutoFix) {
                        Invoke-CMCHWriteLog "Group policy database file last write time older than '$($Global:cmch_config.WindowsUpdate.GpoErrors.PolicyDbFileAgeDays)'. Attempting to fix." Error
                        try {
                            # Removing files.
                            Remove-Item -Path "$env:SystemRoot\System32\GroupPolicy\Machine\registry.pol" -Force -ErrorAction Stop
                            Remove-Item -Path "$env:SystemRoot\System32\GroupPolicy\Machine\gpt.ini" -Force -ErrorAction Stop
        
                            $is_fixed = $true
                            $Global:cmch_check_board.Rows.Find('WindowsUpdate').IsCompliant = $true
                        }
                        catch {
                            $Global:cmch_check_board.Rows.Find('WindowsUpdate').IsCompliant = $false
                            Invoke-CMCHWriteLog 'Failed removing policy files.' Error
                            Invoke-CMCHWriteLog "($($_.Exception.HResult)) $($_.Exception.Message)" Error
                        }
                    }
                    else {
                        $Global:cmch_check_board.Rows.Find('WindowsUpdate').IsCompliant = $false
                        Invoke-CMCHWriteLog "Group policy database file last write time older than '$($Global:cmch_config.WindowsUpdate.GpoErrors.PolicyDbFileAgeDays)', but auto-fix is not enabled." Warning
                    }
                }
                else {
                    $Global:cmch_check_board.Rows.Find('WindowsUpdate').IsCompliant = $true
                    Invoke-CMCHWriteLog 'Policy file is recent.'
                }
            }
            else {
                $Global:cmch_check_board.Rows.Find('WindowsUpdate').IsCompliant = $false
                Invoke-CMCHWriteLog 'Unable to get group policy database file last write time.' Error
            }
        }

        if ($is_fixed -and $Global:cmch_is_consistent_client) {
            Invoke-CMCHWriteLog 'Restarting client services, and triggering a software update evaluation cycle.'
        
            # Restarting services.
            foreach ($service in @('CcmExec', 'smsexec')) {
                Restart-Service -Name $service -Force
            }

            # Triggering software update schedule.
            try {
                $sms_client_class = [wmiclass]'\\.\root\ccm:SMS_Client'
                foreach ($schedule in @(
                        '{00000000-0000-0000-0000-000000000113}'
                        '{00000000-0000-0000-0000-000000000032}'
                        '{00000000-0000-0000-0000-000000000108}'
                    )) {
                    try {
                        $trigger_result = $sms_client_class.TriggerSchedule($schedule)
                        if ($trigger_result.ReturnValue -and $trigger_result.ReturnValue -ne 0) {
                            Invoke-CMCHWriteLog "'TriggerSchedule' failed for schedule '$schedule'. Returned '$($trigger_result.ReturnValue)'." Error
                        }
                    }
                    catch {
                        Invoke-CMCHWriteLog "Failed triggering schedule '$schedle'." Error
                        Invoke-CMCHWriteLog "($($_.Exception.HResult)) $($_.Exception.Message)" Error
                    }
                }
            }
            finally {
                $sms_client_class.Dispose()
            }
        }
    }

    # This function creates a scheduled task to run the client installation
    # after a reboot, at the logon of any user, delayed 15 minutes.
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
            
            $trigger = $definition.Triggers.Create(9)
            [void]$disposables.Add($trigger)
            $trigger.Delay = 'PT15M'

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

    # This function creates a scheduled task to resume the download in case
    # it's abruptly stopped.
    function New-DownloaderRecoveryTask {

        Unregister-ScheduledTask -TaskName 'Config Manager Client Device Monitor - Downloader' -Confirm:$false -ErrorAction SilentlyContinue

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
            
            [void]$definition.Triggers.Create(9)
            $trigger = $definition.Triggers.Create(2)
            [void]$disposables.Add($root)
            $trigger.StartBoundary = [datetime]::Now.AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ss')
            $trigger.DaysInterval = 1
            $trigger.Repetition.Duration = 'PT1H'
            $trigger.Repetition.Interval = 'PT1H'

            $action = $definition.Actions.Create(0)
            $action.Path = 'powershell.exe'
            $action.Arguments = "-ExecutionPolicy Bypass -File ""$PSScriptRoot\Downloader.ps1"""

            [void]$root.RegisterTaskDefinition('Config Manager Client Device Monitor - Downloader', $definition, 6, $null, $null, 5)
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

    ## NOT IMPLEMENTED ##
    <#
        .SYNOPSIS
            Import a certificate into the Trusted Publishers and Trusted Root cert store
        .DESCRIPTION
            This function is used to validate or import a certificate into both the Trusted Publishers 
            and the Trusted Root certificate store. This is useful when you need to manage a Code Signing
            certificate. The function accepts a 'EncodedCertString' which will be a base64 encoded value
            which equates the the actual certificate file. This is used to allow for the script to be used
            without provided additional files. 

        The main use case is for use in a Configuration Item within Configuration Manager.
        .PARAMETER Remediate
            A boolean that determines if the certificate will be imported if not found.
        .PARAMETER CodeSigningCertificateThumbprint
            The thumbprint of the certificate which will be useed to find the certificate in the
            two certificate stores. The 'Thumbprint' of a certificate can be retrieved from the details
            tab of the properties of a certificate.
        .PARAMETER EncodedCertString
            A string that is a base64 represntation of the certificate file. This can be retrieved with the
            below code snippet where ExportedCert.cer is your Code Signing certificate file, and is located.
            in the directory where the command is being ran from.

        Set-Clipboard -Value ([System.Convert]::ToBase64String((Get-Content -Path .\ExportedCert.cer -Encoding Byte)))

            Note: You don't need to have the Private Key marked as exportable to do this.
        .EXAMPLE
            C:\PS>
            Example of how to use this cmdlet
        .EXAMPLE
            C:\PS>
            Another example of how to use this cmdlet
        .NOTES
            FileName:    Register-CodeSigningCertificate.ps1
            Author:      Cody Mathis
            Contact:     @CodyMathis123
            Created:     2020-05-11
            Updated:     2020-05-11
    #>
    function Register-CodeSigningCertificate {

        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [bool]$Remediate,
            [Parameter(Mandatory = $true)]
            [string]$CodeSigningCertificateThumbprint,
            [Parameter(Mandatory = $true)]
            [string]$EncodedCertString
        )
        $CertStoreSearchResult = @{
            TrustedPublisher = $false
            Root             = $false
        }

        foreach ($CertStoreName in @("TrustedPublisher", "Root")) {
            $CertStore = [System.Security.Cryptography.X509Certificates.X509Store]::new($CertStoreName, "LocalMachine")
            $CertStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)

            switch ($CertStore.Certificates.Thumbprint) {
                $CodeSigningCertificateThumbprint {
                    $CertStoreSearchResult[$CertStoreName] = $true
                }
            }
            $CertStore.Close()
        }

        foreach ($Result in $CertStoreSearchResult.GetEnumerator()) {
            switch ($Result.Value) {
                $false {
                    switch ($Remediate) {
                        $true {
                            $CertStore = [System.Security.Cryptography.X509Certificates.X509Store]::new($Result.Key, "LocalMachine")
                            $CertStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                
                            $CertificateByteArray = [System.Convert]::FromBase64String($EncodedCertString)
                            $Certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
                            $Certificate.Import($CertificateByteArray)
                    
                            $CertStore.Add($Certificate)
                            $CertStore.Close()
                        }
                        $false {
                            return $false
                        }
                    }   
                }
            }
        }

        return $true
    }

    # This function determines if theres a reboot pending for the machine by
    # checking CBS, Windows Update, CM Client SDK, PC rename and file rename operations.
    function Get-PendingRebootRe {
        try {
            $pcpendingrename, $pendingfilerename, $ccmclientsdk = $false, $false, $false
    
            $cbs = (Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\').PSChildName -contains 'RebootPending'
            $wua = (Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\') -contains 'RebootPending'
        
            $filerenval = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager').PendingFileRenameOperations
            if (![string]::IsNullOrEmpty($filerenval)) { $pendingfilerename = $true }
    
            $netlogonreg = Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon'
            $domjoin = ($netlogonreg.PSChildName -contains 'JoinDomain') -or ($netlogonreg.PSChildName -contains 'AvoidSpnSet')
    
            $actvpcname = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
            $pcname = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
            $pcpendingrename = ($actvpcname -ne $pcname) -or $domjoin
    
            try {
                $ccmrebpend = ([wmiclass]'\\.\ROOT\ccm\ClientSDK:CCM_ClientUtilities').DetermineIfRebootPending()
                if ($ccmrebpend.ReturnValue -eq 0) { $ccmclientsdk = $ccmrebpend.RebootPending -or $ccmrebpend.IsHardRebootPending }
                else { $ccmclientsdk = $false }
            }
            catch { $ccmclientsdk = $false }
        
            return [PSCustomObject]@{
                ComputerName = $env:COMPUTERNAME
                CbServicing  = $cbs
                WinUpdate    = $wua
                ClientSdk    = $ccmclientsdk
                PcRename     = $pcpendingrename
                FileRenOps   = $pendingfilerename
                FileRenObj   = $filerenval
                BootPending  = $cbs -or $wua -or $ccmclientsdk -or $pcpendingrename -or $pendingfilerename
            }
        }
        catch { throw $PSItem }
    }

    # This function creates an Abstract Path Tree from a list of paths. The APT
    # contains the relative paths to be used in a copy / download operation.
    function Get-AbstractPathTreeFromList {
            
        param ([ref]$the_list, [ref]$apt)

        $common_root = [Windows.Utilities.FileSystem.Path]::GetpathCommonRoot($the_list.Value)
        $path_split = $common_root.Split('\')
        $root_folder_name = $path_split[$path_split.Length - 1]
        
        foreach ($entry in $the_list.Value) {
            $relative_path = ''
            $branches = $entry.Split('\')
            if ($Global:copy_item_ex_is_from_pipeline) { $start_index = $branches.IndexOf($root_folder_name) }
            else { $start_index = $branches.IndexOf($root_folder_name) + 1 }

            foreach ($stage in $branches[$start_index..($branches.Length - 1)]) {
                $relative_path = [string]::Join('\', ($relative_path, $stage))
            }
            if ([System.IO.Directory]::Exists($entry)) {
                [void]$apt.Value.Add(
                    [PSCustomObject]@{
                        Type         = 'Directory'
                        RelativePath = $relative_path
                        SourcePath   = $entry
                        CommonRoot   = $common_root
                        Created      = $false
                    }
                )
            }
            else {
                [void]$apt.Value.Add(
                    [PSCustomObject]@{
                        Type         = 'File'
                        RelativePath = $relative_path
                        SourcePath   = $entry
                        CommonRoot   = $common_root
                        Created      = $false
                    }
                )
            }
        }
    }

    # This function calls the 'ClientHealthReusables.DisposeAll' method, to dispose of
    # all unmanaged resources, closes the CIM session, and frees the global variables.
    # It's called in case the script needs to terminate prematurely.
    function Start-ExitCleanup {
        $Global:cmch_reusables.DisposeAllInstances()
        $Global:cmch_reusables.CloseCimSession()

        # Managed resources.
        foreach ($global_variable in $(
            'cmch_current_component'
            'cmch_log_file_path'
            'cmch_config_imported'
            'cmch_bits_module_imported'
            'cmch_registry_location'
            'cmch_is_consistent_client'
            'cmch_operating_system_info'
            'cmch_ccm_install_path'
            'cmch_reusables'
            'cmch_config'
        )) {
            Remove-Variable -Name $global_variable -Scope 'Global' -Force
        }

        [GC]::Collect()
    }
    #endregion

    #region Importing Configuration
    $Global:cmch_current_component = 'ImportConfig'
    if (Test-Path -Path "$PSSCriptRoot\appsettings.jsonc" -PathType Leaf) {
        try {
            # Importing the configuration contents, and converts it to an object.
            $Global:cmch_config = Get-Content -Path "$PSSCriptRoot\appsettings.jsonc" -Raw | ConvertFrom-Json -ErrorAction Stop
            $Global:cmch_log_file_path = $Global:cmch_config.Log.Path
            $cmch_main_log_dir = [System.IO.Path]::GetDirectoryName($Global:cmch_config.Log.Path)
            if (!(Test-Path -Path $cmch_main_log_dir)) {
                [void](mkdir $cmch_main_log_dir)
            }
            $Global:cmch_config_imported = $true
        }
        catch {
            # In case of a failure, we hardcode the log path, so we can log this failure.
            $Global:cmch_log_file_path = "$PSScriptRoot\Logs\ConfigMgrClientDeviceMonitor.log"
            if (!(Test-Path -Path "$PSScriptRoot\Logs")) {
                [void](mkdir "$PSScriptRoot\Logs")
            }
            Invoke-CMCHWriteLog 'Failed importing configuration from file.' Error
            Write-ErrorRecord([ref]$_)
            Start-ExitCleanup
            exit 1
        }
    }
    #endregion

    #region Checking status

    # This section checks the 'AbortReason' value in the registry, and checks if
    # it's one the main script should abort.
    $Global:cmch_registry_location = 'HKLM:\SOFTWARE\ConfigMgrClientDeviceMonitor\'
    $abort_reason_list = @(
        [AbortReason]::Downloading
        [AbortReason]::InstallPending
        [AbortReason]::RebootPending
        [AbortReason]::FileHashNotMatch
        [AbortReason]::DownloadedFileNotFound
        [AbortReason]::SourcePathWaitTimeout
    )
    $Global:last_abort_reason = (Get-ItemProperty -Path $Global:cmch_registry_location).AbortReason
    if (![string]::IsNullOrEmpty($Global:last_abort_reason) -and ([AbortReason]$Global:last_abort_reason) -in $abort_reason_list) {
        Invoke-CMCHWriteLog "Current abort state triggers an abort. '$(([AbortReason]$abort_reason).ToString())'." Warning
        
        # ERROR_OPERATION_ABORTED
        Start-ExitCleanup
        exit 995
    }
    #endregion

    #region Import Modules
    $Global:cmch_current_component = 'ImportModule'
    # BITS
    try {
        # Importing the 'BITS' module.
        Import-Module -Name 'BitsTransfer' -ErrorAction Stop;
        $Global:cmch_bits_module_imported = $true
    }
    catch { $Global:cmch_bits_module_imported = $false }
    #endregion

    #region Initial evironment setup

    # Importing the 'Windows.Utilities' helper library that will be used throughout the script.
    # https://github.com/FranciscoNabas/Windows.Utilities
    $Global:cmch_utilities_library_path = "$PSSCriptRoot\bin\Windows.Utilities.dll"
    Add-Type -Path $Global:cmch_utilities_library_path

    # Creating initial objects.
    $Global:cmch_reusables = New-Object -TypeName ClientHealthReusables
    $Global:cmch_registry_location = 'HKLM:\SOFTWARE\ConfigMgrClientDeviceMonitor\'
    $Global:cmch_is_consistent_client = $true
    $Global:cmch_install_after_reboot = $false
    $Global:cmch_operating_system_info = $Global:cmch_reusables.QueryCim('Select * From Win32_OperatingSystem')
    $Global:cmch_abort = $false
    
    # You got bigger problems than the config mgr client pal.
    if ($Global:cmch_operating_system_info.Count -lt 1) {
        throw [SystemException]::new("'Win32_OperatingSystem' didn't returned any instances!")
    }

    # Creating the checkboard.
    # This datatable will be used to keep testing track.
    $Global:cmch_check_board = [System.Data.DataTable]::new()
    [void]$Global:cmch_check_board.Columns.Add([System.Data.DataColumn]@{
        ColumnName = 'Id'
        AutoIncrement = $true
        AutoIncrementSeed = 1
        AutoIncrementStep = 1
    })
    $comp_col = [System.Data.DataColumn]::new('Component', [string])
    [void]$Global:cmch_check_board.Columns.Add($comp_col)
    [void]$Global:cmch_check_board.Columns.Add([System.Data.DataColumn]::new('IsChecked', [bool]))
    [void]$Global:cmch_check_board.Columns.Add([System.Data.DataColumn]::new('IsCompliant', [bool]))

    # Certain components, when marked as non compliant marks the client to reinstallation,
    # but it's not necessary to run the install after a reboot, unless there's a pending reboot for this PC.
    [void]$Global:cmch_check_board.Columns.Add([System.Data.DataColumn]::new('IsPendingRebootAware', [bool]))
    $Global:cmch_check_board.PrimaryKey = [System.Data.DataColumn[]]@($comp_col)

    # Adding the component rows.
    foreach ($component in $Global:cmch_config.ComponentList) {
        $row = $Global:cmch_check_board.NewRow()
        $row.Component = $component
        $row.IsChecked = $false
        $row.IsCompliant = $false
        $row.IsPendingRebootAware = $false
        $Global:cmch_check_board.Rows.Add($row)
    }
    #endregion
}

Process {
    #region Main Process
    #region STAGE>_ INITIAL SETUP

    #region Testing to see if we are running in a CM Task Sequence
    $Global:cmch_current_component = 'TestingIfCmTaskSequence'
    Invoke-CMCHWriteLog 'Testing if script is running from a Configuration Manager Task Sequence, or if one is running.'
    try {
        # This COM object RCW is only available when running from a Configuration Manager Task Sequence.
        $ts_object = New-Object -ComObject 'Microsoft.SMS.TSEnvironment' -ErrorAction Stop
        Invoke-CMCHWriteLog 'This script is not allowed to run on a Configuration Manager Task Sequence, or when one is running.' Error -WriteError
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($ts_object)
        Start-ExitCleanup
        exit 1
    }
    catch { }
    $Global:cmch_check_board.Rows.Find('TestingIfCmTaskSequence').IsChecked = $true
    $Global:cmch_check_board.Rows.Find('TestingIfCmTaskSequence').IsCompliant = $true
    Invoke-CMCHWriteLog 'Passed Task Sequence test.'
    #endregion

    #region Managing application registry
    $Global:cmch_current_component = 'ManageLastRunTime'
    Invoke-CMCHWriteLog 'Getting / setting last script execution time from registry.'
    try {
        # Checking if the main registry key exists.
        if (!(Test-Path -Path 'HKLM:\SOFTWARE\ConfigMgrClientDeviceMonitor')) {
            [void](New-Item -Path 'HKLM:\SOFTWARE' -Name 'ConfigMgrClientDeviceMonitor')
        }
        try { $last_run_time = [datetime](Get-ItemProperty -Path $Global:cmch_registry_location).LastRunTime }
        catch { }
        if ($last_run_time) { Invoke-CMCHWriteLog "Last run time: $last_run_time" }

        # Setting last runtime registry value.
        Set-ItemProperty -Path $Global:cmch_registry_location -Name LastRunTime -Value ([datetime]::Now.ToString()) -Force
        
        # If this script is running after a client installation, it cleans all registry keys.
        # This way the check can start from scratch.
        if ([bool](Get-ItemProperty -Path $Global:cmch_registry_location).IsInstallationComplete -eq $true) {
            foreach ($value in @(
                'ClientShareLocation'
                'InstallAfterReboot'
                'InstallerDestinationFolder'
                'InstallerFileMetadata'
                'IsDownloadComplete'
                'IsInstallationComplete'
                'UninstallerCompiledMofs'
            )) {
                Set-ItemProperty -Path $Global:cmch_registry_location -Name $value -Value $null -Force
            }
        }

        $Global:cmch_check_board.Rows.Find('ManageLastRunTime').IsCompliant = $true
    }
    catch {
        Invoke-CMCHWriteLog 'Error managing last run time from registry.' Error
        Write-ErrorRecord([ref]$_)
        $Global:cmch_check_board.Rows.Find('ManageLastRunTime').IsCompliant = $false
    }
    $Global:cmch_check_board.Rows.Find('ManageLastRunTime').IsChecked = $true
    #endregion

    #region Managing client health log file
    $Global:cmch_current_component = 'ManageSolLogFile'

    # Listing all history log files.
    $log_path = [System.IO.Path]::GetDirectoryName($Global:cmch_log_file_path)
    $log_file_base_name = [System.IO.Path]::GetFileNameWithoutExtension($Global:cmch_log_file_path)
    $all_history_log = Get-ChildItem -Path $log_path -Filter "$log_file_base_name-*.log"

    # Removing old files.
    if ($all_history_log.Count -gt $Global:cmch_config.Log.MaxLogHistory) {
        $all_history_log | Sort-Object -Property LastWriteTime | Select-Object -First ($all_history_log.Count - $Global:cmch_config.Log.MaxLogHistory) | Remove-Item -Force
    }
    $Global:cmch_check_board.Rows.Find('ManageSolLogFile').IsChecked = $true
    $Global:cmch_check_board.Rows.Find('ManageSolLogFile').IsCompliant = $true
    #endregion

    #endregion

    #region STAGE>_ PRE-CLIENT CHECK

    #region WMI check
    $Global:cmch_current_component = 'WmiCheck'
    if ($Global:cmch_config.Wmi.Enabled) {
        Invoke-CMCHWriteLog 'Starting WMI check / repair.'
        
        # Calling the test / fix function.
        Start-WmiTestRepair
        $Global:cmch_check_board.Rows.Find('WmiCheck').IsChecked = $true
    }
    #endregion

    #region DNS check
    $Global:cmch_current_component = 'DNS'
    if ($Global:cmch_config.CheckDns.Enabled) {
        Invoke-CMCHWriteLog 'Checking DNS.'

        try {
            # Getting the current computer FQDN.
            $host_fqdn = [System.Net.Dns]::GetHostEntry('localhost').HostName
            
            # Listing the IP addresses from the enabled network adapters.
            $local_addresses = $Global:cmch_reusables.QueryCim("Select IPAddress From Win32_NetworkAdapterConfiguration Where IPEnabled = 'True'").IPAddress
            
            # Tries to get DNS to resolve the current computer name.
            $dns_check = [System.Net.Dns]::GetHostByName($host_fqdn)
        
            # The main method does not work for Windows 7, or Windows Server 2008, and bellow
            if ($Global:cmch_operating_system_info.Caption -notlike '*Windows 7*' -and $Global:cmch_operating_system_info.Caption -notlike '*Server 2008*') {

                # Querying the interface index for the active network adapters.
                $active_adapters = $Global:cmch_reusables.QueryCim('Select InterfaceIndex From MSFT_NetAdapter Where InterfaceOperationalStatus = 1', 'Root/StandardCimv2')
                try {
                    # Listing the DNS server addresses.
                    $dns_servers = (Get-DnsClientServerAddress -AddressFamily 2 -InterfaceIndex $active_adapters.InterfaceIndex).ServerAddresses
                    
                    # Trying to resolve the current computer name with the specified DNS servers.
                    $address_list = (Resolve-DnsName -Name $host_fqdn -Server $dns_servers[0] -Type 'A' -DnsOnly).IPAddress
                }
                catch {
                    # Fallback to deprecated method.
                    $address_list = $dns_check.AddressList.IPAddressToString -replace '%(.*)'
                }
            }
            else {
                # This method does not guarantee to resolve using the DNS server, it might use the local cache.
                # For Windows 7 / Server 2008 only.
                $address_list = $dns_check.AddressList.IPAddressToString -replace '%(.*)'
            }

            $Global:cmch_check_board.Rows.Find('DNS').IsCompliant = $false
            # If the first resolution is correct.

            if ($dns_check.HostName -eq $host_fqdn) {
                $Global:cmch_check_board.Rows.Find('DNS').IsCompliant = $true
                foreach ($address in $address_list) {
                    # Checking the main DNS server resolution.
                    if ($address -notin $local_addresses) {
                        Invoke-CMCHWriteLog "'$address' in DNS record do not exists locally." Warning
                        $Global:cmch_check_board.Rows.Find('DNS').IsCompliant = $false
                    }
                }
            }
            else {
                Invoke-CMCHWriteLog 'Hostname from DNS check not equal to local host DNS host entry hostname.' Error
                Invoke-CMCHWriteLog "DNS name: $($dns_check.HostName). Local FQDN: $host_fqdn." Error
                Invoke-CMCHWriteLog 'Local IP addresses:' Warning
                foreach ($address in $address_list) {
                    Invoke-CMCHWriteLog "   $address" Warning
                }
            }

            if (!$Global:cmch_check_board.Rows.Find('DNS').IsCompliant) {
                if ($Global:cmch_config.CheckDns.AutoFix) {
                    Invoke-CMCHWriteLog 'DNS not consistent. Attempting to fix by registering with the server.' Warning

                    # Registering with DNS servers.
                    if ($PSVersionTable.PSVersion -ge [version]'4.0') {
                        [void](Register-DnsClient)
                    }
                    else {
                        [void](ipconfig.exe /registerdns)
                    }
                }
                else {
                    Invoke-CMCHWriteLog 'DNS not consistent, but auto-fix is not enabled.' Warning
                }
            }
            else {
                Invoke-CMCHWriteLog 'DNS is consistent.'
            }
        }
        catch {
            Invoke-CMCHWriteLog 'Failed checking DNS.' Error
            Write-ErrorRecord([ref]$_)
        }
        $Global:cmch_check_board.Rows.Find('DNS').IsChecked = $true
    }
    #endregion

    #region BITS check
    $Global:cmch_current_component = 'BITS'
    if ($Global:cmch_config.CheckBits.Enabled) {
        Invoke-CMCHWriteLog 'Checking Background Intelligent Transfer Service - BITS.'

        if ($Global:cmch_bits_module_imported) {
            try {
                # Checking if there are any BITS transfer jobs in an error state.
                $error_transfers = Get-BitsTransfer -AllUsers | Where-Object { $_.JobState -like '*Error*' }
                if ($error_transfers) {
                    $Global:cmch_check_board.Rows.Find('BITS').IsCompliant = $false
                    if ($Global:cmch_config.CheckBits.AutoFix) {
                        Invoke-CMCHWriteLog 'There are BITS transactions in error state. Attempting to fix.' Warning

                        # Removing the failed jobs.
                        Remove-BitsTransfer -BitsJob $error_transfers
                        Stop-Service 'BITS' -Force

                        # TODO: Use 'SetNamedSecurityInfo'.
                        # Setting the security descriptor for the BITS service to the default.
                        [void](Invoke-Expression -Command 'sc.exe sdset BITS "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)"')
                        Start-Service -Name 'BITS'
                    }
                    else {
                        Invoke-CMCHWriteLog 'There are BITS transactions in error state, but auto-fix is not enabled.' Warning
                    }
                }
                else {
                    $Global:cmch_check_board.Rows.Find('BITS').IsCompliant = $true
                    Invoke-CMCHWriteLog 'BITS transfers are consistent.'
                }    
            }
            catch {
                $Global:cmch_check_board.Rows.Find('BITS').IsCompliant = $false
                Invoke-CMCHWriteLog 'Error checking BITS jobs.' Error
                Write-ErrorRecord([ref]$_)
            }
        }
        else {
            $Global:cmch_check_board.Rows.Find('BITS').IsCompliant = [DBNull]::Value
            Invoke-CMCHWriteLog 'BITS PowerShell module not imported. Skipping check.' Warning
        }
        $Global:cmch_check_board.Rows.Find('BITS').IsChecked = $true
    }
    #endregion

    #region Admin share
    $Global:cmch_current_component = 'AdminShare'
    if ($Global:cmch_config.AdminShare.Enabled) {
        Invoke-CMCHWriteLog 'Checking file shares.'
        try {
            $share_info = $Global:cmch_reusables.QueryCim('Select * From Win32_Share')
            $is_fix = $false
            # Checking if 'ADMIN$' is a valid share.
            if ('ADMIN$' -in $share_info.Name) {
                Invoke-CMCHWriteLog "'ADMIN$' is consistent."
            }
            else {
                $Global:cmch_check_board.Rows.Find('AdminShare').IsCompliant = $false
                if ($Global:cmch_config.AdminShare.AutoFix) {
                    Invoke-CMCHWriteLog "'ADMIN$' not consistent. Attempting to fix." Error
                    $is_fix = $true
                }
                else {
                    Invoke-CMCHWriteLog "'ADMIN$' not consistent, but auto-fix is not enabled." Warning
                }
            }

            # Checking if 'C$' is a valid share.
            if ('C$' -in $share_info.Name) {
                Invoke-CMCHWriteLog "'C$' is consistent."
            }
            else {
                $Global:cmch_check_board.Rows.Find('AdminShare').IsCompliant = $false
                if ($Global:cmch_config.AdminShare.AutoFix) {
                    Invoke-CMCHWriteLog "'C$' not consistent. Attempting to fix." Error
                    $is_fix = $true
                }
                else {
                    Invoke-CMCHWriteLog "'C$' not consistent, but auto-fix is not enabled." Warning
                }
            }

            if ($is_fix) {
                # TODO: An actual solution.
                # Restarting 'LanmanServer' service
                $Global:cmch_check_board.Rows.Find('AdminShare').IsCompliant = $false
                Invoke-CMCHWriteLog "Restarting 'LanmanServer' service."
                Restart-Service -Name 'LanmanServer' -Force
            }
            else {
                $Global:cmch_check_board.Rows.Find('AdminShare').IsCompliant = $true
            }
        }
        catch {
            $Global:cmch_check_board.Rows.Find('AdminShare').IsCompliant = $false
            Invoke-CMCHWriteLog 'Checking admin share failed.' Error
            Write-ErrorRecord([ref]$_)
        }
        $Global:cmch_check_board.Rows.Find('AdminShare').IsChecked = $true
    }
    #endregion

    #region Drivers
    $Global:cmch_current_component = 'Drivers'
    if ($Global:cmch_config.Drivers) {
        Invoke-CMCHWriteLog 'Checking drivers.'
        $query = @'
Select
    Name
    ,DeviceID
From Win32_PnPEntity
Where
    ConfigManagerErrorCode != 0 And
    ConfigManagerErrorCode != 22 And
    Not Name Like '%PS/2%'
'@
        try {
            # Querying for faulty and/or unknown devices.
            $device_list = $Global:cmch_reusables.QueryCim($query)
            if ($device_list.Count -gt 0) {
                Invoke-CMCHWriteLog "$($device_list.Count) unknown or faulty device(s)." Error
                foreach ($device in $device_list) {
                    Invoke-CMCHWriteLog "Missing or faulty driver: '$($device.Name)'. Device ID: $($device.DeviceID)" Error
                    $Global:cmch_check_board.Rows.Find('Drivers').IsCompliant = $false
                }
            }
            else {
                $Global:cmch_check_board.Rows.Find('Drivers').IsCompliant = $true
                Invoke-CMCHWriteLog 'Drivers are consistent.'
            }
        }
        catch {
            $Global:cmch_check_board.Rows.Find('Drivers').IsCompliant = $false
            Invoke-CMCHWriteLog 'Failed checking drivers.' Error
            Write-ErrorRecord([ref]$_)
        }
        $Global:cmch_check_board.Rows.Find('Drivers').IsChecked = $true
    }
    #endregion

    #region System drive disk space
    $Global:cmch_current_component = 'SystemDiskSpace'
    if ($Global:cmch_config.OsDiskFreeSpace.Enabled) {
        Invoke-CMCHWriteLog 'Checking system drive free space.'

        # Getting the total free space for the system drive.
        $system_drive_free_space = [System.IO.DriveInfo]::new($env:SystemDrive).TotalFreeSpace
        $free_space_bytes = $system_drive_free_space
        
        # Converting the config values to bytes according to the 'SpaceUnit' config.
        switch ($Global:cmch_config.OsDiskFreeSpace.SpaceUnit) {
            0 {
                $system_drive_free_space = $system_drive_free_space / 1Kb
                $free_space_text = "$([math]::Round($system_drive_free_space / 1Kb, 2)) Kb"
                $required_space_text = "$($Global:cmch_config.OsDiskFreeSpace.MinFreeSpace) Kb"
            }
            1 {
                $system_drive_free_space = $system_drive_free_space / 1Mb
                $free_space_text = "$([math]::Round($system_drive_free_space / 1Mb, 2)) Mb"
                $required_space_text = "$($Global:cmch_config.OsDiskFreeSpace.MinFreeSpace) Mb"
            }
            2 {
                $system_drive_free_space = $system_drive_free_space / 1Gb
                $free_space_text = "$([math]::Round($system_drive_free_space / 1Gb, 2)) Gb"
                $required_space_text = "$($Global:cmch_config.OsDiskFreeSpace.MinFreeSpace) Gb"
            }
            3 {
                $system_drive_free_space = $system_drive_free_space / 1Tb
                $free_space_text = "$([math]::Round($system_drive_free_space / 1Tb, 2)) Tb"
                $required_space_text = "$($Global:cmch_config.OsDiskFreeSpace.MinFreeSpace) Tb"
            }
            Default {
                Invoke-CMCHWriteLog "Invalid space measuring unit '$Global:cmch_config.OsDiskFreeSpace.SpaceUnit'." Error
                break
            }
        }

        # Checking if the free space is compliant with the config.
        if ($system_drive_free_space -lt $Global:cmch_config.OsDiskFreeSpace.MinFreeSpace) {
            $Global:cmch_check_board.Rows.Find('SystemDiskSpace').IsCompliant = $false
            Invoke-CMCHWriteLog "System drive free space '$free_space_text' bellow threshold of '$required_space_text'." Warning
        }
        else {
            $Global:cmch_check_board.Rows.Find('SystemDiskSpace').IsCompliant = $false
            Invoke-CMCHWriteLog "System drive free space is compliant ($free_space_bytes B)."
        }
        $Global:cmch_check_board.Rows.Find('SystemDiskSpace').IsChecked = $true
    }
    #endregion

    #region Services
    Invoke-CMCHWriteLog 'Starting service check.'
    $Global:cmch_current_component = 'Services'
    $is_all_service_consistent = $true

    foreach ($service in $Global:cmch_config.Services) {
        Invoke-CMCHWriteLog "Starting service '$($service.Name)' check."

        # Getting an initial service state.
        $managed_service = Get-Service -Name $service.Name
        
        # Creating a service object from the utility library so we can
        # query full Startup Type values, and apply changes to the service if needed.
        try { $service_util = [Windows.Utilities.Service]::new($service.Name) }
        catch {
            Invoke-CMCHWriteLog "Error checking service '$($service.Name)'." Error
            Write-ErrorRecord([ref]$_)
            continue
        }
    
        try {
            # Service start types 'Boot' and 'System' are reserved for drivers.
            # We can mark them as automatic.
            if ($service_util.StartupType -in @('Boot', 'System')) { $svc_startup_type = [Windows.Utilities.ServiceStartupType]::Automatic }
            else { $svc_startup_type = $service_util.StartupType }

            # Checking service compliance.
            $is_fix = $false
            if ($svc_startup_type.value__ -ne $service.StartupType) {
                Invoke-CMCHWriteLog "Service '$($service.Name)' with wrong startup type. Service: '$($service_util.StartupType.ToString())'. Required: $(([Windows.Utilities.ServiceStartupType]$service.StartupType).ToString()). Attempting to fix." Warning
                $is_all_service_consistent = $false
                
                # Changing service startup type.
                $service_util.SetStartupType([Windows.Utilities.ServiceStartupType]$service.StartupType)
                $is_fix = $true
            }
            if ($service_util.Status.value__ -ne $service.Status) {
                Invoke-CMCHWriteLog "Service '$($service.Name)' with wrong status. Service: '$($service_util.Status.ToString())'. Required: $(([System.ServiceProcess.ServiceControllerStatus]$service.Status).ToString()). Attempting to fix." Warning
                $is_all_service_consistent = $false
                
                # Changing service status.
                switch ($service.Status) {
                    1 { Stop-Service -Name $service.Name -Force }
                    4 { Start-Service -Name $service.Name }
                    7 { Suspend-Service -Name $service.Name }
                    Default { Invoke-CMCHWriteLog "Service status '$($service.Status)' not supported." Error }
                }
                $is_fix = $true
            }

            if ($is_fix) {
                # Rechecking.
                $service_util = [Windows.Utilities.Service]::new($service.Name)
                if ($service_util.StartupType -in @('Boot', 'System')) { $svc_startup_type = [Windows.Utilities.ServiceStartupType]::Automatic }
                else { $svc_startup_type = $service_util.StartupType }
                if ($svc_startup_type.value__ -ne $service.StartupType -or $service_util.Status.value__ -ne $service.Status) {
                    Invoke-CMCHWriteLog "Attempt to set service's properties failed with no error. Current status: $($service_util.Status.ToString()). Startup type: $($service_util.StartupType.ToString())." Error
                }
            }
            else {
                Invoke-CMCHWriteLog "Service '$($service.Name)' compliant."
            }
        }
        catch {
            $Global:cmch_check_board.Rows.Find('Services').IsCompliant = $false
            Invoke-CMCHWriteLog "Error checking service $($service.Name)." Error
            Write-ErrorRecord([ref]$_)
            $is_all_service_consistent = $false
        }
    }

    if ($is_all_service_consistent) {
        $Global:cmch_check_board.Rows.Find('Services').IsCompliant = $true
        Invoke-CMCHWriteLog 'All services are consistent.'
    }
    $Global:cmch_check_board.Rows.Find('Services').IsChecked = $true
    #endregion

    #endregion

    #region STAGE>_ CLIENT CHECK

    #region Config Manager Client
    $Global:cmch_current_component = 'CmClient'
    Invoke-CMCHWriteLog 'Starting Configuration Manager Client test.'
    
    # Getting the client installation path from the registry.
    $ccm_log_dir = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global').LogDirectory
    if ([string]::IsNullOrEmpty($ccm_log_dir)) {
        # If not found, we use the default.
        $Global:cmch_ccm_install_path = "$env:SystemRoot\CCM"
    }
    else {
        # Parsing the path. .NET Framework does not have the 'System.IO.Path.TrimEndingDirectorySeparator()' method.
        if ($ccm_log_dir.EndsWith('\')) {
            $ccm_log_dir = $ccm_log_dir[0..($ccm_log_dir.Length - 2)]
        }
        $Global:cmch_ccm_install_path = $ccm_log_dir.Replace('\Logs', '')
    }

    # Checking if the SMS Client Host service exists.
    $ccmexec_service = Get-Service -Name 'CcmExec'
    if ($ccmexec_service) {
        Invoke-CMCHWriteLog 'Client installed.'

        # Client database check.
        if ($Global:cmch_config.CheckClientDatabase) {
            try {
                Invoke-CMCHWriteLog 'Testing client database.'
                Stop-Service -Name 'CcmExec' -Force
            
                # Loading SQLCE assemblies.
                if (!([System.AppDomain]::CurrentDomain.GetAssemblies().Location -contains "$PSScriptRoot\bin\System.Data.SqlServerCe.dll")) {
                    [void][System.Reflection.Assembly]::UnsafeLoadFrom("$PSScriptRoot\bin\System.Data.SqlServerCe.dll")
                }

                # Creating engine.
                $engine = [System.Data.SqlServerCe.SqlCeEngine]::new()
                $is_inconsistent_db = $false
            
                # Testing each database.
                foreach ($database in @('CcmStore.sdf', 'StateMessageStore.sdf', 'InventoryStore.sdf', 'UserAffinityStore.sdf', 'CertEnrollmentStore.sdf')) {
                    $engine.LocalConnectionString = "Data Source = $Global:cmch_ccm_install_path\$database"
                    if (!$engine.Verify([System.Data.SqlServerCe.VerifyOption]::Default)) {
                    
                        # Broken.
                        Invoke-CMCHWriteLog "Client database '$database' is inconsistent. Marking for reinstallation." Error
                        $Global:cmch_is_consistent_client = $false
                        $Global:cmch_check_board.Rows.Find('CmClient').IsPendingRebootAware = $true
                        $is_inconsistent_db = $true
                    }
                    else {
                        Invoke-CMCHWriteLog "Client database '$database' consistent."
                    }
                }
                if (!$is_inconsistent_db) {
                    Invoke-CMCHWriteLog 'Client databases are consistent.'
                }
            }
            catch {
                Invoke-CMCHWriteLog 'Error checking the client databases.' Error
                Write-ErrorRecord([ref]$_)
                $Global:cmch_is_consistent_client = $false
            }
            finally {
                Start-Service -Name 'CcmExec'
                try { $engine.Dispose() }
                catch { }
            }
        }

        # Checking the CCM Client WMI provider.
        if ($Global:cmch_is_consistent_client) {
            Invoke-CMCHWriteLog 'Checking CM client WMI namespace.'
            try {
                # Checking if the 'SMS_Client' class have an instance.
                if ($Global:cmch_reusables.QueryCim('Select * From SMS_Client', 'Root/CCM').Count -gt 0) {
                    Invoke-CMCHWriteLog 'CM client provider is consistent.'
                }
                else {
                    Invoke-CMCHWriteLog "'SMS_Client' class have no instances. Marking the client to reinstall." Error
                    $Global:cmch_is_consistent_client = $false
                    $Global:cmch_check_board.Rows.Find('CmClient').IsPendingRebootAware = $true
                }
            }
            catch {
                Invoke-CMCHWriteLog 'Error checking the CM client WMI namespace. Marking for reinstall.' Error
                Write-ErrorRecord([ref]$_)
                $Global:cmch_is_consistent_client = $false
                $Global:cmch_check_board.Rows.Find('CmClient').IsPendingRebootAware = $true
            }
        }
    }
    else {
        Invoke-CMCHWriteLog 'Client Host service not found. Marking for (re)installation.' Error
        $Global:cmch_is_consistent_client = $false
    }
    if ($is_consistent_client) {
        $Global:cmch_check_board.Rows.Find('CmClient').IsCompliant = $true
        Invoke-CMCHWriteLog 'Configuration Manager Client is consistent.'
    }
    else {
        $Global:cmch_check_board.Rows.Find('CmClient').IsCompliant = $false
    }
    $Global:cmch_check_board.Rows.Find('CmClient').IsChecked = $true
    #endregion

    #region CM Client version
    $Global:cmch_current_component = 'ClientVersion'
    if ($Global:cmch_is_consistent_client) {
        Invoke-CMCHWriteLog 'Checking client version.'
        try {
            # Getting the current client version installed from WMI.
            $client_version = [version]::Parse($Global:cmch_reusables.QueryCim('Select * From SMS_Client', 'Root/CCM')[0].ClientVersion)

            # Checking if the version is outdate.
            if ($client_version -lt [version]$Global:cmch_config.Client.Version) {
                Invoke-CMCHWriteLog "Installed client bellow required version. Installed: $client_version. Required: $($Global:cmch_config.Client.Version). Marking to reinstall." Warning
                $Global:cmch_is_consistent_client = $false
                $Global:cmch_check_board.Rows.Find('ClientVersion').IsPendingRebootAware = $true
                $Global:cmch_check_board.Rows.Find('ClientVersion').IsCompliant = $false
            }
            else {
                $Global:cmch_check_board.Rows.Find('ClientVersion').IsCompliant = $true
                Invoke-CMCHWriteLog 'Configuration Manager Client in the correct version.'
            }
        }
        catch {
            $Global:cmch_check_board.Rows.Find('ClientVersion').IsCompliant = $false
            Invoke-CMCHWriteLog 'Error checking installed client version.' Error
            Write-ErrorRecord([ref]$_)
        }
        $Global:cmch_check_board.Rows.Find('ClientVersion').IsChecked = $true
    }
    #endregion

    #region smstsmgr service
    $Global:cmch_current_component = 'SmstsmgrService'
    if ($Global:cmch_is_consistent_client) {

        # TODO: It's also a good idea for this service to depend on 'CcmExec'. Include multiple
        # services dependencies functionality in the utilities library.

        # Checking if the 'smstsmgr' service depends on the 'Winmgmt' service.
        Invoke-CMCHWriteLog "Checking 'smstsmgr' service dependencies."
        $managed_service = Get-Service -Name 'smstsmgr'
        if ($managed_service) {
            if ($managed_service.ServicesDependedOn.Name -ne 'Winmgmt') {
                Invoke-CMCHWriteLog "'smstsmgr' services depended on list is not compliant. Attempting to fix." Warning
                try {
                    $service_util = [Windows.Utilities.Service]::new('smstsmgr')
                    
                    # Currently this method can set the dependency to only one service.
                    $service_util.SetDependency('Winmgmt')

                    # Retesting.
                    $managed_service = Get-Service -Name 'smstsmgr'
                    if ($managed_service.ServicesDependedOn.Name -ne 'Winmgmt') {
                        $Global:cmch_check_board.Rows.Find('SmstsmgrService').IsCompliant = $false
                        Invoke-CMCHWriteLog "Unable to set service dependency. SetServiceDependency returned no errors." Error
                    }
                    else {
                        Invoke-CMCHWriteLog "'smstsmgr' service auto-fix succeeded."
                        $Global:cmch_check_board.Rows.Find('SmstsmgrService').IsCompliant = $true
                    }
                }
                catch {
                    Invoke-CMCHWriteLog "Failed setting 'smstsmgr' service dependency." Error
                    Write-ErrorRecord([ref]$_)
                }
            }
            else {
                $Global:cmch_check_board.Rows.Find('SmstsmgrService').IsCompliant = $true
                Invoke-CMCHWriteLog "Service 'smstsmgr' service dependent list is consistent."
            }
        }
        else {
            Invoke-CMCHWriteLog "Service 'smstsmgr' not found. Marking to reinstall." Error
            $Global:cmch_is_consistent_client = $false
            $Global:cmch_check_board.Rows.Find('SmstsmgrService').IsCompliant = $false
        }
        $Global:cmch_check_board.Rows.Find('SmstsmgrService').IsChecked = $true
    }
    #endregion

    #region Client Site Code
    $Global:cmch_current_component = 'SiteCode'
    if ($Global:cmch_is_consistent_client) {
        Invoke-CMCHWriteLog 'Checking assigned site code.'
        try {
            $is_fix = $false
            $sms_client = New-Object -ComObject 'Microsoft.SMS.Client'

            # Checking the current assigned SMS site code.
            $current_site_code = $sms_client.GetAssignedSite().Trim()
            if ($current_site_code -ne $Global:cmch_config.Client.SiteCode) {
                Invoke-CMCHWriteLog "Wrong site code. Assigned: $current_site_code. Required: $($Global:cmch_config.Client.SiteCode). Attempting to fix." Warning
                
                # Changing to the required one.
                $sms_client.SetAssignedSite($Global:cmch_config.Client.SiteCode)
                $is_fix = $true
            }
            else {
                Invoke-CMCHWriteLog 'Client assigned site is the correct one.'
            }

            if ($is_fix) {
                # Waiting a minute before retesting so the client have time to process the request.
                Start-Sleep -Seconds 60

                # Retesting
                $current_site_code = $sms_client.GetAssignedSite().Trim()
                if ($current_site_code -ne $Global:cmch_config.Client.SiteCode) {
                    $Global:cmch_check_board.Rows.Find('SiteCode').IsCompliant = $false
                    Invoke-CMCHWriteLog "Auto fix failed without errors. Current assigned site is '$current_site_code'." Error
                }
                else {
                    Invoke-CMCHWriteLog 'Site assignment auto-fix succeeded.'
                    $Global:cmch_check_board.Rows.Find('SiteCode').IsCompliant = $true
                }
            }
        }
        catch {
            $Global:cmch_check_board.Rows.Find('SiteCode').IsCompliant = $false
            Invoke-CMCHWriteLog 'Failed to check assigned site code.' Error
            Write-ErrorRecord([ref]$_)
        }
        finally {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($sms_client)
        }
        $Global:cmch_check_board.Rows.Find('SiteCode').IsChecked = $true
    }
    #endregion

    #region Client cache size
    $Global:cmch_current_component = 'CacheSize'
    if ($Global:cmch_is_consistent_client -and $Global:cmch_config.Client.CacheInfo.Enabled) {
        try {
            $resource_manager = New-Object -ComObject 'UIResource.UIResourceMgr'

            # Getting the configured client cache size.
            $cache_size = $resource_manager.GetCacheInfo().TotalSize()
        
            # Cache size based on percentage of disk size.
            if ($cache_size -like '*%*') {
                $cache_size = [int]$cache_size.Replace('%', '').Trim() / 100
            
                $system_drive = Get-PSDrive -Name $env:SystemDrive.Replace(':', '')
                $total_drive_size = $system_drive.Free + $system_drive.Used

                $cache_size = [math]::Round($total_drive_size * $cache_size / 1MB)
            }

            # Maximum cache size.
            if ($Global:cmch_config.Client.CacheInfo.CacheSize -gt 99999) {
                $required_cache_size = 99999
            }
            else {
                $required_cache_size = $Global:cmch_config.Client.CacheInfo.CacheSize
            }

            # Checking size.
            if ($cache_size -ne $required_cache_size) {
                Invoke-CMCHWriteLog "Cache size not compliant. Current: $cache_size. Required: $required_cache_size. Attempting o fix." Warning
                $resource_manager.GetCacheInfo().TotalSize() = $required_cache_size.ToString()

                # Waiting a minute for the client to process the changes.
                Start-Sleep -Seconds 60

                # Retesting
                $cache_size = $resource_manager.GetCacheInfo().TotalSize()
        
                if ($cache_size -like '*%*') {
                    $cache_size = [int]$cache_size.Replace('%', '').Trim() / 100
                
                    $system_drive = Get-PSDrive -Name $env:SystemDrive.Replace(':', '')
                    $total_drive_size = $system_drive.Free + $system_drive.Used
                
                    $cache_size = [math]::Round($total_drive_size * $cache_size / 1MB)
                }

                if ($Global:cmch_config.Client.CacheInfo.CacheSize -gt 99999) {
                    $required_cache_size = 99999
                }
                else {
                    $required_cache_size = $Global:cmch_config.Client.CacheInfo.CacheSize
                }

                if ($cache_size -ne $required_cache_size) {
                    $Global:cmch_check_board.Rows.Find('CacheSize').IsCompliant = $false
                    Invoke-CMCHWriteLog "Failed to set maximum client cache size. Current: '$cache_size'. Required: '$required_cache_size'." Error
                }
                else {
                    Invoke-CMCHWriteLog 'Client cache auto-fix succeeded.'
                    $Global:cmch_check_board.Rows.Find('CacheSize').IsCompliant = $true
                }
            }
            else {
                $Global:cmch_check_board.Rows.Find('CacheSize').IsCompliant = $true
                Invoke-CMCHWriteLog 'Cache size is consistent.'
            }
        }
        catch {
            $Global:cmch_check_board.Rows.Find('CacheSize').IsCompliant = $false
            Invoke-CMCHWriteLog 'Failed checking client cache size.' Error
            Invoke-CMCHWriteLog $_.Exception.StackTrace Error
            Invoke-CMCHWriteLog $_.Exception.InnerException.StackTrace Error
            Write-ErrorRecord([ref]$_)
        }
        finally {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($resource_manager)
        }
        $Global:cmch_check_board.Rows.Find('CacheSize').IsChecked = $true
    }
    #endregion

    #region Client log configuration
    $Global:cmch_current_component = 'ClientLogSize'
    if ($Global:cmch_is_consistent_client -and $Global:cmch_config.Client.LogInfo.Enabled) {
        Invoke-CMCHWriteLog 'Checking client log parameters.'

        # Listing the current client log settings.
        $max_log_file_size = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global').LogMaxSize
        $max_log_history = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global').LogMaxHistory
        $log_level = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global').LogLevel
    
        # Converting the required size to bytes according to the 'SizeUnit' configuration.
        switch ($Global:cmch_config.Client.LogInfo.SizeUnit) {
            1 { $desired_log_max_size = $Global:cmch_config.Client.LogInfo.MaxLogSize * 1Mb }
            Default { $desired_log_max_size = $Global:cmch_config.Client.LogInfo.MaxLogSize * 1Kb }
        }
        $desired_log_max_history = $Global:cmch_config.Client.LogInfo.MaxLogHistory

        # Values in conformity.
        if ($max_log_file_size -eq $desired_log_max_size -and $max_log_history -eq $desired_log_max_history) {
            Invoke-CMCHWriteLog 'Logging parameters in conformity with the configuration.'
            $Global:cmch_check_board.Rows.Find('ClientLogSize').IsCompliant = $true
        }
        else {
            Invoke-CMCHWriteLog 'Client logging options not in conformity with the configuration file. Will attempt to adjust.' Warning
            Invoke-CMCHWriteLog "Max log file size: is '$max_log_file_size', required '$desired_log_max_size'. Max log file history: is '$max_log_history', required '$desired_log_max_history'." Warning
            try {
                $sms_client_class = [wmiclass]'\\.\root\ccm:SMS_Client'
                $set_logging_result = $sms_client_class.SetGlobalLoggingConfiguration($log_level, $desired_log_max_size, $desired_log_max_history)
                if ($set_logging_result.ReturnValue -and $set_logging_result.ReturnValue -ne 0) {
                    Invoke-CMCHWriteLog "Failed adjusting logging parameters. Method returned '$($set_logging_result.ReturnValue)'." Warning
                    $Global:cmch_check_board.Rows.Find('ClientLogSize').IsCompliant = $false
                }
                else {
                    # Waiting a minute before retesting.
                    Start-Sleep -Seconds 60

                    $max_log_file_size = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global').LogMaxSize
                    $max_log_history = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global').LogMaxHistory
                    $log_level = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global').LogLevel

                    if ($max_log_file_size -eq $desired_log_max_size -and $max_log_history -eq $desired_log_max_history) {
                        $Global:cmch_check_board.Rows.Find('ClientLogSize').IsCompliant = $true
                        Invoke-CMCHWriteLog 'Logging parameters adjusted successfully.'
                    }
                    else {
                        Invoke-CMCHWriteLog "'SetGlobalLoggingConfiguration' succeeded, but values were not updated. Auto-fix failed." Error
                        Invoke-CMCHWriteLog "Max log file size: is '$max_log_file_size', required '$desired_log_max_size'. Max log file history: is '$max_log_history', required '$desired_log_max_history'." Error
                        $Global:cmch_check_board.Rows.Find('ClientLogSize').IsCompliant = $false
                    }
                }
            }
            catch {
                $Global:cmch_check_board.Rows.Find('ClientLogSize').IsCompliant = $true
                Invoke-CMCHWriteLog 'Failed adjusting logging parameters.' Error
                Write-ErrorRecord([ref]$_)
            }
            finally {
                try { $sms_client_class.Dispose() }
                catch { }
            }
        }
        $Global:cmch_check_board.Rows.Find('ClientLogSize').IsChecked = $true
    }
    #endregion

    #region Provisioning mode
    $Global:cmch_current_component = 'ProvisioningMode'
    if ($Global:cmch_is_consistent_client -and $Global:cmch_config.ClientProvisioningMode.Enabled) {
        Invoke-CMCHWriteLog 'Checking client provisioning mode.'
        try {
            # Checking if the client is in provisioning mode in the registry.
            $prov_mode_registry = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\CcmExec').ProvisioningMode
            if ($prov_mode_registry) {
                if ($prov_mode_registry -eq 'true') {
                    if ($Global:cmch_config.ClientProvisioningMode.AutoFix) {
                        Invoke-CMCHWriteLog 'Provisioning mode enabled. Attempting to fix.' Warning

                        # Setting the registry key to false.
                        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\CcmExec' -Name 'ProvisioningMode' -Value 'false' -ErrorAction Stop
                        try {

                            # Calling the 'SetClientProvisioningMode' static method from 'SMS_Client'.
                            $sms_client_class = [wmiclass]'\\.\root\ccm:SMS_Client'
                            $result = $sms_client_class.SetClientProvisioningMode($false)
                            if ($result.ReturnValue -and $result.ReturnValue -ne 0) {
                                $Global:cmch_check_board.Rows.Find('ClientLogSize').IsCompliant = $false
                                Invoke-CMCHWriteLog "Set client provisioning mode failed with '$($result.ReturnValue)'." Error
                            }
                            else {
                                $Global:cmch_check_board.Rows.Find('ClientLogSize').IsCompliant = $true
                                Invoke-CMCHWriteLog 'Set client provisioning mode succeeded.'
                            }
                        }
                        finally {
                            $sms_client_class.Dispose()
                        }
                    }
                    else {
                        $Global:cmch_check_board.Rows.Find('ClientLogSize').IsCompliant = $false
                        Invoke-CMCHWriteLog 'Client provisioning mode is not consistent, but auto-fix is not enabled.' Warning
                    }
                }
                else {
                    $Global:cmch_check_board.Rows.Find('ClientLogSize').IsCompliant = $true
                    Invoke-CMCHWriteLog 'Client provisioning mode is consistent.'
                }    
            }
            else {
                $Global:cmch_check_board.Rows.Find('ClientLogSize').IsCompliant = $false
                Invoke-CMCHWriteLog 'Provisioning mode registry key not found. Marking client to reinstall.' Error
                $Global:cmch_is_consistent_client = $false
            }
        }
        catch {
            $Global:cmch_check_board.Rows.Find('ClientLogSize').IsCompliant = $false
            Invoke-CMCHWriteLog 'Failed checking client provisioning mode.' Error
            Write-ErrorRecord([ref]$_)
        }
        $Global:cmch_check_board.Rows.Find('ClientLogSize').IsChecked = $true
    }
    #endregion

    #region Client certificate
    $Global:cmch_current_component = 'ClientCertificate'
    if ($Global:cmch_is_consistent_client -and $Global:cmch_config.ClientCertificate.Enabled) {
        Invoke-CMCHWriteLog 'Checking client certificate.'
        $is_consistent_cert = $true
    
        try {
            # Getting the contents from the log.
            $log_file_content = Get-Content -Path "$Global:cmch_ccm_install_path\Logs\ClientIDManagerStartup.log" -ErrorAction 'Stop'
            if ($log_file_content) {
                # Check if there are errors in the log.
                if ($log_file_content -match 'Failed to find the certificate in the store') {
                    $is_consistent_cert = $false
                }
                if ($log_file_content -match '[RegTask] - Server rejected registration 3') {
                    Invoke-CMCHWriteLog 'Found certificate store errors, but auto-fix is not applicable.' Warning
                    $is_consistent_cert = $false
                }

                if ($is_consistent_cert) {
                    $Global:cmch_check_board.Rows.Find('ClientCertificate').IsCompliant = $true
                    Invoke-CMCHWriteLog 'Client certificate is consistent.'
                }
                else {
                    $Global:cmch_check_board.Rows.Find('ClientCertificate').IsCompliant = $false
                    if ($Global:cmch_config.ClientCertificate.AutoFix) {
                        Invoke-CMCHWriteLog 'Found certificate store errors. Attempting to fix.' Warning
                        Stop-Service 'CcmExec' -Force

                        # Name is persistent across systems.
                        Remove-Item -Path "$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys\19c5cf9c7b5dc9de3e548adb70398402_50e417e0-e461-474b-96e2-077b80325612" -Force

                        # Deleting the log so the same error occurrence wont show. Client host service should create a new one.
                        Remove-Item -Path "$Global:cmch_ccm_install_path\Logs\ClientIDManagerStartup.log" -Force

                        Start-Service -Name 'CcmExec'
                        Invoke-CMCHWriteLog 'Finished client certificate store fix attempt.'
                    }
                    else {
                        Invoke-CMCHWriteLog 'Found certificate store errors, but auto-fix is not enabled.' Warning
                    }
                }
            }
            else {
                Invoke-CMCHWriteLog "'ClientIDManagerStartup.log' is empty." Warning
            }
        }
        catch {
            Invoke-CMCHWriteLog 'Error checking client certificate.' Error
            Write-ErrorRecord([ref]$_)
        }
        $Global:cmch_check_board.Rows.Find('ClientCertificate').IsChecked = $true
    }
    #endregion

    #region Hardware inventory
    $Global:cmch_current_component = 'HardwareInventory'
    if ($Global:cmch_is_consistent_client -and $Global:cmch_config.HardwareInventory.Enabled) {
        Invoke-CMCHWriteLog 'Checking hardware inventory action cycle.'

        try {
            # Checking if there's a registry for a hardware inventory cycle.
            $query = "Select * From InventoryActionStatus Where InventoryActionID = '{00000000-0000-0000-0000-000000000001}'"
            $instances = $Global:cmch_reusables.QueryCim($query, 'Root/CCM/InvAgt')
            if ([string]::IsNullOrEmpty($instances.InventoryActionID)) {
                if ($Global:cmch_config.HardwareInventory.AutoFix) {
                    Invoke-CMCHWriteLog 'InventoryActionStatus returned no instances. Starting a hardware inventory cycle.' Warning
                    try {
                        # If no instances were found, we start a cycle.
                        $sms_client_class = [wmiclass]'\\.\Root\CCM:SMS_Client'
                        $trigger_result = $sms_client_class.TriggerSchedule('{00000000-0000-0000-0000-000000000001}')
                        if ($trigger_result.ReturnValue -and $trigger_result.ReturnValue -ne 0) {
                            $Global:cmch_check_board.Rows.Find('HardwareInventory').IsCompliant = $false

                            if ($Global:cmch_config.HardwareInventory.ReinstallOnAutoFixFailure) {
                                Invoke-CMCHWriteLog "Trigger schedule for hardware inventory failed. Returned '$($trigger_result.ReturnValue)'. Marking client to reinstall." Error
                                $Global:cmch_is_consistent_client = $false
                            }
                            else {
                                Invoke-CMCHWriteLog 'Hardware inventory auto-fix failed, but reinstall for failed fix is not enabled.' Warning
                            }
                        }
                        else {
                            # Waiting a minute before checking again.
                            Start-Sleep -Seconds 60
                            $instances = $Global:cmch_reusables.QueryCim($query, 'Root/CCM/InvAgt')
                            if ($instances.Count -eq 0) {
                                
                                # The cycle trigger didn't returned errors, but no instances got returned.
                                # This can be viewed as a deffective client.
                                $Global:cmch_check_board.Rows.Find('HardwareInventory').IsCompliant = $false
                                if ($Global:cmch_config.HardwareInventory.ReinstallOnAutoFixFailure) {
                                    Invoke-CMCHWriteLog 'Hardware inventory auto-fix failed. Marking client to reinstall.' Warning
                                    $Global:cmch_is_consistent_client = $false
                                }
                                else {
                                    Invoke-CMCHWriteLog 'Hardware inventory auto-fix failed, but reinstall for failed fix is not enabled.' Warning
                                }
                            }
                            else {
                                # There's an instance on the recheck. Just making sure the last date is ok.
                                if ($instances[0].LastCycleStartedDate -lt [datetime]::Now.AddDays( - $Global:cmch_config.HardwareInventory.MaxIntervalDays )) {
                                    $Global:cmch_check_board.Rows.Find('HardwareInventory').IsCompliant = $false
                                    if ($Global:cmch_config.HardwareInventory.ReinstallOnAutoFixFailure) {
                                        Invoke-CMCHWriteLog 'Hardware inventory auto-fix failed. Marking client to reinstall.' Warning
                                        $Global:cmch_is_consistent_client = $false
                                    }
                                    else {
                                        Invoke-CMCHWriteLog 'Hardware inventory auto-fix failed, but reinstall for failed fix is not enabled.' Warning
                                    }
                                }
                                else {
                                    $Global:cmch_check_board.Rows.Find('HardwareInventory').IsCompliant = $true
                                    Invoke-CMCHWriteLog 'Hardware inventory cycle fix succeeded.'
                                }
                            }
                        }
                    }
                    catch {
                        $Global:cmch_check_board.Rows.Find('HardwareInventory').IsCompliant = $false
                        if ($Global:cmch_config.HardwareInventory.ReinstallOnAutoFixFailure) {
                            Invoke-CMCHWriteLog 'Hardware inventory auto-fix failed. Marking client to reinstall.' Error
                            Write-ErrorRecord([ref]$_)
                            $Global:cmch_is_consistent_client = $false
                        }
                        else {
                            Invoke-CMCHWriteLog 'Hardware inventory auto-fix failed, but reinstall for failed fix is not enabled.' Error
                            Write-ErrorRecord([ref]$_)
                        }
                    }
                    finally {
                        $sms_client_class.Dispose()
                    }
                }
                else {
                    $Global:cmch_check_board.Rows.Find('HardwareInventory').IsCompliant = $false
                    Invoke-CMCHWriteLog 'InventoryActionStatus returned no instances, but auto-fix is not enabled.' Warning
                }
            }
            else {
                # Comparing last cycle start date with config.
                # MI is going to return the date in the 'DateTime' format.
                if ($instances[0].LastCycleStartedDate -lt [datetime]::Now.AddDays( - $Global:cmch_config.HardwareInventory.MaxIntervalDays )) {
                    if ($Global:cmch_config.HardwareInventory.AutoFix) {
                        Invoke-CMCHWriteLog 'Last hardware inventory cycle older than the threshold. Triggering a cycle.' Warning
                        try {
                            # Triggering a HI cycle.
                            $sms_client_class = [wmiclass]'\\.\root\ccm:SMS_Client'
                            $trigger_result = $sms_client_class.TriggerSchedule('{00000000-0000-0000-0000-000000000001}')
                            if ($trigger_result.ReturnValue -and $trigger_result.ReturnValue -ne 0) {
                                $Global:cmch_check_board.Rows.Find('HardwareInventory').IsCompliant = $false
                                if ($Global:cmch_config.HardwareInventory.ReinstallOnAutoFixFailure) {
                                    Invoke-CMCHWriteLog "Trigger schedule for hardware inventory failed. Returned '$($trigger_result.ReturnValue)'. Marking client to reinstall." Error
                                    $Global:cmch_is_consistent_client = $false
                                }
                                else {
                                    Invoke-CMCHWriteLog 'Hardware inventory auto-fix failed, but reinstall for failed fix is not enabled.' Warning
                                }
                            }
                            else {
                                # Waiting 2 minutes before testing again.
                                Start-Sleep -Seconds 120
                                $instances = $Global:cmch_reusables.QueryCim($query, 'Root/CCM/InvAgt')
                                if ($instances[0].LastCycleStartedDate -lt [datetime]::Now.AddDays( - $Global:cmch_config.HardwareInventory.MaxIntervalDays )) {
                                    $Global:cmch_check_board.Rows.Find('HardwareInventory').IsCompliant = $false
                                    if ($Global:cmch_config.HardwareInventory.ReinstallOnAutoFixFailure) {
                                        Invoke-CMCHWriteLog 'Hardware inventory auto-fix failed. Marking client to reinstall.' Warning
                                        $Global:cmch_is_consistent_client = $false
                                    }
                                    else {
                                        Invoke-CMCHWriteLog 'Hardware inventory auto-fix failed, but reinstall for failed fix is not enabled.' Warning
                                    }
                                }
                                else {
                                    $Global:cmch_check_board.Rows.Find('HardwareInventory').IsCompliant = $true
                                    Invoke-CMCHWriteLog 'Hardware inventory cycle fix succeeded.'
                                }
                            }
                        }
                        catch {
                            $Global:cmch_check_board.Rows.Find('HardwareInventory').IsCompliant = $false
                            if ($Global:cmch_config.HardwareInventory.ReinstallOnAutoFixFailure) {
                                Invoke-CMCHWriteLog 'Hardware inventory auto-fix failed. Marking client to reinstall.' Error
                                Write-ErrorRecord([ref]$_)
                                $Global:cmch_is_consistent_client = $false
                            }
                            else {
                                Invoke-CMCHWriteLog 'Hardware inventory auto-fix failed, but reinstall for failed fix is not enabled.' Error
                                Write-ErrorRecord([ref]$_)
                            }
                        }
                        finally {
                            $sms_client_class.Dispose()
                        }
                    }
                    else {
                        $Global:cmch_check_board.Rows.Find('HardwareInventory').IsCompliant = $false
                        Invoke-CMCHWriteLog 'Last hardware inventory cycle older than the threshold, but auto-fix is not enabled.' Warning
                    }
                }
                else {
                    Invoke-CMCHWriteLog 'Hardware inventory is consistent.'
                    $Global:cmch_check_board.Rows.Find('HardwareInventory').IsCompliant = $true
                }
            }
        }
        catch {
            $Global:cmch_check_board.Rows.Find('HardwareInventory').IsCompliant = $false
            Invoke-CMCHWriteLog 'Error checking last hardware inventory cycle.' Error
            Write-ErrorRecord([ref]$_)
        }
        $Global:cmch_check_board.Rows.Find('HardwareInventory').IsChecked = $true
    }
    #endregion

    #region Software metering driver
    $Global:cmch_current_component = 'SoftwareMetering'
    if ($Global:cmch_is_consistent_client -and $Global:cmch_config.SoftwareMetering.Enabled) {
        Invoke-CMCHWriteLog 'Checking software metering PrepDriver.'

        # Checking if there are errors in the log.
        $log_file_content = Get-Content -Path "$Global:cmch_ccm_install_path\Logs\mtrmgr.log"
        if ($log_file_content -match 'StartPrepDriver - OpenService Failed with Error' -or $log_file_content -match 'Software Metering failed to start PrepDriver') {
            if ($Global:cmch_config.SoftwareMetering.AutoFix) {
                Invoke-CMCHWriteLog "Found errors on 'mtrmgr.log'. Attempting to fix." Error
                try {
                    $reg_splat = @{
                        Path        = 'HKLM:\SOFTWARE\Microsoft\SMS\Client\Configuration\Client Properties'
                        Name        = 'Local SMS Path'
                        ErrorAction = 'Stop'
                    }
                    $local_sms_path = (Get-ItemProperty @reg_splat).'Local SMS Path'
                    if ($local_sms_path) {
                        # This method will call the install part of the driver. Same as using 'Rundll32.exe', but we handle the errors.
                        # https://learn.microsoft.com/en-us/windows/win32/api/setupapi/nf-setupapi-installhinfsectionw
                        [Windows.Utilities.WindowsInstaller]::InstallInfSection("DefaultInstall 128 $([System.IO.Path]::Join($local_sms_path, 'prepdrv.inf'))")

                        # Deleting the log file so the same error doesn't get caught again. The client will recreate it.
                        Stop-Service -Name 'CcmExec' -Force
                        Remove-Item -Path "$Global:cmch_ccm_install_path\Logs\mtrmgr.log" -Force
                        Start-Service -Name 'CcmExec'

                        $Global:cmch_check_board.Rows.Find('SoftwareMetering').IsCompliant = $true
                        Invoke-CMCHWriteLog "Successfully called the default install from 'prepdrv.inf'"
                    }
                    else {
                        Invoke-CMCHWriteLog "Local SMS Path not found in the registry. Marking client to reinstall." Error
                        $Global:cmch_check_board.Rows.Find('SoftwareMetering').IsCompliant = $false
                        $Global:cmch_is_consistent_client = $false
                    }    
                }
                catch {
                    $Global:cmch_check_board.Rows.Find('SoftwareMetering').IsCompliant = $false
                    Invoke-CMCHWriteLog 'Error attempting to fix software metering PrepDriver.' Error
                    Write-ErrorRecord([ref]$_)
                }
            }
            else {
                $Global:cmch_check_board.Rows.Find('SoftwareMetering').IsCompliant = $false
                Invoke-CMCHWriteLog "Found errors on 'mtrmgr.log', but auto-fix is not enabled." Warning
            }
        }
        else {
            $Global:cmch_check_board.Rows.Find('SoftwareMetering').IsCompliant = $true
            Invoke-CMCHWriteLog 'Software metering PrepDriver consistent.'
        }
        $Global:cmch_check_board.Rows.Find('SoftwareMetering').IsChecked = $true
    }
    #endregion

    #region Client settings
    $Global:cmch_current_component = 'ClientSettings'
    if ($Global:cmch_is_consistent_client -and $Global:cmch_config.CheckClientSettings) {
        Invoke-CMCHWriteLog 'Checking client settings.'

        try {
            # Checking if isntances exists in 'CCM_ClientAgentConfig' where policy source is 'CcmTaskSequence'.
            $instances = $Global:cmch_reusables.QueryCim("Select * From CCM_ClientAgentConfig Where PolicySource = 'CcmTaskSequence'", 'Root/CCM/Policy/DefaultMachine/RequestedConfig')
            $instance_count = $instances.Count
            if ($instance_count -gt 0) {
                if ($Global:cmch_config.CheckClientSettings.AutoFix) {
                    Invoke-CMCHWriteLog "Client settings not consistent. Attempting to remove '$instance_count' instances." Error
                
                    $is_reinstall_eligible = $false
                    $processed = 0
                    $failed = 0
                    Write-Progress -Activity 'Applying Client Settings Fix' -Status "Removing instances. $processed/$instance_count."
                    foreach ($policy in $instances) {
                        try {
                            # Removing instances.
                            $Global:cmch_reusables.CimSession.DeleteInstance($policy)
                            Write-Progress -Activity 'Applying Client Settings Fix' -Status "Removing instances. $processed/$instance_count." -PercentComplete (($processed / $instance_count) * 100)
                        }
                        catch {
                            $is_reinstall_eligible = $true
                            Invoke-CMCHWriteLog 'Failed removing an instance.' Error
                            Invoke-CMCHWriteLog "($($error_record.Value.Exception.HResult)) $($error_record.Value.Exception.Message)." Error
                            $failed++
                        }

                        $processed++
                    }
                    Write-Progress -Activity 'Applying Client Settings Fix' -Status "Removing instances. $processed/$instance_count." -Completed

                    if ($is_reinstall_eligible) {
                        $Global:cmch_check_board.Rows.Find('ClientSettings').IsCompliant = $false
                        if ($Global:cmch_config.CheckClientSettings.ReinstallOnAutoFixFailure) {
                            Invoke-CMCHWriteLog "Failed to remove $failed instances. Marking client to reinstall." Error
                            $Global:cmch_is_consistent_client = $false
                        }
                        else {
                            Invoke-CMCHWriteLog "Failed to remove $failed instances, but reinstall for failed fix is not enabled." Error
                        }
                    }
                    else {
                        $Global:cmch_check_board.Rows.Find('ClientSettings').IsCompliant = $true
                        Invoke-CMCHWriteLog 'Client settings fix succeeded.'
                    }
                }
                else {
                    $Global:cmch_check_board.Rows.Find('ClientSettings').IsCompliant = $false
                    Invoke-CMCHWriteLog 'Client settings not consistent, but auto-fix is not enabled.' Warning
                }
            }
            else {
                $Global:cmch_check_board.Rows.Find('ClientSettings').IsCompliant = $true
                Invoke-CMCHWriteLog 'Client settings is consistent.'
            }
        }
        catch {
            $Global:cmch_check_board.Rows.Find('ClientSettings').IsCompliant = $false
            Invoke-CMCHWriteLog 'Failed checking client settings polcies.' Error
            Write-ErrorRecord([ref]$_)
        }
        $Global:cmch_check_board.Rows.Find('ClientSettings').IsChecked = $true
    }
    #endregion

    #region Client state messages
    $Global:cmch_current_component = 'ClientStateMessages'
    if ($Global:cmch_is_consistent_client -and $Global:cmch_config.ClientStateMessages.Enabled) {
        Invoke-CMCHWriteLog 'Checking client state messages.'

        # Checking the logs to see if the client is able to send state messages.
        $statmsg_log_content = Get-Content -Path "$Global:cmch_ccm_install_path\Logs\StateMessage.log"
        if ($statmsg_log_content -match 'Successfully forwarded State Messages to the MP') {
            $Global:cmch_check_board.Rows.Find('ClientStateMessages').IsCompliant = $true
            Invoke-CMCHWriteLog 'State messaging is consistent.'
        }
        else {
            if ($Global:cmch_config.ClientStateMessages.AutoFix) {
                Invoke-CMCHWriteLog 'State messaging not consistent. Remediating.' Error
                try {
                    # Forcing a compliance state refresh.
                    $update_store = New-Object -ComObject 'Microsoft.CCM.UpdatesStore'
                    $update_store.RefreshServerComplianceState()
                    Invoke-CMCHWriteLog 'Auto fix applied.'
                    $Global:cmch_check_board.Rows.Find('ClientStateMessages').IsCompliant = $true
                }
                catch {
                    $Global:cmch_check_board.Rows.Find('ClientStateMessages').IsCompliant = $false
                    Invoke-CMCHWriteLog 'Error applying auto fix for state messaging.' Error
                    Write-ErrorRecord([ref]$_)
                }
                finally {
                    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($update_store)
                }
            }
            else {
                $Global:cmch_check_board.Rows.Find('ClientStateMessages').IsCompliant = $false
                Invoke-CMCHWriteLog 'State messaging not consistent, but auto-fix is not enabled.' Warning
            }
        }
        $Global:cmch_check_board.Rows.Find('ClientStateMessages').IsChecked = $true
    }
    #endregion

    #region Send pending state messages
    $Global:cmch_current_component = 'SendPendingStatMessages'
    if ($Global:cmch_is_consistent_client) {
        Invoke-CMCHWriteLog 'Sending any pending state messages.'
        try {
            $sms_client_class = [wmiclass]'\\.\root\ccm:SMS_Client'
            $trigger_result = $sms_client_class.TriggerSchedule('{00000000-0000-0000-0000-000000000111}')
            if ($trigger_result.ReturnValue -and $trigger_result.ReturnValue -ne 0) {
                Invoke-CMCHWriteLog "Send pending messages failed. 'TriggerSchedule' returned '$trigger_result'." Error
            }
            else {
                Invoke-CMCHWriteLog 'Client action triggered successfully.'
            }
        }
        finally {
            $sms_client_class.Dispose()
        }
    }
    #endregion

    #region Trigger policy machine evaluation
    $Global:cmch_current_component = 'TriggerMachinePolicyEval'
    if ($Global:cmch_is_consistent_client) {
        Invoke-CMCHWriteLog 'Triggering machine policy evaluation cycle.'
        try {
            $sms_client_class = [wmiclass]'\\.\root\ccm:SMS_Client'
            $trigger_result = $sms_client_class.TriggerSchedule('{00000000-0000-0000-0000-000000000022}')
            if ($trigger_result.ReturnValue -and $trigger_result.ReturnValue -ne 0) {
                Invoke-CMCHWriteLog "Machine policy eval. failed. 'TriggerSchedule' returned '$trigger_result'." Error
            }
            else {
                Invoke-CMCHWriteLog 'Client action triggered successfully.'
            }
        }
        finally {
            $sms_client_class.Dispose()
        }
    }
    #endregion

    #endregion

    #region STAGE>_ WINDOWS UPDATE

    #region Windows update
    $Global:cmch_current_component = 'WindowsUpdate'
    if ($Global:cmch_config.WindowsUpdate.GpoErrors.Enabled) {
    
        # TODO: Include the other functions.
        Invoke-CMCHWriteLog 'Checking Windows Update Agent.'
        Test-WinUpdateGpoError -CcmLogPath "$Global:cmch_ccm_install_path\Logs" -LogLineCount $Global:cmch_config.WindowsUpdate.GpoErrors.LogLineCount

        $Global:cmch_check_board.Rows.Find('WindowsUpdate').IsChecked = $true
    }
    #endregion

    #region Required updates
    $Global:cmch_current_component = 'RequiredUpdates'
    if ($Global:cmch_config.WindowsUpdate.RequiredUpdates.Enabled) {
        Invoke-CMCHWriteLog 'Checking required updates.'
        $patches_rel_path = "$($Global:cmch_operating_system_info.Caption)\$($Global:cmch_operating_system_info.BuildNumber)"

        if (!(Test-Path -Path "$($Global:cmch_config.Updates.Share)\$patches_rel_path")) {
            Invoke-CMCHWriteLog "Folder '$($Global:cmch_config.Updates.Share)\$patches_rel_path' not found." Error
            Invoke-CMCHWriteLog "Make sure the share folder structure follows the pattern '\\ComputerName\Share\< OS Caption >\< OS Build Number >' for UNC, or 'DRIVE:\Share\< OS Caption >\< OS Build Number >' for local." Error
        }
        else {
            $kb_list = Get-ChildItem -Path "$($Global:cmch_config.Updates.Share)\$patches_rel_path" -Filter '*KB*.msu'
            if ($kb_list) {
                $installed_hotfix = $Global:cmch_reusables.QueryCim('Select * From Win32_QuickFixEngineering')
                foreach ($patch in $kb_list) {
                    $id_matches = $patch.BaseName | Select-String -Pattern '(?<=KB|kb)(.*?)(?=[^0-9])'
                    if ($id_matches.Matches.Count -gt 0) {
                        $hotfix_id = $id_matches.Matches[0].Value
                        if ($hotfix_id -notin $installed_hotfix.HotFixID) {
                            if ($Global:cmch_config.Updates.AutoFix) {
                                Invoke-CMCHWriteLog "'KB$hotfix_id' not installed. Attempting to install." Error
                                Start-Process -FilePath "$env:SystemRoot\System32\wusa.exe" -ArgumentList "$($patch.FullName) /quiet /norestart" -NoNewWindow -Wait
                                Invoke-CMCHWriteLog 'Installation finished. Check the Windows Update logs for sucess or failure.'
                                $Global:cmch_check_board.Rows.Find('RequiredUpdates').IsCompliant = $true
                            }
                            else {
                                $Global:cmch_check_board.Rows.Find('RequiredUpdates').IsCompliant = $false
                                Invoke-CMCHWriteLog "'KB$hotfix_id' not installed, but auto-fix is disabled." Warning
                            }
                        }
                        else {
                            Invoke-CMCHWriteLog "'KB$hotfix_id' already installed."
                        }
                    }
                    else {
                        $Global:cmch_check_board.Rows.Find('RequiredUpdates').IsCompliant = $false
                        Invoke-CMCHWriteLog "Unable to get hotfix ID from '$($patch.Name)'. Incorrect name format." Error
                    }
                }
            }
            else {
                $Global:cmch_check_board.Rows.Find('RequiredUpdates').IsCompliant = $true
                Invoke-CMCHWriteLog 'No mandatory Windows updates found to install.'
            }    
        }
        $Global:cmch_check_board.Rows.Find('RequiredUpdates').IsChecked = $true
    }
    #endregion

    #endregion

    #region Pending reboot
    $Global:cmch_current_component = 'PendingAndLastReboot'
    Invoke-CMCHWriteLog 'Checking last and pending reboot.'
    $pri = Get-PendingRebootRe
    if ($pending_reboot_info.RebootPending) {

        # Checking if the client is marked to reinstall, and if it failed on certain stages
        # so we can mark it to install after a reboot.
        if (!$Global:cmch_is_consistent_client -and $Global:cmch_check_board.Rows.Where({ $_.IsPendingRebootAware }).Count -gt 0) {
            $Global:cmch_install_after_reboot = $true
        }

        Invoke-CMCHWriteLog 'Computer have a pending reboot.' Warning
        Invoke-CMCHWriteLog @"
Component Based Service: $($pri.CbServicing)
Windows Update: $($pri.WinUpdate)
Client SDK: $($pri.ClientSdk)
Computer rename: $($pri.PcRename)
File rename operations: $($pri.FileRenOps)
File rename count: $($pri.FileRenObj.Count)
"@ Warning
    }
    else {
        Invoke-CMCHWriteLog 'Computer have no pending reboot.'
    }
    Invoke-CMCHWriteLog "Last boot up time: $($Global:cmch_operating_system_info.LastBootUpTime)"
    #endregion
    #endregion

    if ($TestNoInstall) {
        Invoke-CMCHWriteLog 'This run is a test and no uninstall/install will be performed.'
        Invoke-CMCHWriteLog "Client consistent: $($Global:cmch_is_consistent_client)."
        Invoke-CMCHWriteLog $Global:cmch_check_board.Columns
        Invoke-CMCHWriteLog '-------------------------------------------------------------------'
        $sb = [System.Text.StringBuilder]::new()
        foreach ($row in $Global:cmch_check_board.Rows) {
            foreach ($item in $row.ItemArray) {
                [void]$sb.Append("$item ")
            }
            Invoke-CMCHWriteLog $sb.ToString()
            [void]$sb.Clear()
        }
        Start-ExitCleanup
        exit 666
    }

    #region Client reinstall
    if (!$Global:cmch_is_consistent_client) {
        $Global:cmch_current_component = 'ClientUninstallAndCleanup'
        Invoke-CMCHWriteLog 'Client is marked as not consistent. Processing reinstallation.' Warning
        $proceed_with_install = $true
        #region Uninstalling Client
        if (Get-Service -Name 'CcmExec') {
            try {
                if (Test-Path -Path "$env:SystemRoot\ccmsetup\ccmsetup.exe" -PathType Leaf) {
    
                    # Starting uninstall as job.
                    Invoke-CMCHWriteLog 'Uninstalling client.'
                    $uninstall_job = Start-Job -ScriptBlock { Start-Process -FilePath "$env:SystemRoot\ccmsetup\ccmsetup.exe" -ArgumentList '/Uninstall' -NoNewWindow -Wait }
                
                    # Waiting uninstallation to finish.
                    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    while ($ccmsetup_service -or $uninstall_job.JobStateInfo.State -eq 'Running' -or $ccmsetup_process) {
                        $ccmsetup_service = Get-Service -Name 'ccmsetup'
                        $ccmsetup_process = Get-Process -Name 'ccmsetup'
                        Start-Sleep -Milliseconds 100
                    
                        if ($stopwatch.Elapsed.TotalMinutes -ge 1) {
                            Invoke-CMCHWriteLog "Waiting for uninstall to finish. Service state: $($ccmsetup_service.Status). Job state: $($uninstall_job.JobStateInfo.State)."
                            $stopwatch.Restart()
                        }
                    }
                    $stopwatch.Stop()

                    Invoke-CMCHWriteLog 'Waiting 3 minutes to make sure all handles were closed before cleanup.'
                    Start-Sleep -Seconds 180
                }
                else {
                    if ((Get-Service -Name 'CcmExec')) {
                        if (!(Test-Path -Path "$($Global:cmch_config.Client.Share)\ccmsetup.exe" -PathType 'Leaf')) {
                            Invoke-CMCHWriteLog "Client is installed, but 'ccmsetup.exe' was not found locally or on the share '$($Global:cmch_config.Client.Share)'." Error
                            Invoke-CMCHWriteLog 'Check the client share config, and try again. Proceeding with cleanup witout installing.' Error
                            $proceed_with_install = $false
                        }
                        else {
                            Invoke-CMCHWriteLog "Client is installed, but 'ccmsetup.exe' not found locally. Running from the share."
                            $uninstall_job = Start-Job -ScriptBlock { Start-Process -FilePath "$($Global:cmch_config.Client.Share)\ccmsetup.exe" -ArgumentList '/Uninstall' -NoNewWindow -Wait }
    
                            # Waiting uninstallation to finish.
                            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                            while ($ccmsetup_service -or $uninstall_job.JobStateInfo.State -eq 'Running' -or $ccmsetup_process) {
                                $ccmsetup_service = Get-Service -Name 'ccmsetup'
                                $ccmsetup_process = Get-Process -Name 'ccmsetup'
                                Start-Sleep -Milliseconds 100
                            
                                if ($stopwatch.Elapsed.TotalMinutes -ge 1) {
                                    Invoke-CMCHWriteLog "Waiting for uninstall to finish. Service state: $($ccmsetup_service.Status). Job state: $($uninstall_job.JobStateInfo.State)."
                                    $stopwatch.Restart()
                                }
                            }
                            $stopwatch.Stop()

                            Invoke-CMCHWriteLog 'Waiting 3 minutes to make sure all handles were closed before cleanup.'
                            Start-Sleep -Seconds 180
                        }
                    }
                    else {
                        Invoke-CMCHWriteLog "Client not installed, and 'ccmsetup.exe' was not found locally or on the share '$($Global:cmch_config.Client.Share)'." Error
                        Invoke-CMCHWriteLog 'Check the client share config, and try again. Proceeding with cleanup witout installing.' Error
                        $proceed_with_install = $false
                    }
                }    
            }
            catch {
                Invoke-CMCHWriteLog 'Failed uninstalling the client.' Error
                Write-ErrorRecord([ref]$_)
            }
        }
        #endregion

        #region Item Provider Cleanup
        Invoke-CMCHWriteLog 'Cleaning files and registry.'
        foreach ($item_path in @(
            'HKLM:\SOFTWARE\Microsoft\SMS'
            'HKLM:\SOFTWARE\Microsoft\CCM'
            'HKLM:\SOFTWARE\Microsoft\CCMSetup'
            "$env:SystemRoot\ccm*"
        )) {
            try {
                Remove-Item -Path $item_path -Recurse -Force -ErrorAction Stop
                Invoke-CMCHWriteLog "Removed item '$item_path'."
            }
            catch {
                Invoke-CMCHWriteLog "Failed removing item '$item_path'." Error
                Write-ErrorRecord([ref]$_)
            }
        }
        #endregion

        #region WMI
        Invoke-CMCHWriteLog 'Removing WMI namespaces.'
        foreach ($namespace in @('ROOT/CCM', 'ROOT/Microsoft/PolicyPlatform')) {
            try {
                $split = $namespace.Split('/')
                $namespace_name = $split | Select-Object -Last 1
                $root_namespace = [string]::Join('/', $split[0..$split.Length - 2])

                $namspace_instance = $Global:cmch_reusables.QueryCim("Select Name From __NAMESPACE Where Name = '$namespace_name'", $root_namespace)
                if ($namspace_instance.Count -gt 0) {
                    Remove-WmiSchemaRecursively($namespace)
                }
            }
            catch { }
        }
        #endregion

        #region Re-compiling MOFs
        if (![bool](Get-ItemProperty -Path $Global:cmch_registry_location).UninstallerCompiledMofs) {
            Invoke-CMCHWriteLog 'Recompiling MOF files.'
            [System.Collections.Generic.HashSet[string]]$files_to_recompile = @()
            foreach ($file in (Get-ChildItem -Path "$env:SystemRoot\System32" -Filter '*.mof')) { [void]$files_to_recompile.Add($file.FullName) }
            [void]$files_to_recompile.Add('C:\Program Files\Microsoft Policy Platform\SchemaNamespaces.mof')
            [void]$files_to_recompile.Add('C:\Program Files\Microsoft Policy Platform\ExtendedStatus.mof')

            foreach ($file in $files_to_recompile) {
                $mofcomp_result = & "$env:SystemRoot\System32\wbem\mofcomp.exe" $file
                if ($mofcomp_result -match 'MOF file has been successfully parsed') {
                    Invoke-CMCHWriteLog "'$file' was compiled successfully."
                }
                else {
                    $error_match = $mofcomp_result | Select-String '(?<=Compiler returned error )(.*?)$'
                    if ($error_match.Matches.Count -gt 0) {
                        $error_code = $error_match.Matches[0].Value
                    }
                    else {
                        $error_code = 'N/A'
                    }
                    Invoke-CMCHWriteLog "Failed compiling '$file'. Compiler returned '$error_code'." Error
                }
            }

            # Marking the MOF compilation so we don't repeat it if the client is not installed.
            Set-ItemProperty -Path $Global:cmch_registry_location -Name 'UninstallerCompiledMofs' -Value $true
        }
        else {
            Invoke-CMCHWriteLog 'MOFs already compiled in a previous run.'
        }
        #endregion

        #region Removing services
        Invoke-CMCHWriteLog 'Removing services.'
        foreach ($service in @('CcmExec', 'ccmsetup', 'smstsmgr', 'smsexec')) {
            if (Get-Service -Name 'CcmExec') {
                $service_util = [Windows.Utilities.Service]::new('CcmExec')
                
                # 'Delete($true)' is force all dependent services to stop and delete the service.
                # If any dependent service doesn't stop, or there are handles opened to the service, it gets marked for deletion.
                #
                # TODO: If service was not deleted, install the client in the next boot.
                $service_util.Delete($true)
            }
        }
        Invoke-CMCHWriteLog 'Client uninstallation and cleanup completed.'
        #endregion

        if (!$proceed_with_install) {
            Invoke-CMCHWriteLog "'proceed with install' flag is set to false. Ending execution." Warning
            Start-ExitCleanup
            exit ([AbortReason]::FalseProceedWithInstall.value__)
        }
        #region Installing the installer
        <#
            NOTE:

            The downloader implementation is not complete, and will just copy the files using 'Copy-Item'.
            The installer will do this anyways, so for now the downloader is not worth using.
        #>
        $is_download_disabled = (Get-ItemProperty -Path $Global:cmch_registry_location).DisableDownload
        if (!$is_download_disabled) { $is_download_disabled = 0 }
        if ($Global:cmch_config.Client.DownloadPriorToInstall -and $is_download_disabled -eq 0) {
            Invoke-CMCHWriteLog 'Client installer download enabled. Setting up downloader.'

            # Storing installer binary information.
            Invoke-CMCHWriteLog 'Listing files in the client share.'
            $all_file_info = Get-ChildItem -Path $Global:cmch_config.Client.Share -Recurse -Force

            # To copy file by file, and maintain the same folder structure, we are going to use something I call an Abstract Path Tree.
            # We are passing parameters as reference because this function was created to handle them with performance in mind.
            Invoke-CMCHWriteLog 'Creating abstract path tree.'
            [System.Collections.Generic.HashSet[PSObject]]$apt = @()
            Get-AbstractPathTreeFromList -the_list ([ref]$all_file_info.FullName) -apt ([ref]$apt)
            
            # Creating destination folder.
            Invoke-CMCHWriteLog 'Creating destination folder.'
            $installer_destination_folder = "$env:SystemRoot\Temp\cmch_ccmsetup"
            if (!(Test-Path -Path $installer_destination_folder)) {
                [void](New-Item -Path "$env:SystemRoot\Temp" -Name 'cmch_ccmsetup' -ItemType 'Directory' -Force)
            }
            Set-ItemProperty -Path $Global:cmch_registry_location -Name 'InstallerDestinationFolder' -Value $installer_destination_folder -Force

            # Storing the hashes so if the process is interrupted, we can continue.
            Invoke-CMCHWriteLog 'Storing installer file metadata on disk.'
            [System.Collections.ArrayList]$installer_file_metadata = @()
            foreach ($file in $all_file_info) {

                # It's a file.
                if (($file.Attributes -band [System.IO.FileAttributes]::Directory) -ne [System.IO.FileAttributes]::Directory) {
                    $apt_info = $apt.Where({ $_.SourcePath -eq $file.FullName })
                    $destination_folder = [System.IO.Path]::GetDirectoryName("$($installer_destination_folder)$($apt_info.RelativePath)")
                    [void]$installer_file_metadata.Add([PSCustomObject]@{
                        FullName = $file.FullName
                        DestinationPath = $destination_folder
                        SHA256Hash = (Get-FileHash -Path $file.FullName -Algorithm 'SHA256').Hash
                    })
                }
            }

            # Exporting file information, and storing info in the registry.
            Invoke-CMCHWriteLog 'Storing metadata file path to the registry.'
            try {
                $file_info_json = "$PSScriptRoot\ccmsetup_file_info-$([datetime]::Now.ToString('yyyyMMddHHmmss.ffff')).json"
                $installer_file_metadata | ConvertTo-Json -ErrorAction 'Stop' | Out-File -FilePath $file_info_json -Force -ErrorAction 'Stop'
            }
            catch {
                $Global:cmch_abort = $true
                Invoke-CMCHWriteLog 'Failed storing file metadata. Execution cannot continue.' Error
                Write-ErrorRecord([ref]$_)
            }

            # Setting abort reason so the script doesn't run again during download / install.
            Invoke-CMCHWriteLog 'Setting abort flags.'
            try {
                Set-ItemProperty -Path $Global:cmch_registry_location -Name 'InstallerFileMetadata' -Value $file_info_json -Force
                Set-ItemProperty -Path $Global:cmch_registry_location -Name 'AbortReason' -Value ([AbortReason]::Downloading)
            }
            catch {
                $Global:cmch_abort = $true
                Invoke-CMCHWriteLog 'Failed storing current state in the registry. Execution cannot continue.' Error
                Write-ErrorRecord([ref]$_)
            }

            Invoke-CMCHWriteLog 'Concatenating installer parameters.'
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

            Invoke-CMCHWriteLog "Storing installer location, client share location, installer parameters and install after reboot in the registry."
            Set-ItemProperty -Path $Global:cmch_registry_location -Name 'ClientShareLocation' -Value $Global:cmch_config.Client.Share -Force
            Set-ItemProperty -Path $Global:cmch_registry_location -Name 'InstallerParameters' -Value $installer_parameters.Trim()
            Set-ItemProperty -Path $Global:cmch_registry_location -Name 'InstallAfterReboot' -Value $Global:cmch_install_after_reboot

            # Creating scheduled tasks.
            Invoke-CMCHWriteLog 'Processing scheduled tasks.'
            if ($Global:last_abort_reason -ne 'DownloaderGetInstallerMetadata') {
                New-DownloaderRecoveryTask
                if ($Global:cmch_install_after_reboot) {
                    New-ClientInstallAfterRebootTask
                }
            }

            # Starting downloader.
            Invoke-CMCHWriteLog 'Creating downloader.'
            $messenger = [hashtable]::Synchronized(@{ DownloadCompleted = $false })

            $pool = [runspacefactory]::CreateRunspacePool()
            $pool.SetMaxRunspaces(2)
            $pool.ApartmentState = 'STA'
            $pool.ThreadOptions = 'UseNewThread'
            $pool.Open()
            $Global:cmch_reusables.DisposableObjects.Add([DisposableObjects]::new($pool))

            $downloader = [powershell]::Create()
            $downloader.RunspacePool = $pool
            [void]$downloader.AddScript("$PSSCriptRoot\Downloader.ps1").AddParameter('Messenger', $messenger)

            Invoke-CMCHWriteLog 'Starting download.'
            [void]$downloader.BeginInvoke()

            Invoke-CMCHWriteLog 'Entering download wait loop.'
            # $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            do {
                # Implement a timeout? Should be handled by the downloader. Maybe.
                Start-Sleep -Seconds 60
            } while (!$messenger.DownloadCompleted -or $downloader.InvocationStateInfo.State -eq 'Running')

            # Donwload failed.
            if (!$messenger.DonwloadCompleted) {
                Invoke-CMCHWriteLog @"
Downloader thread exited but download not marked as complete. Cannot continue.
Downloader state: $($downloader.InvocationStateInfo.State).
Reason: $($downloader.InvocationStateInfo.Reason).
Error stream:
$($downloader.Streams.Error)
"@ Error

                $downloader.Dispose()
                Start-ExitCleanup
                exit -1
            }
            try {
                [void]$downloader.StopAsync($null, $null)
            }
            catch {
                [void]$downloader.Stop()
            }
            $downloader.Dispose()

            # Starting installation.
            Invoke-CMCHWriteLog 'Starting the installation.'
            $installer = [powershell]::Create()
            $installer.RunspacePool = $pool
            [void]$installer.AddScript("$PSSCriptRoot\Installer.ps1")

            # Doing it asynchronously if we need to implement something else later.
            [void]$installer.BeginInvoke()

            do {
                Start-Sleep -Seconds 60
            } while ($installer.InvocationStateInfo.State -eq 'Running')

            if ($installer.HadErrors) {
                Invoke-CMCHWriteLog 'Installer completed, but had errors. Printing last error.'
                Invoke-CMCHWriteLog ($installer.Streams.Error | Select-Object -Last 1).ToString()
            }
            else {
                Invoke-CMCHWriteLog 'Installation completed. Finalizing.'
            }
        }
        #endregion

        #region Installing
        $Global:cmch_current_component = 'ClientInstall'
        else {
            if ($Global:cmch_install_after_reboot) {
                New-ClientInstallAfterRebootTask
                Set-ItemProperty -Path $Global:cmch_registry_location -Name 'AbortReason' -Value ([AbortReason]::InstallPending.ToString())
            }
            else {
                # Starting installation.
                Invoke-CMCHWriteLog 'Starting the installation.'

                $runspace = [runspacefactory]::CreateRunspace()
                $runspace.ApartmentState = 'STA'
                $runspace.ThreadOptions = 'UseNewThread'
                $runspace.Open()
                [void]$Global:cmch_reusables.DisposableObjects.Add([DisposableObjects]::new($runspace))

                $installer = [powershell]::Create()
                $installer.Runspace = $runspace
                [void]$installer.AddScript("$PSSCriptRoot\Installer.ps1")

                # Doing it asynchronously if we need to implement something else later.
                [void]$installer.BeginInvoke()

                Start-Sleep -Seconds 5
                while ($installer.InvocationStateInfo.State -eq 'Running') {
                    Start-Sleep -Seconds 60
                }

                if ($installer.HadErrors) {
                    Invoke-CMCHWriteLog 'Installer completed, but had errors. Printing errors.'
                    foreach ($record in $installer.Streams.Error) {
                        Invoke-CMCHWriteLog $record.ToString()
                    }
                }
                else {
                    Invoke-CMCHWriteLog 'Installation completed. Finalizing.'
                }
            }
        }
        #endregion
    }
    #endregion
}

End {
    #region Cleanup
    # Releasing unmanaged resources.
    $Global:cmch_reusables.DisposeAllInstances()
    $Global:cmch_reusables.CloseCimSession()

    # Managed resources.
    foreach ($global_variable in $(
        'cmch_current_component'
        'cmch_log_file_path'
        'cmch_config_imported'
        'cmch_bits_module_imported'
        'cmch_registry_location'
        'cmch_is_consistent_client'
        'cmch_operating_system_info'
        'cmch_ccm_install_path'
        'cmch_reusables'
        'cmch_config'
    )) {
        Remove-Variable -Name $global_variable -Scope 'Global' -Force
    }

    [GC]::Collect()
    #endregion
}