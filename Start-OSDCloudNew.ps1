Write-Host "Starting Deployment Script..." -ForegroundColor Cyan

$LogFile = "X:\DeployScript.log"
"[$(Get-Date -Format 'u')] Starting Deployment Script..." | Out-File $LogFile -Append
function Log {
    param([string]$Message)
    "[$(Get-Date -Format 'u')] $Message" | Out-File $LogFile -Append
}

#=================== Disk Setup (UEFI GPT Bootable) ===================#
$Disk = Get-Disk | Where-Object {
    ($_.OperationalStatus -eq 'Online') -and 
    (($_.PartitionStyle -eq 'RAW') -or ($_.Size -gt 30GB))
} | Sort-Object Size -Descending | Select-Object -First 1

if (-not $Disk) { throw "No suitable target disk found." }

$DiskNumber = $Disk.Number
Write-Host "Cleaning and partitioning Disk $DiskNumber..."

Clear-Disk -Number $DiskNumber -RemoveData -Confirm:$false
Initialize-Disk -Number $DiskNumber -PartitionStyle GPT

# 1. EFI System Partition - 100MB
$ESP = New-Partition -DiskNumber $DiskNumber -Size 100MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}" -AssignDriveLetter
Format-Volume -Partition $ESP -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false

# 2. Microsoft Reserved Partition - 16MB
New-Partition -DiskNumber $DiskNumber -Size 16MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null

# 3. Windows Partition (C:)
$PartitionC = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $PartitionC -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
Set-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionC.PartitionNumber -NewDriveLetter "C"

# 4. Data Partition (D:) - 10GB
$PartitionD = New-Partition -DiskNumber $DiskNumber -Size 10GB -AssignDriveLetter
Format-Volume -Partition $PartitionD -FileSystem NTFS -NewFileSystemLabel "Data" -Confirm:$false
Set-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionD.PartitionNumber -NewDriveLetter "D"

#=================== WIM Download ===================#
$WimUrl = "http://10.1.192.20/install.wim"
$LocalWim = "D:\install.wim"
Write-Host "Downloading WIM from $WimUrl..."
Invoke-WebRequest -Uri $WimUrl -OutFile $LocalWim

#=================== Apply WIM Image ===================#
Write-Host "Applying Windows image to C:..."
dism.exe /Apply-Image /ImageFile:$LocalWim /Index:1 /ApplyDir:C:\

#=================== Boot Configuration ===================#
$ESPDrive = ($ESP | Get-Volume).DriveLetter + ":"
Write-Host "Configuring boot files..."
bcdboot C:\Windows /s $ESPDrive /f UEFI

#=================== Prompt for Device Type ===================#
$GroupTag = "NotSet"
do {
    Write-Host "Select System Type:" -ForegroundColor Yellow
    Write-Host "1: Productivity Desktop"
    Write-Host "2: Productivity Laptop"
    Write-Host "3: Line of Business"
    $choice = Read-Host "Enter choice"
    switch ($choice) {
        '1' { $GroupTag = "ProductivityDesktop" }
        '2' { $GroupTag = "ProductivityLaptop" }
        '3' { $GroupTag = "LineOfBusinessDesktop" }
        default { Write-Host "Invalid choice. Try again." }
    }
} until ($GroupTag -ne "NotSet")

#=================== Write OOBE.json ===================#
$OOBEJson = @"
{
    "Updates": [],
    "RemoveAppx": [
        "MicrosoftTeams", "Microsoft.GamingApp", "Microsoft.GetHelp",
        "Microsoft.MicrosoftOfficeHub", "Microsoft.MicrosoftSolitaireCollection",
        "Microsoft.People", "Microsoft.PowerAutomateDesktop",
        "Microsoft.WindowsFeedbackHub", "Microsoft.XboxGamingOverlay",
        "Microsoft.XboxIdentityProvider", "Microsoft.YourPhone"
    ],
    "UpdateDrivers": true,
    "UpdateWindows": true,
    "AutopilotOOBE": true,
    "GroupTagID": "$GroupTag"
}
"@

$OOBEPath = "C:\ProgramData\OSDeploy"
New-Item -Path $OOBEPath -ItemType Directory -Force | Out-Null
$OOBEJson | Out-File "$OOBEPath\OOBE.json" -Encoding ascii -Force

#=================== Write Autopilot Configuration ===================#
$AutoPilotJson = @{
    CloudAssignedOobeConfig       = 131
    CloudAssignedTenantId         = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
    CloudAssignedDomainJoinMethod = 0
    ZtdCorrelationId              = (New-Guid).Guid
    CloudAssignedTenantDomain     = "obgpharma.onmicrosoft.com"
    CloudAssignedUserUpn          = ""
    CloudAssignedGroupTag         = $GroupTag
} | ConvertTo-Json -Depth 10

$AutoPilotPath = "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
New-Item -Path $AutoPilotPath -ItemType Directory -Force | Out-Null
$AutoPilotJson | Out-File "$AutoPilotPath\AutopilotConfigurationFile.json" -Encoding ascii -Force

#=================== Write SetupComplete Script ===================#
$FirstLogonScript = @'
@echo off
PowerShell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -Command "
$LogPath = 'C:\Windows\Temp\AutopilotRegister.log'
Start-Transcript -Path $LogPath -Append

try {
    if (Get-Command 'mdmdiagnosticstool.exe' -ErrorAction SilentlyContinue) {
        $HardwareHash = 'C:\HardwareHash.csv'
        mdmdiagnosticstool.exe -CollectHardwareHash -Output $HardwareHash
        Write-Output 'Hardware hash collected to $HardwareHash'

        mdmdiagnosticstool.exe -area Autopilot -cab 'C:\AutopilotDiag.cab'
        Write-Output 'Autopilot diagnostics collected.'
    }

    schtasks /run /tn "Microsoft\Windows\EnterpriseMgmt\Schedule created by enrollment client for automatically setting up the device"
    Write-Output 'Enrollment task triggered.'

    rundll32.exe shell32.dll,Control_RunDLL "sysdm.cpl,,4"
} catch {
    Write-Output \"Error during autopilot script: $_\"
} finally {
    Stop-Transcript
}"
'@

$SetupScripts = "C:\Windows\Setup\Scripts"
New-Item -Path $SetupScripts -ItemType Directory -Force | Out-Null
$FirstLogonScript | Out-File "$SetupScripts\SetupComplete.cmd" -Encoding ascii -Force

#=================== Finalize ===================#
try {
    Stop-Transcript
} catch {
    Write-Warning "Failed to stop transcript: $_"
}

Write-Host "`nDeployment complete. Rebooting into full OS..." -ForegroundColor Green
Start-Sleep -Seconds 5
# Restart-Computer -Force
