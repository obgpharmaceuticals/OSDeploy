# Start transcript logging
Start-Transcript -Path "X:\DeployScript.log" -Append

try {
    Write-Host "Starting Windows 11 deployment..." -ForegroundColor Cyan

    # Prompt for system type
    Write-Host "Select system type:"
    Write-Host "1. Productivity Desktop"
    Write-Host "2. Productivity Laptop"
    Write-Host "3. Line of Business Desktop"
    $choice = Read-Host "Enter your choice (1-3)"

    switch ($choice) {
        '1' { $GroupTag = "ProductivityDesktop" }
        '2' { $GroupTag = "ProductivityLaptop" }
        '3' { $GroupTag = "LineOfBusinessDesktop" }
        default {
            Write-Host "Invalid choice. Exiting..." -ForegroundColor Red
            exit 1
        }
    }

    # Select and wipe Disk 0
    $disk = Get-Disk 0
    $isNVMe = ($disk.FriendlyName -like "*NVMe*")

    Write-Host "Wiping disk and setting up partitions..." -ForegroundColor Yellow
    $disk | Set-Disk -IsReadOnly $false
    $disk | Set-Disk -IsOffline $false
    $disk | Clear-Disk -RemoveData -Confirm:$false
    $disk | Initialize-Disk -PartitionStyle GPT

    New-Partition -DiskNumber 0 -Size 550MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" -AssignDriveLetter | Out-Null  # Recovery
    $efi = New-Partition -DiskNumber 0 -Size 100MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}" -AssignDriveLetter
    New-Partition -DiskNumber 0 -Size 16MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null  # MSR
    $os = New-Partition -DiskNumber 0 -UseMaximumSize -GptType "{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}" -AssignDriveLetter

    Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    Format-Volume -Partition $os -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false

    # Apply WIM
    $osDrive = ($os | Get-Volume).DriveLetter + ":"
    $wimURL = "http://10.1.192.20/install.wim"
    $wimPath = "X:\install.wim"
    Invoke-WebRequest -Uri $wimURL -OutFile $wimPath

    Write-Host "Applying image to $osDrive..." -ForegroundColor Cyan
    dism /Apply-Image /ImageFile:$wimPath /Index:1 /ApplyDir:$osDrive\

    # Make bootable
    bcdboot "$osDrive\Windows" /s "$($efi.DriveLetter):" /f UEFI

    # Generate AutopilotConfigurationFile.json
    $AutopilotConfig = @{
        CloudAssignedTenantId = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain = "obgpharma.onmicrosoft.com"
        CloudAssignedDeviceName = "%SERIAL%"
        CloudAssignedProfile = ""
        CloudAssignedGroupTag = $GroupTag
    }
    $AutopilotConfig | ConvertTo-Json -Depth 10 | Set-Content -Path "$osDrive\AutopilotConfigurationFile.json" -Encoding UTF8

    # Generate OOBE.json
    $oobeJson = @{
        version = "1.0.0"
        CloudAssignedOobeConfig = @{
            SkipKeyboardSelection = $true
            HideEULA = $true
            UserType = "Standard"
            Language = "en-GB"
            Region = "GB"
        }
        ZtdCorrelationId = $GroupTag
        SkipOOBE = $false
        ConfigureKeyboard = $true
        ConfigureRegion = $true
        RemoveWindowsStoreApps = $true
        UpdateDrivers = $true
        UpdateWindows = $true
    }
    $oobeJson | ConvertTo-Json -Depth 10 | Set-Content -Path "$osDrive\OOBE.json" -Encoding UTF8

    # Generate Unattend.xml with proper en-GB settings
    $unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>en-GB</InputLocale>
      <SystemLocale>en-GB</SystemLocale>
      <UILanguage>en-GB</UILanguage>
      <UserLocale>en-GB</UserLocale>
    </component>
  </settings>
</unattend>
"@
    $unattend | Out-File -FilePath "$osDrive\Windows\Panther\Unattend.xml" -Encoding utf8

    # Write SetupComplete.cmd
    $setupScript = @"
@echo off
set RETRIES=3
set COUNT=0

:LOOP
if %COUNT% GEQ %RETRIES% goto END

powershell -ExecutionPolicy Bypass -Command "try {
    iex ((New-Object Net.WebClient).DownloadString('https://aka.ms/Get-WindowsAutopilotInfo'))
    .\Get-WindowsAutoPilotInfo.ps1 -Online -TenantId 'c95ebf8f-ebb1-45ad-8ef4-463fa94051ee' -AppId 'faa1bc75-81c7-4750-ac62-1e5ea3ac48c5' -AppSecret 'ouu8Q~h2IxPhfb3GP~o2pQOvn2HSmBkOm2D8hcB-'
} catch {
    Start-Sleep -Seconds 10
    exit 1
}"
if %ERRORLEVEL% EQU 0 goto END

set /A COUNT+=1
goto LOOP

:END
exit /b
"@
    $setupScript | Out-File -FilePath "$osDrive\Windows\Setup\Scripts\SetupComplete.cmd" -Encoding ascii -Force

    Write-Host "Deployment complete. Rebooting..." -ForegroundColor Green
    Restart-Computer
}
catch {
    Write-Host "Deployment failed: $_" -ForegroundColor Red
}
finally {
    Stop-Transcript
}
