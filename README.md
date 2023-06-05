# Configuration Manager Client Device Monitor

These scripts are based on the Config. Manager Client Health script,
with added features, and overall modernization.
You can find more information on their [GitHub page](https://github.com/AndersRodland/ConfigMgrClientHealth).

## Main script

The main script is responsible for performing the checks, and determining if the client is healthy.
If it's not, it triggers a reinstallation.
It also checks some Operating System key components.
The main script uses settings from a configuration file called `appsettings.json`, in the script's root directory. You can
find the documentation for all the options [here](Configuration%20file.md).
  
The complete list of tests is:

- Pre-client checks
  - WMI repository
  - DNS name resolution
  - Background Intelligent Transfer Service (BITS)
  - `ADMIN$` and `C$` shares
  - Device drivers (check only)
  - System drive free space (check only)
  - Services startup type and status (listed in the config file)
- Client checks
  - Client database and WMI provider
  - Client version
  - `smstsmgr`service dependency
  - Assigned site code
  - Client cache size
  - Client logging configuration
  - Provisioning mode
  - Client certificate
  - Hardware inventory cycle
  - Client settings
  - State messages
- Windows update
  - Agent handler, and group policy errors
  - Required updates (not tested so far)
- Pending reboot and last boot up time

## Installer

This script is called whenever a client installation is needed.
Uninstall and cleanup are done by the main script. If the main script determines the installation
needs to be done after a reboot, the installer will be called by a scheduled task.

## Downloader

This script is currently under development. Its main purpose is to download the client installation files
before the installation, to avoid disruptions. It most likely will use the BITS APIs.
You can enable the downloader via the config file.