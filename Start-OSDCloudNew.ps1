Start-Transcript -Path X:\DeployLog.txt -Append

# Prompt for System Type
Write-Host "Select System Type:" -ForegroundColor Yellow
Write-Host "1. Productivity Desktop"
Write-Host "2. Productivity Laptop"
Write-Host "3. Line of Business Desktop"
$selection = Read-Host "Enter selection (1, 2, or 3)"

switch ($selection) {
    '1' { $GroupTag = "ProductivityDesktop" }
    '2' { $GroupTag = "ProductivityLaptop" }
    '3' { $GroupTag = "LineOfBusinessDesktop" }
    default {
        Write-Host "Invalid selection. Defaulting to ProductivityDesktop." -ForegroundColor Red
        $GroupTag = "ProductivityDesktop"
    }
}

# Wipe and reinitialize disk
Write-Host "Wiping and reinitializing system disk..." -ForegroundColor Cyan

$BootDiskNumber = (Get-Partition | Where-Object { $_.DriveLetter -eq "X" }).DiskNumber
$TargetDisk = Get-Disk | Where-Object { $_.Number -ne $BootDiskNumber -and $_.BusType -ne 'USB' } | Select-Object -First 1

if (-not $TargetDisk) {
    Write-Host "No suitable disk found for installation." -ForegroundColor Red
    Exit 1
}

$TargetDisk | Set-Disk -IsReadOnly $false -ErrorAction SilentlyContinue
$TargetDisk | Set-Disk -IsOffline $false -ErrorAction SilentlyContinue
$TargetDisk | Clear-Disk -RemoveData -Confirm:$false
$TargetDisk | Initialize-Disk -PartitionStyle GPT

# Create EFI (100 MB), MSR (16 MB), and OS partitions
New-Partition -DiskNumber $TargetDisk.Number -Size 100MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}" | Format-Volume -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
New-Partition -DiskNumber $TargetDisk.Number -Size 16MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null
$OSPartition = New-Partition -DiskNumber $TargetDisk.Number -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $OSPartition -FileSystem NTFS -NewFileSystemLabel "OS" -Confirm:$false

$OSDrive = $OSPartition.DriveLetter + ":"

# Download and apply Windows image
$WIMUrl = "http://10.1.192.20/install.wim"
$WIMLocal = "$env:TEMP\install.wim"
Write-Host "Downloading Windows image..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $WIMUrl -OutFile $WIMLocal

Write-Host "Applying Windows image to $OSDrive..." -ForegroundColor Cyan
Dism /Apply-Image /ImageFile:$WIMLocal /Index:1 /ApplyDir:$OSDrive\

# Set up boot files
Write-Host "Configuring bootloader..." -ForegroundColor Cyan
bcdboot "$OSDrive\Windows" /s "$OSDrive" /f UEFI

# Autopilot Configuration
$AutopilotPath = "$OSDrive\Windows\Provisioning\Autopilot"
New-Item -ItemType Directory -Path $AutopilotPath -Force

@"
{
    "CloudAssignedTenantId": "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee",
    "CloudAssignedTenantDomain": "obgpharma.onmicrosoft.com",
    "CloudAssignedGroupTag": "$GroupTag"
}
"@ | Set-Content -Path "$AutopilotPath\AutopilotConfigurationFile.json" -Encoding UTF8

# OOBE.json Configuration (Remove apps, update, drivers)
@"
{
    "Version": 1,
    "OOBE": {
        "HideEULA": true,
        "HidePrivacySettings": true,
        "HideLocalAccount": true,
        "HideOEMRegistration": true,
        "HideRegion": true,
        "HideLanguage": true,
        "HideKeyboard": true,
        "ProtectYourPC": "1"
    },
    "RemoveAppx": [
        "MicrosoftTeams",
        "Microsoft.GamingApp",
        "Microsoft.GetHelp",
        "Microsoft.MicrosoftOfficeHub",
        "Microsoft.MicrosoftSolitaireCollection",
        "Microsoft.People",
        "Microsoft.PowerAutomateDesktop",
        "Microsoft.WindowsFeedbackHub",
        "Microsoft.XboxGamingOverlay",
        "Microsoft.XboxIdentityProvider",
        "Microsoft.YourPhone"
    ],
    "UpdateDrivers": true,
    "UpdateWindows": true
}
"@ | Set-Content -Path "$OSDrive\Windows\OOBE.json" -Encoding UTF8

# SetupComplete to run Autopilot hash upload on first boot
$SetupCompletePath = "$OSDrive\Windows\Setup\Scripts"
New-Item -ItemType Directory -Path $SetupCompletePath -Force

@"
powershell -ExecutionPolicy Bypass -NoLogo -NoProfile -WindowStyle Hidden -Command "& {
    Start-Transcript -Path C:\OOBE-PostSetup.log -Append
    try {
        Install-Script -Name Get-WindowsAutopilotInfo -Force -Scope LocalMachine -ErrorAction Stop
        Get-WindowsAutopilotInfo -Online
    } catch {
        Write-Error "Autopilot upload failed: $_"
    }
    Stop-Transcript
}"
"@ | Set-Content -Path "$SetupCompletePath\SetupComplete.cmd" -Encoding ASCII

# Done - reboot into OOBE
Write-Host "Deployment complete. Rebooting into OOBE..." -ForegroundColor Green
Stop-Transcript
# Restart-Computer -Force
