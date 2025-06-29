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

    # Always wipe Disk 0
    $DiskNumber = 0

    # Clear Disk 0 including OEM partitions
    Write-Host "Clearing disk $DiskNumber including OEM partitions..."
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false

    # Initialize as GPT
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -Confirm:$false

    # Ensure disk is online and writable
    Set-Disk -Number $DiskNumber -IsOffline $false
    Set-Disk -Number $DiskNumber -IsReadOnly $false

    # Create EFI System Partition (no drive letter yet)
    $ESP = New-Partition -DiskNumber $DiskNumber -Size 100MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
    Format-Volume -Partition $ESP -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false

    # Create MSR partition
    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null

    # Create Windows partition (C:)
    $OSPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize
    Format-Volume -Partition $OSPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $OSPartition.PartitionNumber -NewDriveLetter C

    Write-Host "Disk prepared successfully. Windows partition is now C:."

    # Wait for network connectivity
    Write-Host "Waiting for network connectivity..."
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

    # Apply WIM
    $WimPath = "M:\install.wim"
    if (-not (Test-Path $WimPath)) {
        throw "WIM file not found at $WimPath"
    }
    Write-Host "Applying Windows image from $WimPath to C:..."
    $dism = Start-Process -FilePath dism.exe -ArgumentList "/Apply-Image", "/ImageFile:$WimPath", "/Index:1", "/ApplyDir:C:\" -Wait -PassThru
    if ($dism.ExitCode -ne 0) {
        throw "DISM failed with exit code $($dism.ExitCode)"
    }

    # Find EFI partition and mount it as S:
    $ESPPartition = Get-Partition -DiskNumber $DiskNumber | Where-Object {
        $_.GptType -eq "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
    }

    if ($ESPPartition) {
        Write-Host "Assigning drive letter S: to EFI partition..."
        Set-Partition -DiskNumber $DiskNumber -PartitionNumber $ESPPartition.PartitionNumber -NewDriveLetter "S"
    } else {
        throw "EFI partition not found!"
    }

    # Setup boot files with /addfirst
    Write-Host "Running bcdboot to create UEFI boot entry with highest priority..."
    Start-Process -FilePath "bcdboot.exe" -ArgumentList "C:\Windows", "/s", "S:", "/f", "UEFI", "/l", "en-GB", "/addfirst" -Wait -NoNewWindow

    # Optional: Remove S: mapping
    Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $ESPPartition.PartitionNumber -AccessPath "S:\" -ErrorAction SilentlyContinue

    Write-Host "Boot files created successfully."

    # Autopilot configuration
    $AutopilotFolder = "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
    New-Item -ItemType Directory -Force -Path $AutopilotFolder | Out-Null

    $AutopilotConfig = @{
        CloudAssignedTenantId    = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain = "obgpharma.onmicrosoft.com"
        GroupTag                 = $GroupTag
    }
    $AutopilotConfig | ConvertTo-Json -Depth 3 | Out-File "$AutopilotFolder\AutopilotConfigurationFile.json" -Encoding utf8

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
    $OOBEJson | ConvertTo-Json -Depth 5 | Out-File "$AutopilotFolder\OOBE.json" -Encoding utf8

    # Unattend.xml
    $UnattendPath = "C:\Windows\Panther\Unattend\Unattend.xml"
    $UnattendXml = "<?xml version=`"1.0`" encoding=`"utf-8`"?>
<unattend xmlns=`"urn:schemas-microsoft-com:unattend`">
  <settings pass=`"oobeSystem`">
    <component name=`"Microsoft-Windows-International-Core`" processorArchitecture=`"amd64`" publicKeyToken=`"31bf3856ad364e35`" language=`"neutral`" versionScope=`"nonSxS`" xmlns:wcm=`"http://schemas.microsoft.com/WMIConfig/2002/State`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`">
      <InputLocale>en-GB</InputLocale>
      <SystemLocale>en-GB</SystemLocale>
      <UILanguage>en-GB</UILanguage>
      <UserLocale>en-GB</UserLocale>
    </component>
  </settings>
</unattend>"
    Set-Content -Path $UnattendPath -Value $UnattendXml -Encoding UTF8

    # Download Get-WindowsAutoPilotInfo script
    $AutoPilotScriptPath = "C:\Autopilot\Get-WindowsAutoPilotInfo.ps1"
    $AutoPilotScriptURL = "http://10.1.192.20/Get-WindowsAutoPilotInfo.ps1"
    New-Item -ItemType Directory -Path "C:\Autopilot" -Force | Out-Null
    try {
        Invoke-WebRequest -Uri $AutoPilotScriptURL -OutFile $AutoPilotScriptPath -UseBasicParsing -ErrorAction Stop
        Write-Host "Downloaded Get-WindowsAutoPilotInfo.ps1 successfully."
    } catch {
        Write-Warning "Failed to download Autopilot script: $_"
    }

    # SetupComplete.cmd
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
