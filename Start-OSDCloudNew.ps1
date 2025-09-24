# =============================================
# Windows 11 Deployment Script with Offline Driver Injection
# =============================================

# Start transcript for WinPE logging
Start-Transcript -Path "X:\DeployScript.log" -Append

try {
    Write-Host "Starting Windows 11 OBG deployment..." -ForegroundColor Cyan

    # -----------------------------
    # Prompt for system type
    # -----------------------------
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

    # -----------------------------
    # Select disk to wipe and deploy
    # -----------------------------
    $Disk = Get-Disk | Where-Object {
        $_.IsSystem -eq $false -and
        $_.OperationalStatus -eq "Online" -and
        $_.BusType -in @("NVMe", "SATA", "SCSI", "ATA")
    } | Sort-Object -Property Size -Descending | Select-Object -First 1

    if (-not $Disk) { throw "No suitable disk found for installation." }

    $DiskNumber = $Disk.Number
    Write-Host "Selected disk number $DiskNumber ($($Disk.FriendlyName))"

    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -Confirm:$false
    Set-Disk -Number $DiskNumber -IsOffline $false
    Set-Disk -Number $DiskNumber -IsReadOnly $false

    # -----------------------------
    # Partition disk
    # -----------------------------
    $ESP = New-Partition -DiskNumber $DiskNumber -Size 512MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
    Format-Volume -Partition $ESP -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    $ESP | Set-Partition -NewDriveLetter S

    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null

    $OSPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize
    Format-Volume -Partition $OSPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $OSPartition.PartitionNumber -NewDriveLetter C

    Write-Host "Disk $DiskNumber partitioned successfully."

    # -----------------------------
    # Determine client IP & deployment server
    # -----------------------------
    $ClientIP = (Get-WmiObject Win32_NetworkAdapterConfiguration |
        Where-Object { $_.IPEnabled -eq $true -and $_.IPAddress -ne $null } |
        ForEach-Object { $_.IPAddress } |
        Where-Object { $_ -notlike "169.*" -and $_ -ne "127.0.0.1" } |
        Select-Object -First 1)
    if (-not $ClientIP) { throw "Could not determine client IP address." }
    Write-Host "Client IP detected: $ClientIP"

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

    $NetworkPath = "\\$ServerIP\ReadOnlyShare"
    $DriveLetter = "M:"
    net use $DriveLetter /delete /yes > $null 2>&1
    net use $DriveLetter $NetworkPath /persistent:no | Out-Null

    # -----------------------------
    # Apply WIM image
    # -----------------------------
    $WimPath = "M:\install.wim"
    if (-not (Test-Path $WimPath)) { throw "WIM file not found at $WimPath" }
    Write-Host "Applying Windows image from $WimPath to C:..."
    $dism = Start-Process -FilePath dism.exe -ArgumentList "/Apply-Image", "/ImageFile:$WimPath", "/Index:6", "/ApplyDir:C:\" -Wait -PassThru
    if ($dism.ExitCode -ne 0) { throw "DISM failed with exit code $($dism.ExitCode)" }

    # -----------------------------
    # Import OSD modules & inject drivers
    # -----------------------------
    Write-Host "Importing OSD and OSDCloud modules..."
    Import-Module "X:\Windows\System32\WindowsPowerShell\v1.0\Modules\OSD\OSD.psm1" -Force -ErrorAction Stop
    Import-Module "X:\Windows\System32\WindowsPowerShell\v1.0\Modules\OSDCloud\OSDCloud.psm1" -Force -ErrorAction Stop

    $Model = Get-OSDComputerModel
    if (-not $Model) { $Model = "<unknown>" }
    Write-Host "Detected model: $Model"

    $LogFile = "X:\DeployScript.log"
    Add-Content -Path $LogFile -Value ("Detected model: $Model")

    Write-Host "Injecting drivers into offline Windows (C:\)..."
    Invoke-OSDCloudDriverPackCM -ComputerModel $Model -Target 'C:\' -ForceUnsigned -Verbose | ForEach-Object {
        Add-Content -Path $LogFile -Value $_
    }
    Write-Host "Driver injection complete."
    Add-Content -Path $LogFile -Value "Driver injection complete."

    # -----------------------------
    # Configure boot files (UEFI)
    # -----------------------------
    if (-not (Test-Path "S:\EFI\Microsoft\Boot")) { New-Item -Path "S:\EFI\Microsoft\Boot" -ItemType Directory -Force | Out-Null }
    bcdboot C:\Windows /s S: /f UEFI
    if (-not (Test-Path "S:\EFI\Boot")) { New-Item -Path "S:\EFI\Boot" -ItemType Directory -Force | Out-Null }
    Copy-Item -Path "S:\EFI\Microsoft\Boot\bootmgfw.efi" -Destination "S:\EFI\Boot\bootx64.efi" -Force

    # -----------------------------
    # Create Autopilot JSON files
    # -----------------------------
    $AutopilotFolder = "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
    foreach ($Folder in @($AutopilotFolder, "C:\Autopilot")) {
        if (-not (Test-Path $Folder)) { New-Item -Path $Folder -ItemType Directory -Force | Out-Null }
    }

    $AutopilotConfig = @{
        CloudAssignedTenantId     = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain = "obgpharma.onmicrosoft.com"
        GroupTag                  = $GroupTag
    }
    $AutopilotConfig | ConvertTo-Json -Depth 3 | Set-Content "$AutopilotFolder\AutopilotConfigurationFile.json" -Encoding utf8

    $OOBEJson = @{
        CloudAssignedTenantId         = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain     = "obgpharma.onmicrosoft.com"
        DeviceType                    = $GroupTag
        EnableUserStatusTracking      = $true
        EnableUserConfirmation        = $true
        EnableProvisioningDiagnostics = $true
        DeviceLicensingType           = "WindowsEnterprise"
        Language                      = "en-GB"
        SkipZDP                       = $true
        RemovePreInstalledApps        = @(
            "Microsoft.ZuneMusic","Microsoft.XboxApp","Microsoft.XboxGameOverlay",
            "Microsoft.XboxGamingOverlay","Microsoft.XboxSpeechToTextOverlay",
            "Microsoft.YourPhone","Microsoft.Getstarted","Microsoft.3DBuilder"
        )
    }
    $OOBEJson | ConvertTo-Json -Depth 5 | Set-Content "$AutopilotFolder\OOBE.json" -Encoding utf8

    # Copy JSONs to legacy pickup path
    $LegacyDir = "C:\Windows\Provisioning\Autopilot"
    if (-not (Test-Path $LegacyDir)) { New-Item -Path $LegacyDir -ItemType Directory -Force | Out-Null }
    Copy-Item "$AutopilotFolder\AutopilotConfigurationFile.json" "$LegacyDir\AutopilotConfigurationFile.json" -Force
    Copy-Item "$AutopilotFolder\OOBE.json" "$LegacyDir\OOBE.json" -Force

    Write-Host "Autopilot JSON files created successfully."

    # -----------------------------
    # Create Unattend.xml
    # -----------------------------
    $UnattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>en-GB</InputLocale>
      <SystemLocale>en-GB</SystemLocale>
      <UILanguage>en-GB</UILanguage>
      <UserLocale>en-GB</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>1</ProtectYourPC>
      </OOBE>
    </component>
  </settings>
</unattend>
"@
    $UnattendPath = "C:\Windows\Panther\Unattend\Unattend.xml"
    Set-Content -Path $UnattendPath -Value $UnattendXml -Encoding UTF8

    # -----------------------------
    # Download Autopilot script
    # -----------------------------
    $AutoPilotScriptPath = "C:\Autopilot\Get-WindowsAutoPilotInfo.ps1"
    $AutoPilotScriptURL = "http://$ServerIP/Get-WindowsAutoPilotInfo.ps1"
    Invoke-WebRequest -Uri $AutoPilotScriptURL -OutFile $AutoPilotScriptPath -UseBasicParsing -ErrorAction Stop
    Write-Host "Downloaded Get-WindowsAutoPilotInfo.ps1 successfully."

    Write-Host "Deployment completed successfully. Rebooting in 5 seconds..."
    Start-Sleep -Seconds 5
    # Restart-Computer -Force

} catch {
    Write-Error "Deployment failed: $_"
} finally {
    try { Stop-Transcript } catch {}
}
