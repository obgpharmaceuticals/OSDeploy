# Start transcript logging
Start-Transcript -Path "X:\DeployScript.log" -Append

try {
    Write-Host "Starting deployment..." -ForegroundColor Cyan

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

    # Select and prepare disk
    $Disk = Get-Disk | Where-Object {
        $_.OperationalStatus -eq 'Online' -and
        ($_.PartitionStyle -eq 'RAW' -or $_.PartitionStyle -eq 'GPT') -and
        $_.Size -gt 30GB
    } | Sort-Object Size -Descending | Select-Object -First 1

    if (-not $Disk) { throw "No suitable disk found." }
    $DiskNumber = $Disk.Number
    Write-Host "Selected disk $DiskNumber (Size: $([math]::Round($Disk.Size/1GB,2)) GB)"

    # Clean and initialize disk
    Write-Host "Cleaning disk $DiskNumber..."
    Clear-Disk -Number $DiskNumber -RemoveData -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT

    # Create partitions
    Write-Host "Creating EFI partition (100 MB)..."
    $EfiPartition = New-Partition -DiskNumber $DiskNumber -Size 100MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
    Write-Host "Creating MSR partition (128 MB)..."
    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null
    Write-Host "Creating Data partition (10 GB)..."
    $DataPartition = New-Partition -DiskNumber $DiskNumber -Size 10GB
    Write-Host "Creating Windows partition (remaining space)..."
    $WindowsPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize

    # Format and assign drive letters
    Write-Host "Formatting EFI partition and assigning drive letter S:"
    Format-Volume -Partition $EfiPartition -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    Start-Sleep -Seconds 3
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $EfiPartition.PartitionNumber -NewDriveLetter S

    Write-Host "Formatting Data partition and assigning drive letter D:"
    Format-Volume -Partition $DataPartition -FileSystem NTFS -NewFileSystemLabel "Data" -Confirm:$false
    Start-Sleep -Seconds 3
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $DataPartition.PartitionNumber -NewDriveLetter D

    Write-Host "Formatting Windows partition and assigning drive letter C:"
    Format-Volume -Partition $WindowsPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Start-Sleep -Seconds 3
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $WindowsPartition.PartitionNumber -NewDriveLetter C

    Write-Host "Partitions created: EFI (S:), Data (D:), Windows (C:)"

    # Apply WIM image to C:
    Write-Host "Applying Windows image to C:..."
    dism.exe /Apply-Image /ImageFile:E:\install.wim /Index:1 /ApplyDir:C:\

    # Setup boot files
    Write-Host "Setting up boot configuration..."
    bcdboot C:\Windows /s S: /f UEFI

    # Create Autopilot provisioning folder
    $AutopilotFolder = "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
    if (-not (Test-Path $AutopilotFolder)) {
        New-Item -Path $AutopilotFolder -ItemType Directory -Force | Out-Null
    }

    # Create AutopilotConfigurationFile.json
    $AutopilotConfig = @{
        CloudAssignedTenantId    = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain = "obgpharma.onmicrosoft.com"
        GroupTag                 = $GroupTag
    }
    $AutopilotConfig | ConvertTo-Json -Depth 3 | Out-File -FilePath "$AutopilotFolder\AutopilotConfigurationFile.json" -Encoding utf8

    # Create OOBE.json
    $OOBEJson = @{
        CloudAssignedTenantId         = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain     = "obgpharma.onmicrosoft.com"
        DeviceType                    = $GroupTag
        EnableUserStatusTracking      = $true
        EnableUserConfirmation        = $true
        EnableProvisioningDiagnostics = $true
        DeviceLicensingType           = "WindowsEnterprise"
        Language                      = "en-GB"
        RemovePreInstalledApps        = @(
            "Microsoft.ZuneMusic", "Microsoft.XboxApp", "Microsoft.XboxGameOverlay",
            "Microsoft.XboxGamingOverlay", "Microsoft.XboxSpeechToTextOverlay",
            "Microsoft.YourPhone", "Microsoft.Getstarted", "Microsoft.3DBuilder"
        )
    }
    $OOBEJson | ConvertTo-Json -Depth 5 | Out-File -FilePath "$AutopilotFolder\OOBE.json" -Encoding utf8

    # Create unattend.xml
    $UnattendPath = "C:\Windows\Panther\Unattend\Unattend.xml"
    New-Item -ItemType Directory -Force -Path (Split-Path $UnattendPath) | Out-Null
    @"
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
"@ | Out-File -Encoding utf8 -FilePath $UnattendPath

    # Create SetupComplete.cmd
    $SetupCompletePath = "C:\Windows\Setup\Scripts\SetupComplete.cmd"
    New-Item -ItemType Directory -Path (Split-Path $SetupCompletePath) -Force | Out-Null
    @"
@echo off
echo ==== AUTOPILOT SETUP ==== >> C:\Autopilot-Diag.txt
echo Timestamp: %DATE% %TIME% >> C:\Autopilot-Diag.txt
echo Checking JSON files... >> C:\Autopilot-Diag.txt

if exist "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot\AutopilotConfigurationFile.json" (
    echo Found AutopilotConfigurationFile.json >> C:\Autopilot-Diag.txt
) else (
    echo MISSING: AutopilotConfigurationFile.json >> C:\Autopilot-Diag.txt
)

if exist "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot\OOBE.json" (
    echo Found OOBE.json >> C:\Autopilot-Diag.txt
) else (
    echo MISSING: OOBE.json >> C:\Autopilot-Diag.txt
)

powershell.exe -ExecutionPolicy Bypass -NoProfile -Command ^
 "\$GroupTagID = '$GroupTag'; ^
  Write-Host -ForegroundColor Green 'AutoPilot Enabled'; ^
  Write-Host 'Installing Get-WindowsAutoPilotInfo script'; ^
  Install-Script -Name Get-WindowsAutoPilotInfo -Force -Scope AllUsers; ^
  \$ScriptPath = Join-Path \$env:ProgramFiles 'WindowsPowerShell\Scripts\Get-WindowsAutoPilotInfo.ps1'; ^
  if (Test-Path \$ScriptPath) { ^
      Write-Host 'Running Autopilot script...'; ^
      & \$ScriptPath -GroupTag \$GroupTagID -Online -Assign; ^
      Write-Host 'Autopilot script completed successfully'; ^
  } else { ^
      Write-Host 'ERROR: Get-WindowsAutoPilotInfo.ps1 not found'; ^
  }"

echo Autopilot hash upload completed >> C:\Autopilot-Diag.txt
exit
"@ | Out-File -FilePath $SetupCompletePath -Encoding ASCII

    Write-Host "SetupComplete.cmd created successfully."
    Write-Host "Deployment script completed. Rebooting in 5 seconds..."
    Start-Sleep -Seconds 5
    Restart-Computer -Force
}
catch {
    Write-Error "Deployment failed: $_"
}
finally {
    try { Stop-Transcript } catch {}
}
