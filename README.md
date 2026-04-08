# VELOCIRAPTOR-CLIENT-UPGRADE

PowerShell script to upgrade the **Velociraptor Windows client** to **0.76.2** using the endpoint's **existing configuration**.

This script is designed for environments where the client is already installed and a valid Velociraptor config is already present on the endpoint. It downloads the official MSI, upgrades the client in place, preserves the existing config, preserves the existing writeback file, auto-detects the installed service name, and verifies that the client is running after the upgrade.

## Why this exists

The official Velociraptor Windows MSI is the recommended installation method for Windows clients, but the client configuration must be provided separately. During upgrades, it is important to preserve the existing endpoint configuration and client identity rather than replacing them with a stock placeholder or forcing re-enrollment.

This script is built for that use case.

## What the script does

- Downloads the official Velociraptor **0.76.2** Windows MSI
- Detects the installed Velociraptor Windows service automatically
- Stops the service if it already exists
- Backs up the endpoint's existing `client.config.yaml`
- Installs the MSI silently using `msiexec`
- Restores the original `client.config.yaml` after the MSI install
- Preserves `velociraptor.writeback.yaml`
- Starts the service again
- Verifies the service is running
- Verifies the installed binary version matches the expected version unless version checking is skipped

## Script location

`windows_velo_client_upgrade.ps1`

## Requirements

- Windows endpoint with PowerShell **5.1** or later
- Local administrator privileges
- Existing Velociraptor client already installed
- Existing valid config present on the endpoint at:
  ```
  C:\Program Files\Velociraptor\client.config.yaml
  ```
- Internet access to download the MSI from GitHub, or ability to modify the script to use an internal download source

## Default download URL

The script downloads this MSI by default:

```
https://github.com/Velocidex/velociraptor/releases/download/v0.76/velociraptor-v0.76.2-windows-amd64.msi
```

## Default paths

### Velociraptor install paths

```
C:\Program Files\Velociraptor\Velociraptor.exe
C:\Program Files\Velociraptor\client.config.yaml
C:\Program Files\Velociraptor\velociraptor.writeback.yaml
```

### Working paths

```
C:\ProgramData\Velociraptor\Downloads
C:\ProgramData\Velociraptor\Logs
C:\ProgramData\Velociraptor\Backup
```

## Usage

Run the script as Administrator:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\windows_velo_client_upgrade.ps1
```

### Optional parameters

#### `-DownloadUrl`

Override the default MSI download URL.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\windows_velo_client_upgrade.ps1 -DownloadUrl "https://your-internal-repo.example.com/velociraptor-v0.76.2-windows-amd64.msi"
```

#### `-ExpectedVersion`

Override the expected installed version.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\windows_velo_client_upgrade.ps1 -ExpectedVersion "0.76.2"
```

#### `-WorkingDirectory`

Override the working directory used for downloads, logs, and backups.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\windows_velo_client_upgrade.ps1 -WorkingDirectory "D:\VelociraptorUpgrade"
```

#### `-SkipVersionCheck`

Skip post-install version validation.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\windows_velo_client_upgrade.ps1 -SkipVersionCheck
```

## How it works

1. Creates working directories if they do not already exist
2. Confirms the script is running as Administrator
3. Detects the existing Velociraptor service by:
   - service name
   - display name
   - executable path
4. Stops the detected service if present
5. Backs up the current `client.config.yaml`
6. Downloads the official MSI
7. Installs the MSI silently
8. Restores the original `client.config.yaml`
9. Detects the post-install service again
10. Starts the service
11. Confirms the service is running
12. Confirms the installed version matches the expected version unless skipped

## Logging

The script writes logs to:

```
C:\ProgramData\Velociraptor\Logs\velociraptor-upgrade.log
```

The MSI verbose log is written to:

```
C:\ProgramData\Velociraptor\Logs\velociraptor-msi-install.log
```

## Backup behavior

Before installing the MSI, the script backs up the endpoint's existing config to:

```
C:\ProgramData\Velociraptor\Backup\client.config.yaml.backup
```

This backup is then restored after the MSI install completes.

## Important behavior notes

- This script expects the endpoint to already have a valid Velociraptor config
- This script does not generate a new config
- This script does not repack the MSI
- This script does not modify `velociraptor.writeback.yaml`
- Preserving the existing writeback file helps preserve the existing client identity
- The script is meant for in-place upgrades, not fresh installs

## When to use this script

Use this script when:

- Velociraptor is already installed on the endpoint
- The endpoint already has a valid config
- You want to upgrade the Windows client in place
- You want to preserve the endpoint's existing config and writeback state
- You want the script to automatically detect the service name instead of hardcoding it

## When not to use this script

Do not use this script when:

- The endpoint does not already have a valid config
- You are performing a first-time Velociraptor deployment
- You need a repacked MSI with an embedded config
- You want to intentionally replace the endpoint's current client config

## Notes on service detection

Some environments may show the service with:

- Service name: `Velociraptor`
- Display name: `Velociraptor Service`

Because those can differ, this script auto-detects the installed service instead of assuming a single hardcoded service name.

## Example verification commands

Check the service:

```powershell
Get-Service | Where-Object { $_.Name -match 'Velociraptor' -or $_.DisplayName -match 'Velociraptor' } | Format-Table Name, DisplayName, Status -AutoSize
```

Check the binary path:

```powershell
Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'Velociraptor' } | Select-Object Name, DisplayName, State, PathName
```

## Exit behavior

- Returns `0` on success
- Returns `1` on failure

## Disclaimer

Test in a lab or pilot group before broad deployment. Review the script and adjust paths, download source, and operational controls as needed for your environment.
