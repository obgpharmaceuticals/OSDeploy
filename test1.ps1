Write-Host "Start Process New"

try {
    Start-Transcript -Path "x:\DeployScript.log" -Append
} catch {
    Write-Warning "Failed to start transcript: $_"
}

#=======================================================================
#   Disk Partitioning: Clean disk, create 10GB D: and remaining C:
#=======================================================================

Write-Host "Selecting disk to clean and partition..."

# Select first online disk (ignores partition style, type, etc)
$TargetDisk = Get-Disk | Where-Object { $_.OperationalStatus -eq 'Online' } | Sort-Object Size -Descending | Select-Object -First 1

if (-not $TargetDisk) {
    throw "No online disk found to partition."
}

Write-Host "Selected disk number $($TargetDisk.Number) - Size: $([math]::Round($TargetDisk.Size /1GB, 2)) GB"

# Clean disk (WARNING: deletes ALL data)
Write-Host "Cleaning disk $($TargetDisk.Number)..."
Clear-Disk -Number $TargetDisk.Number -RemoveData -Confirm:$false

# Initialize disk as GPT
Write-Host "Initializing disk $($TargetDisk.Number) as GPT..."
Initialize-Disk -Number $TargetDisk.Number -PartitionStyle GPT -PassThru | Out-Null

# Create 10GB D: partition
Write-Host "Creating 10GB D: partition..."
$PartitionD = New-Partition -DiskNumber $TargetDisk.Number -Size 10GB -AssignDriveLetter

# Format D: partition as NTFS
Format-Volume -Partition $PartitionD -FileSystem NTFS -NewFileSystemLabel "Data" -Confirm:$false

# Assign drive letter D (in case not auto assigned)
Set-Partition -DiskNumber $TargetDisk.Number -PartitionNumber $PartitionD.PartitionNumber -NewDriveLetter D

# Create remaining partition as C:
Write-Host "Creating remaining space as C: partition..."
$PartitionC = New-Partition -DiskNumber $TargetDisk.Number -UseMaximumSize -AssignDriveLetter

# Format C: partition as NTFS
Format-Volume -Partition $PartitionC -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false

# Assign drive letter C (in case not auto assigned)
Set-Partition -DiskNumber $TargetDisk.Number -PartitionNumber $PartitionC.PartitionNumber -NewDriveLetter C

Write-Host "Disk partitioning complete."

#=======================================================================
#   Selection: Choose the type of system which is being deployed
#=======================================================================

$GroupTag = "NotSet"
do {
    Write-Host "================ Computer Type ================" -ForegroundColor Yellow
    Write-Host "1: Productivity Desktop"
    Write-Host "2: Productivity Laptop"
    Write-Host "3: Line of Business"
    try {
        $selection = Read-Host "Please make a selection"
    } catch {
        Write-Warning "Input failed. Retrying..."
        Start-Sleep -Seconds 5
        continue
    }

    switch ($selection) {
        '1' { $GroupTag = "ProductivityDesktop" }
        '2' { $GroupTag = "ProductivityLaptop" }
        '3' { $GroupTag = "LineOfBusinessDesktop" }
        default {
            Write-Warning "Invalid selection. Please choose 1, 2, or 3."
            $GroupTag = "NotSet"
        }
    }
} until ($GroupTag -ne "NotSet")

#=======================================================================
#   Download install.wim to D:\
#=======================================================================

$WimUrl = "http://10.1.192.20/install.wim"
$LocalWimPath = "D:\install.wim"

Write-Host "Downloading install.wim from $WimUrl to $LocalWimPath ..."
try {
    Invoke-WebRequest -Uri $WimUrl -OutFile $LocalWimPath -UseBasicParsing -Verbose
    Write-Host "Download complete."
} catch {
    throw "Failed to download install.wim: $_"
}

#=======================================================================
#   OS: Set up OSDCloud parameters to use local WIM image
#=======================================================================

$Params = @{
    OSName       = "Windows 11 23H2 x64"
    OSEdition    = "Enterprise"
    OSLanguage   = "en-gb"
    OSLicense    = "Volume"
    ZTI          = $true
    Wim          = $LocalWimPath
    WimIndex     = 1
    TargetDrive  = "C:"
}

Write-Host "Starting OSDCloud deployment using local WIM image..."
Start-OSDCloud @Params

#=======================================================================
#   PostOS: Create OOBE.json
#=======================================================================

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

$OSDeployPath = "C:\ProgramData\OSDeploy"
New-Item -Path $OSDeployPath -ItemType Directory -Force | Out-Null
$OOBEJson | Out-File -FilePath "$OSDeployPath\OOBE.json" -Encoding ascii -Force

#=======================================================================
#   Autopilot Configuration
#=======================================================================

$AutopilotConfig = @{
    CloudAssignedOobeConfig       = 131
    CloudAssignedTenantId         = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
    CloudAssignedDomainJoinMethod = 0
    ZtdCorrelationId              = (New-Guid).Guid
    CloudAssignedTenantDomain     = "obgpharma.onmicrosoft.com"
    CloudAssignedUserUpn          = ""
    CloudAssignedGroupTag         = $GroupTag
} | ConvertTo-Json -Depth 10

$AutopilotPath = "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
New-Item -Path $AutopilotPath -ItemType Directory -Force | Out-Null
$AutopilotConfig | Out-File -FilePath "$AutopilotPath\AutopilotConfigurationFile.json" -Encoding ascii -Force

#=======================================================================
#   Write Post-Deployment Autopilot Registration Script
#=======================================================================

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

    # Force Intune enrollment sync
    schtasks /run /tn "Microsoft\Windows\EnterpriseMgmt\Schedule created by enrollment client for automatically setting up the device"
    Write-Output 'Enrollment task triggered.'

    # Trigger OOBE
    rundll32.exe shell32.dll,Control_RunDLL "sysdm.cpl,,4"
} catch {
    Write-Output \"Error during autopilot script: $_\"
} finally {
    Stop-Transcript
}"
'@

$FirstLogonPath = "C:\Windows\Setup\Scripts"
New-Item -Path $FirstLogonPath -ItemType Directory -Force | Out-Null
$FirstLogonScript | Out-File "$FirstLogonPath\SetupComplete.cmd" -Encoding ascii -Force

#=======================================================================
# Final Step: Stop transcript and reboot
#=======================================================================

Write-Host "`nDeployment script complete. Rebooting into full OS..." -ForegroundColor Green
try {
    Stop-Transcript
} catch {
    Write-Warning "Failed to stop transcript: $_"
}

Start-Sleep -Seconds 5
# Restart-Computer -Force
