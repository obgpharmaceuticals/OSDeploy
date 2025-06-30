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
        '1' { $GroupTag = "ProductivityDesktop" }
        '2' { $GroupTag = "ProductivityLaptop" }
        '3' { $GroupTag = "LineOfBusinessDesktop" }
        default {
            Write-Warning "Invalid choice. Defaulting to ProductivityDesktop"
            $GroupTag = "ProductivityDesktop"
        }
    }
    Write-Host "GroupTag set to: $GroupTag"

    $DiskNumber = 0

    # Clear Disk 0 including OEM partitions
    Write-Host "Clearing disk $DiskNumber including OEM partitions..."
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false

    # Initialize disk as GPT
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -Confirm:$false

    # Ensure disk is online and writable
    Set-Disk -Number $DiskNumber -IsOffline $false
    Set-Disk -Number $DiskNumber -IsReadOnly $false

    # Create EFI System Partition (100MB), assign no drive letter yet
    $ESPPartition = New-Partition -DiskNumber $DiskNumber -Size 100MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
    Format-Volume -Partition $ESPPartition -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false

    # Assign drive letter S: to EFI partition to prepare boot files
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $ESPPartition.PartitionNumber -NewDriveLetter S

    # Create MSR partition (128MB)
    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null

    # Create Windows partition using remaining space
    $OSPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize
    Format-Volume -Partition $OSPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false

    # Assign drive letter C: to Windows partition
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $OSPartition.PartitionNumber -NewDriveLetter C

    Write-Host "Disk partitions created and formatted:"
    Write-Host "EFI partition: S:"
    Write-Host "Windows partition: C:"

    # Wait for network connectivity
    Write-Host "Waiting for network connectivity to 10.1.192.20..."
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-Connection -ComputerName 10.1.192.20 -Count 1 -Quiet) {
            Write-Host "Network is available."
            break
        }
        Start-Sleep -Seconds 2
        if ($i -eq 29) { throw "Network not available after timeout." }
    }

    # Map network share as M:
    $NetworkPath = "\\10.1.192.20\ReadOnlyShare"
    $DriveLetter = "M:"
    net use $DriveLetter /delete /yes > $null 2>&1
    Write-Host "Mapping $DriveLetter to $NetworkPath..."
    $mapResult = net use $DriveLetter $NetworkPath /persistent:no 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to map $DriveLetter to $NetworkPath. Error details: $mapResult"
    }

    # Apply WIM image to C:
    $WimPath = "M:\install.wim"
    if (-not (Test-Path $WimPath)) {
        throw "WIM file not found at $WimPath"
    }
    Write-Host "Applying Windows image from $WimPath to C:..."
    $dism = Start-Process -FilePath dism.exe -ArgumentList "/Apply-Image", "/ImageFile:$WimPath", "/Index:1", "/ApplyDir:C:\" -Wait -PassThru
    if ($dism.ExitCode -ne 0) {
        throw "DISM failed with exit code $($dism.ExitCode)"
    }

    # Verify boot files presence in Windows image
    if (-not (Test-Path "C:\Windows\Boot\EFI\bootmgfw.efi")) {
        Write-Warning "Boot files missing in C:\Windows\Boot\EFI. Proceeding anyway..."
    } else {
        Write-Host "Boot files found in C:\Windows\Boot\EFI."
    }

    # Ensure EFI boot folder structure on S:
    $efiBootPath = "S:\EFI\Microsoft\Boot"
    if (-not (Test-Path $efiBootPath)) {
        Write-Host "Creating EFI folder structure at $efiBootPath..."
        New-Item -Path $efiBootPath -ItemType Directory -Force | Out-Null
    }

    # Run bcdboot to create UEFI boot files on EFI partition
    Write-Host "Running bcdboot to create UEFI boot files..."
    $bcdbootResult = bcdboot C:\Windows /s S: /f UEFI
    Write-Host $bcdbootResult

    # Confirm boot files were created
    if (-not (Test-Path "$efiBootPath\bootmgfw.efi")) {
        throw "bcdboot failed to create boot files. System may not boot."
    } else {
        Write-Host "Boot files successfully created on EFI partition."
    }

    # Optional: remove S: drive letter (commented out if you want to keep it)
    # Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $ESPPartition.PartitionNumber -AccessPath "S:\" -ErrorAction SilentlyContinue

    # Create required folder structure for Autopilot and unattend files
    $requiredFolders = @(
        "C:\Windows\Panther\Unattend",
        "C:\Windows\Setup\Scripts",
        "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
    )
    foreach ($folder in $requiredFolders) {
        if (-not (Test-Path $folder)) {
            Write-Host "Creating folder: $folder"
            New-Item -Path $folder -ItemType Directory -Force | Out-Null
        }
    }

    # Autopilot configuration
    $AutopilotFolder = "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
    $AutopilotConfig = @{
        CloudAssignedTenantId     = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain = "obgpharma.onmicrosoft.com"
        GroupTag                  = $GroupTag
    }
    $AutopilotConfig | ConvertTo-Json -Depth 3 | Out-File "$AutopilotFolder\AutopilotConfigurationFile.json" -Encoding UTF8

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
            "Microsoft.ZuneMusic", "Microsoft.XboxApp", "Microsoft.XboxGameOverlay",
            "Microsoft.XboxGamingOverlay", "Microsoft.XboxSpeechToTextOverlay",
            "Microsoft.YourPhone", "Microsoft.Getstarted", "Microsoft.3DBuilder"
        )
    }
    $OOBEJson | ConvertTo-Json -Depth 5 | Out-File "$AutopilotFolder\OOBE.json" -Encoding UTF8

    # Write unattend.xml with UK locale settings
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
  </settings>
</unattend>
"@
    $UnattendPath = "C:\Windows\Panther\Unattend\Unattend.xml"
    Set-Content -Path $UnattendPath -Value $UnattendXml -Encoding UTF8

    # Download Get-WindowsAutoPilotInfo.ps1 script
    $AutoPilotScriptPath = "C:\Autopilot\Get-WindowsAutoPilotInfo.ps1"
    $AutoPilotScriptURL = "http://10.1.192.20/Get-WindowsAutoPilotInfo.ps1"
    New-Item -ItemType Directory -Path "C:\Autopilot" -Force | Out-Null
    try {
        Invoke-WebRequest -Uri $AutoPilotScriptURL -OutFile $AutoPilotScriptPath -UseBasicParsing -ErrorAction Stop
        Write-Host "Downloaded Get-WindowsAutoPilotInfo.ps1 successfully."
    } catch {
        Write-Warning "Failed to download Autopilot script: $_"
    }

    # Write SetupComplete.cmd to run Autopilot hardware hash upload
    $SetupCompletePath = "C:\Windows\Setup\Scripts\SetupComplete.cmd"
    $SetupCompleteContent = @"
@echo off
set LOGFILE=C:\Autopilot-Diag.txt
set SCRIPT=C:\Autopilot\Get-WindowsAutoPilotInfo.ps1

echo ==== AUTOPILOT SETUP ==== >> %LOGFILE%
echo Timestamp: %DATE% %TIME% >> %LOGFILE%

timeout /t 10 > nul

if exist "%SCRIPT%" (
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%SCRIPT%" -TenantId "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee" -AppId "faa1bc75-81c7-4750-ac62-1e5ea3ac48c5" -AppSecret "ouu8Q~h2IxPhfb3GP~o2pQOvn2HSmBkOm2D8hcB-" -GroupTag "$GroupTag" -Online -Assign >> %LOGFILE% 2>&1
) else (
    echo ERROR: Script not found at %SCRIPT% >> %LOGFILE%
)

echo Waiting 300 seconds (5 minutes) to ensure upload finishes and prevent reboot... >> %LOGFILE%
timeout /t 300 /nobreak > nul

echo SetupComplete.cmd finished at %DATE% %TIME% >> %LOGFILE%
exit /b 0
"@
    Set-Content -Path $SetupCompletePath -Value $SetupCompleteContent -Encoding ASCII

    Write-Host "SetupComplete.cmd created successfully."

    Write-Host "Deployment script completed. Rebooting in 5 seconds..."
    Start-Sleep -Seconds 5
    # Restart-Computer -Force
}
catch {
    Write-Error "Deployment failed: $_"
}
finally {
    try { Stop-Transcript } catch {}
}
