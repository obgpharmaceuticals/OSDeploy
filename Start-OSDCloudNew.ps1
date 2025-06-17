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
    $ESP = New-Partition -DiskNumber $DiskNumber -Size 100MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}" -AssignDriveLetter
    $MSR = New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}"
    $DataPartition = New-Partition -DiskNumber $DiskNumber -Size 10GB -AssignDriveLetter
    $OSPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter

    # Format partitions
    Format-Volume -Partition $ESP -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    Format-Volume -Partition $DataPartition -FileSystem NTFS -NewFileSystemLabel "Data" -Confirm:$false
    Format-Volume -Partition $OSPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false

    # Assign drive letters
    $ESPDrive = ($ESP | Get-Partition).DriveLetter + ":"
    $DataDrive = ($DataPartition | Get-Partition).DriveLetter + ":"
    $OSDrive = ($OSPartition | Get-Partition).DriveLetter + ":"

    Write-Host "Partitions created: EFI ($ESPDrive), Data ($DataDrive), Windows ($OSDrive)"

    # Apply Windows image
    Write-Host "Applying Windows image to $OSDrive..."
    dism.exe /Apply-Image /ImageFile:E:\install.wim /Index:1 /ApplyDir:$OSDrive

    # Setup boot files
    bcdboot "$OSDrive\Windows" /s $ESPDrive /f UEFI

    # Autopilot folder
    $AutopilotFolder = "$OSDrive\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
    New-Item -ItemType Directory -Force -Path $AutopilotFolder | Out-Null

    # AutopilotConfigurationFile.json
    $AutopilotConfig = @{
        CloudAssignedTenantId    = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain = "obgpharma.onmicrosoft.com"
        GroupTag                 = $GroupTag
    }
    $AutopilotConfig | ConvertTo-Json -Depth 3 | Out-File "$AutopilotFolder\AutopilotConfigurationFile.json" -Encoding utf8

    # OOBE.json
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
    $OOBEJson | ConvertTo-Json -Depth 5 | Out-File "$AutopilotFolder\OOBE.json" -Encoding utf8

    # Unattend.xml
    $UnattendPath = "$OSDrive\Windows\Panther\Unattend\Unattend.xml"
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

    # Download Autopilot script
    $AutoPilotScriptPath = "$OSDrive\Autopilot\Get-WindowsAutoPilotInfo.ps1"
    $AutoPilotScriptURL = "http://10.1.192.20/Get-WindowsAutoPilotInfo.ps1"
    New-Item -ItemType Directory -Path "$OSDrive\Autopilot" -Force | Out-Null
    Invoke-WebRequest -Uri $AutoPilotScriptURL -OutFile $AutoPilotScriptPath -UseBasicParsing

    # Write SetupComplete.cmd
    $SetupCompletePath = "$OSDrive\Windows\Setup\Scripts\SetupComplete.cmd"
    New-Item -ItemType Directory -Path (Split-Path $SetupCompletePath) -Force | Out-Null
    @"
@echo off
set LOGFILE=C:\Autopilot-Diag.txt
set SCRIPT=C:\Autopilot\Get-WindowsAutoPilotInfo.ps1

echo ==== AUTOPILOT SETUP ==== >> %LOGFILE%
echo Timestamp: %DATE% %TIME% >> %LOGFILE%

if exist "%SCRIPT%" (
    powershell.exe -ExecutionPolicy Bypass -NoProfile -Command ^
    "$retries = 3; $success = $false; for (`$i = 1; `$i -le $retries; `$i++) { try { & '%SCRIPT%' -TenantId 'c95ebf8f-ebb1-45ad-8ef4-463fa94051ee' -AppId 'faa1bc75-81c7-4750-ac62-1e5ea3ac48c5' -AppSecret 'ouu8Q~h2IxPhfb3GP~o2pQOvn2HSmBkOm2D8hcB-' -GroupTag '$GroupTag' -Online -Assign; `$success = $true; break } catch { Add-Content -Path '%LOGFILE%' -Value ('Attempt {0} failed: {1}' -f `$i, `$_); Start-Sleep -Seconds 10 } }; if (-not `$success) { Add-Content -Path '%LOGFILE%' -Value 'All upload attempts failed.' }"
) else (
    echo ERROR: Script not found at %SCRIPT% >> %LOGFILE%
)
exit
"@ | Out-File -FilePath $SetupCompletePath -Encoding ASCII

    Write-Host "SetupComplete.cmd created successfully."
    Write-Host "Deployment complete. Rebooting in 5 seconds..."
    Start-Sleep -Seconds 5
    Restart-Computer -Force
}
catch {
    Write-Error "Deployment failed: $_"
}
finally {
    try { Stop-Transcript } catch {}
}
