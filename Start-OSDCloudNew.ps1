Start-Transcript -Path "X:\DeployLog.txt" -Force

# Prompt for system type and assign GroupTag
$systemType = Read-Host "Enter system type: 1 = ProductivityDesktop, 2 = ProductivityLaptop, 3 = LineOfBusinessDesktop"
switch ($systemType) {
    '1' { $GroupTag = "ProductivityDesktop" }
    '2' { $GroupTag = "ProductivityLaptop" }
    '3' { $GroupTag = "LineOfBusinessDesktop" }
    default { Write-Host "Invalid input. Exiting."; Exit 1 }
}

# Clean and prepare disk 0
Get-Disk 0 | Set-Disk -IsReadOnly $false
Get-Disk 0 | Set-Disk -IsOffline $false
Get-Disk 0 | Clear-Disk -RemoveData -Confirm:$false

$partitions = Initialize-Disk 0 -PartitionStyle GPT -PassThru |
    New-Partition -GptType "{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}" -DriveLetter C -UseMaximumSize |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false

New-Partition -DiskNumber 0 -Size 100MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}" | Format-Volume -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false | Set-Partition -NewDriveLetter S
New-Partition -DiskNumber 0 -Size 16MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null

# Apply Windows image (index must be Enterprise)
$WimPath = "\\10.1.192.20\install.wim"
Write-Host "Applying Windows image from $WimPath..."
dism /Apply-Image /ImageFile:$WimPath /Index:6 /ApplyDir:C:\

# Configure BCD
bcdboot C:\Windows /s S: /f UEFI

# Set up Autopilot provisioning folder
$AutopilotFolder = "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
New-Item -ItemType Directory -Path $AutopilotFolder -Force

# Create AutopilotConfigurationFile.json
$AutopilotConfig = @{
    CloudAssignedTenantId     = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
    CloudAssignedTenantDomain = "obgpharma.onmicrosoft.com"
    GroupTag                  = $GroupTag
    CloudAssignedEdition      = "Enterprise"
}
$AutopilotConfig | ConvertTo-Json -Depth 3 | Out-File "$AutopilotFolder\AutopilotConfigurationFile.json" -Encoding utf8

# Create OOBE.json for updates/app removals
$OOBEConfig = @{
    OobeSettings = @{
        HidePrivacySettings = $true
        UserType = "Standard"
        Language = "en-GB"
        Region = "GB"
    }
    Update = @{
        Drivers = "Exclude"
        Apps = "Exclude"
    }
    AppRemoval = @(
        "Microsoft.Todos",
        "Microsoft.BingNews",
        "Microsoft.MicrosoftStickyNotes",
        "Microsoft.ZuneMusic",
        "Microsoft.ZuneVideo",
        "Microsoft.MicrosoftSolitaireCollection"
    )
}
$OOBEConfig | ConvertTo-Json -Depth 4 | Out-File "$AutopilotFolder\OOBE.json" -Encoding utf8

# Download Get-WindowsAutopilotInfo script
Invoke-WebRequest -Uri "https://aka.ms/Get-WindowsAutoPilotInfo" -OutFile "C:\Get-WindowsAutoPilotInfo.ps1"

# Create SetupComplete.cmd to upload hardware hash
$SetupCompletePath = "C:\Windows\Setup\Scripts"
New-Item -ItemType Directory -Path $SetupCompletePath -Force

@"
@echo off
SET LOGFILE=C:\AutopilotUpload.log
SET COUNT=0
:RETRY
powershell.exe -ExecutionPolicy Bypass -File C:\Get-WindowsAutoPilotInfo.ps1 -Online -TenantId "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee" -AppId "faa1bc75-81c7-4750-ac62-1e5ea3ac48c5" -AppSecret "ouu8Q~h2IxPhfb3GP~o2pQOvn2HSmBkOm2D8hcB-" >> %LOGFILE% 2>&1
IF %ERRORLEVEL% NEQ 0 (
    SET /A COUNT+=1
    IF %COUNT% LSS 5 (
        timeout /t 30
        GOTO RETRY
    )
)
"@ | Out-File "$SetupCompletePath\SetupComplete.cmd" -Encoding ascii

# Final step - reboot
Write-Host "Deployment complete. Rebooting into OOBE..."
# Restart-Computer
