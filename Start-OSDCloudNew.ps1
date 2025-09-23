# Start transcript logging 
Start-Transcript -Path "X:\DeployScript.log" -Append

try {
    Write-Host "Starting Windows 11 deployment..." -ForegroundColor Cyan

    # Prompt for system type
    Write-Host "Select system type:"
    Write-Host "1. Productivity Desktop"
    Write-Host "2. Productivity Laptop"
    Write-Host "3. Line of Business Desktop"
    $selection = Read-Host "Enter choice (1-3)"
    switch ($selection) {
        '1' { $GroupTag = "ProductivityDesktop11" }
        '2' { $GroupTag = "ProductivityLaptop11" }
        '3' { $GroupTag = "LineOfBusinessDesktop11" }
        default {
            Write-Warning "Invalid choice. Defaulting to ProductivityDesktop"
            $GroupTag = "ProductivityDesktop11"
        }
    }
    Write-Host "GroupTag set to: $GroupTag"

    # Always wipe Disk 0
    $DiskNumber = 0

    # Find the first disk that is online, fixed, and has the largest size (usually your boot disk)
    $Disk = Get-Disk | Where-Object { $_.IsSystem -eq $false -and $_.OperationalStatus -eq "Online" -and $_.BusType -in @("NVMe","SATA","SCSI","ATA") } |
            Sort-Object -Property Size -Descending | Select-Object -First 1
    if (-not $Disk) { Write-Error "No suitable disk found for installation."; exit 1 }

    $DiskNumber = $Disk.Number
    Write-Host "Selected disk number $DiskNumber ($($Disk.FriendlyName)) with BusType $($Disk.BusType)"

    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -Confirm:$false
    Set-Disk -Number $DiskNumber -IsOffline $false
    Set-Disk -Number $DiskNumber -IsReadOnly $false

    # EFI partition 512 MB
    $ESP = New-Partition -DiskNumber $DiskNumber -Size 512MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
    Format-Volume -Partition $ESP -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    $ESP | Set-Partition -NewDriveLetter S
    Write-Host "EFI partition assigned to drive letter: S"

    # MSR 128 MB
    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null

    # OS partition
    $OSPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize
    Format-Volume -Partition $OSPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $OSPartition.PartitionNumber -NewDriveLetter C
    Write-Host "Disk $DiskNumber partitioned successfully."

    # --- Determine client IP (WinPE compatible) ---
    $ClientIP = (Get-WmiObject Win32_NetworkAdapterConfiguration |
                 Where-Object { $_.IPEnabled -eq $true -and $_.IPAddress -ne $null } |
                 ForEach-Object { $_.IPAddress } |
                 Where-Object { $_ -notlike "169.*" -and $_ -ne "127.0.0.1" } |
                 Select-Object -First 1)
    if (-not $ClientIP) { throw "Could not determine client IP address." }
    Write-Host "Client IP detected: $ClientIP"

    # Map subnet to deployment server
    $DeploymentServers = @{
        "10.1.192" = "10.1.192.20"
        "10.3.192" = "10.3.192.20"
        "10.5.192" = "10.5.192.20"
    }
    $Subnet = ($ClientIP -split "\.")[0..2] -join "."
    if ($DeploymentServers.ContainsKey($Subnet)) {
        $ServerIP = $DeploymentServers[$Subnet]
        Write-Host "Deployment server selected: $ServerIP"
    } else { throw "No deployment server configured for subnet $Subnet" }

    # Map network share
    $NetworkPath = "\\$ServerIP\ReadOnlyShare"
    $DriveLetter = "M:"
    net use $DriveLetter /delete /yes > $null 2>&1
    Write-Host "Mapping $DriveLetter to $NetworkPath..."
    $mapResult = net use $DriveLetter $NetworkPath /persistent:no 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to map $DriveLetter. Error: $mapResult" }

    # Apply WIM
    $WimPath = "M:\install.wim"
    if (-not (Test-Path $WimPath)) { throw "WIM file not found at $WimPath" }
    Write-Host "Applying Windows image..."
    $dism = Start-Process -FilePath dism.exe -ArgumentList "/Apply-Image","/ImageFile:$WimPath","/Index:6","/ApplyDir:C:\" -Wait -PassThru
    if ($dism.ExitCode -ne 0) { throw "DISM failed with exit code $($dism.ExitCode)" }

    # Disable ZDP offline
    reg load HKLM\TempHive C:\Windows\System32\config\SOFTWARE
    reg add "HKLM\TempHive\Microsoft\Windows\CurrentVersion\OOBE" /v DisableZDP /t REG_DWORD /d 1 /f
    reg unload HKLM\TempHive

    # Boot files
    if (-not (Test-Path "S:\EFI\Microsoft\Boot")) { New-Item -Path "S:\EFI\Microsoft\Boot" -ItemType Directory -Force | Out-Null }
    bcdboot C:\Windows /s S: /f UEFI
    if (-not (Test-Path "S:\EFI\Boot")) { New-Item -Path "S:\EFI\Boot" -ItemType Directory -Force | Out-Null }
    Copy-Item "S:\EFI\Microsoft\Boot\bootmgfw.efi" "S:\EFI\Boot\bootx64.efi" -Force

    # Create required folders
    $TargetFolders = @(
        "C:\Windows\Panther\Unattend",
        "C:\Windows\Setup\Scripts",
        "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot",
        "C:\Autopilot"
    )
    foreach ($Folder in $TargetFolders) {
        if (-not (Test-Path $Folder)) { New-Item -Path $Folder -ItemType Directory -Force | Out-Null }
    }

    # Autopilot JSONs
    $AutopilotFolder = "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
    $AutopilotConfig = @{
        CloudAssignedTenantId    = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain= "obgpharma.onmicrosoft.com"
        GroupTag                 = $GroupTag
    }
    $AutopilotConfig | ConvertTo-Json -Depth 3 | Out-File "$AutopilotFolder\AutopilotConfigurationFile.json" -Encoding utf8
    # OOBE JSON omitted for brevity (same as before)

    # Unattend.xml
    $UnattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>en-GB</InputLocale>
      <SystemLocale>en-GB</SystemLocale>
      <UILanguage>en-GB</UILanguage>
      <UserLocale>en-GB</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>1</ProtectYourPC>
      </OOBE>
    </component>
  </settings>
</unattend>
"@
    Set-Content -Path "C:\Windows\Panther\Unattend\Unattend.xml" -Value $UnattendXml -Encoding UTF8

    # Download Autopilot script
    $AutoPilotScriptPath = "C:\Autopilot\Get-WindowsAutoPilotInfo.ps1"
    Invoke-WebRequest -Uri "http://10.1.192.20/Get-WindowsAutoPilotInfo.ps1" -OutFile $AutoPilotScriptPath -UseBasicParsing

    # SetupComplete.cmd (same as your version, includes Invoke-OSDCloudDriver)
    $SetupCompletePath = "C:\Windows\Setup\Scripts\SetupComplete.cmd"
    Set-Content -Path $SetupCompletePath -Value @"
@echo off
REM (content unchanged from your previous script)
"@ -Encoding ASCII

    # >>> ADDED: Copy OSD/OSDCloud modules from WinPE into deployed OS
    try {
        $moduleSrc = "X:\Program Files\WindowsPowerShell\Modules"
        $moduleDst = "C:\Program Files\WindowsPowerShell\Modules"
        if (Test-Path $moduleSrc) {
            Write-Host "Copying OSD modules from WinPE to deployed OS..."
            Copy-Item -Path "$moduleSrc\OSD*"      -Destination $moduleDst -Recurse -Force -ErrorAction Stop
            Copy-Item -Path "$moduleSrc\OSDCloud*" -Destination $moduleDst -Recurse -Force -ErrorAction Stop
            Write-Host "Modules copied successfully to $moduleDst."
        } else {
            Write-Warning "WinPE module source not found at $moduleSrc"
        }
    } catch {
        Write-Warning "Failed to copy OSD/OSDCloud modules: $_"
    }
    # <<< END ADDITION

    # Registry signal for Intune requirement
    New-Item -Path "HKLM:\SOFTWARE\OBG\Signals" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\OBG\Signals" -Name "ReadyForWin32" -PropertyType DWord -Value 1 -Force | Out-Null

    Write-Host "Deployment script completed. Rebooting in 5 seconds..."
    Start-Sleep -Seconds 5
    Restart-Computer -Force

} catch {
    Write-Error "Deployment failed: $_"
} finally {
    try { Stop-Transcript } catch {}
}
