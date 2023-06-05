# Script configuration file

The script configuration file consists of a JSON file. It contains most of the options from the
original script, plus extras.

## Options

### Client

Under **Client** you can find the required client characteristics, settings, and installation parameters.

- Version: The required client version.
- SiteCode: The required assigned SMS site code.
- Share: The share location for the client installation files.
- DownloadPriorToInstall: Enables the downloader (not fully implemented yet).
- DownloadRetries: The number of retries to download the client installation files.
- WaitForShareTime: If the files in the path described in the **Share** option is not available. This property.
  tells how long the installer, and uninstaller should wait for availability, in minutes.
- InstallRetries: The number of retries to install the client.
- CacheInfo
  - CacheSize: The client cache size in bytes.
  - DeleteOrphanedData: Currently not implemented.
  - Enabled: Enables the check.
- LogInfo
  - MaxLogFileSize: The maximum size of a single log file.
  - SizeUnit: The size unit for the **MaxLogFileSize** property. `0` for kilobytes, and `1` for megabytes.
  - MaxLogHistory: The maximum number of log file history for a configuration manager log.
  - Enabled: Enables the check.
- InstallParameters: The installation parameters. More information about them can be found at the [Microsoft documentation](https://learn.microsoft.com/en-us/mem/configmgr/core/clients/deploy/about-client-installation-properties) site.

### Log

Under **Log** are the logging settings for the solution itself.

- Path: The main script log path.
- Downloader: The downloader log path.
- Installer: The installer log path.
- MaxLogHistory: The number of log files to be kept as history for the 3 scripts.
- MaxLogFileSize: The maximum size for a single log file.
- SizeUnit:  The size unit for the **MaxLogFileSize** property. `0` for kilobytes, and `1` for megabytes.
- ServerSideLogging: Not yet implemented.

### WindowsUpdate

Under **WindowsUpdate** are the options for the Windows update checks.

- ResetWUComponentsOnFail: Not yet implemented. The function was created, but still needs testing. Performs the steps described on [Additional resources for Windows update](https://learn.microsoft.com/en-us/troubleshoot/windows-client/deployment/additional-resources-for-windows-update)
- GpoErrors
  - Enabled: Enables the test.
  - AutoFix: Enables the auto fix.
  - LogLineCount: The number of lines from the log to look for errors.
  - PolicyDbFileAgeDays: The maximum number of days since the last write on the group policy database file.
- CodeSigningCert (not implemented yet)
  - Enabled: Enables the check.
  - AutoFix: Enables the auto fix.
  - CertThumbprint: The certificate thumbprint used in the auto fix.
  - CertEncodedString: The base-64 string representing the certificate.
- RequiredUpdates
    - Share: The share folder where the required .msu KBs will be.
    - Enabled: Enables the check.
    - AutoFix: Enables the auto fix.

### Services

This part of the main script checks the status, and startup type of the services listed there.
Startup type values:

- 0: Boot (includeded for compatibility. is converted to 'Automatic')
- 1: System (includeded for compatibility. is converted to 'Automatic')
- 2: Automatic
- 3: Manual
- 4: Disabled
- 5: Automatic delayed start.

Status values:

- 1: Stopped
- 4: Running
- 7: Paused

### Remaining items

- Drivers: Checks for failed or invalid device drivers.
- CheckClientDatabase: Checks the client database files integrity using the SQLCE engine.
- CheckBits: Checks for Background Intelligent Transfer Service for failed jobs.
- CheckClientSettings: Controls the client settings check part of the script.
- CheckDns: Controls the DNS check.
- Reboot: Not yet implemented.
- OsDiskFreeSpace: Controls the system drive free space test
  - SpaceUnit. 0: Kb, 1: Mb, 2: Gb, 3: Tb.
- HardwareInventory: Controls the hardware inventory check.
- SoftwareMetering: Controls the software meetering prep drive.
- Wmi: Controls the WMI part of the test.
- AdminShare: Controls the admin share part of the test.
- ClientProvisioningMode: Controls the client provisioning mode test.
- ClientCertificate: Controls the client certificate part of the test.
- ClientStateMessage: Controls the client state message part of the test.

### ComponentList

This list is used to control the status of the test, and no action is needed. This is there to provide compatibility with future enhancements. Do not modify.