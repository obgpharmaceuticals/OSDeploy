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

# Disk Wipe
Get-Disk | Where-Object IsBoot -eq $false | Initialize-Disk -PartitionStyle GPT -PassThru |
    New-Partition -UseMaximumSize -AssignDriveLetter |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel "OS" -Confirm:$false

$OSDrive = (Get-Volume -FileSystemLabel "OS").DriveLetter + ":"

# Apply WIM from network
$WIMUrl = "http://10.1.192.20/install.wim"
$WIMLocal = "$env:TEMP\install.wim"
Invoke-WebRequest -Uri $WIMUrl -OutFile $WIMLocal

Dism /Apply-Image /ImageFile:$WIMLocal /Index:1 /ApplyDir:$OSDrive\

# Set up boot files
bcdboot "$OSDrive\Windows" /s "$OSDrive" /f UEFI

# Autopilot Configuration
$AutopilotConfigPath = "$OSDrive\Windows\Provisioning\Autopilot"
New-Item -Path $AutopilotConfigPath -ItemType Directory -Force

@"
{
    "CloudAssignedTenantId": "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee",
    "CloudAssignedTenantDomain": "obgpharma.onmicrosoft.com",
    "CloudAssignedProfile": "",
    "CloudAssignedGroupTag": "$GroupTag"
}
"@ | Set-Content -Path "$AutopilotConfigPath\AutopilotConfigurationFile.json" -Encoding utf8

# OOBE.json setup
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
"@ | Set-Content -Path "$OSDrive\Windows\OOBE.json" -Encoding utf8

# SetupComplete to upload hardware hash (Intune registration)
$SetupCompletePath = "$OSDrive\Windows\Setup\Scripts"
New-Item -ItemType Directory -Path $SetupCompletePath -Force

@"
powershell -ExecutionPolicy Bypass -NoLogo -NoProfile -WindowStyle Hidden -Command "& {
    Start-Transcript -Path C:\OOBE-PostSetup.log -Append
    try {
        Install-Script -Name Get-WindowsAutopilotInfo -Force -Scope LocalMachine
        Get-WindowsAutopilotInfo -Online
    } catch {
        Write-Error "Autopilot upload failed: $_"
    }
    Stop-Transcript
}"
"@ | Set-Content -Path "$SetupCompletePath\SetupComplete.cmd" -Encoding ascii

# Reboot to complete
Write-Host "Deployment complete. Rebooting..." -ForegroundColor Green
Restart-Computer -Force
