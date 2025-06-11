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

# Disk 0 - Wipe and Partition (UEFI GPT)
$disk = Get-Disk -Number 0
$disk | Clear-Disk -RemoveData -Confirm:$false
Initialize-Disk -Number 0 -PartitionStyle GPT

# Create partitions
$efi = New-Partition -DiskNumber 0 -Size 100MB -GptType "{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}" -AssignDriveLetter
Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
Set-Partition -DiskNumber 0 -PartitionNumber $efi.PartitionNumber -NewDriveLetter S

New-Partition -DiskNumber 0 -Size 16MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null  # MSR

$os = New-Partition -DiskNumber 0 -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $os -FileSystem NTFS -NewFileSystemLabel "OS" -Confirm:$false
Set-Partition -DiskNumber 0 -PartitionNumber $os.PartitionNumber -NewDriveLetter C

# Apply Windows from Network WIM
$WIMPath = "http://10.1.192.20/install.wim"
Dism /Apply-Image /ImageFile:$WIMPath /Index:1 /ApplyDir:C:\

# Setup Bootloader
bcdboot C:\Windows /s S: /f UEFI

# Autopilot Configuration
$AutoPilotPath = "C:\Windows\Provisioning\Autopilot"
New-Item -Path $AutoPilotPath -ItemType Directory -Force | Out-Null

@"
{
    "CloudAssignedTenantId": "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee",
    "CloudAssignedTenantDomain": "obgpharma.onmicrosoft.com",
    "CloudAssignedGroupTag": "$GroupTag"
}
"@ | Set-Content -Path "$AutoPilotPath\AutopilotConfigurationFile.json" -Encoding utf8

# OOBE.json Customization
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
"@ | Set-Content -Path "C:\Windows\OOBE.json" -Encoding utf8

# SetupComplete Script for Autopilot Upload
$SetupScriptPath = "C:\Windows\Setup\Scripts"
New-Item -Path $SetupScriptPath -ItemType Directory -Force | Out-Null

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
"@ | Set-Content -Path "$SetupScriptPath\SetupComplete.cmd" -Encoding ascii

# Reboot into full OS
Write-Host "Installation complete. Rebooting..." -ForegroundColor Green
Restart-Computer -Force
