Write-Host "Start Process New 2"

try {
    Start-Transcript -Path "x:\DeployScript.log" -Append
} catch {
    Write-Warning "Failed to start transcript: $_"
}

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
#   Create Temporary Partition for WIM Download
#=======================================================================
Write-Host "Detecting target disk..."
$TargetDisk = Get-Disk | Where-Object {
    $_.IsBoot -eq $false -and $_.IsSystem -eq $false -and $_.PartitionStyle -ne 'RAW'
} | Sort-Object Size -Descending | Select-Object -First 1

if (-not $TargetDisk) {
    throw "No suitable target disk found."
}

Write-Host "Creating 10 GB temporary partition on disk $($TargetDisk.Number)..."
$TempPartition = New-Partition -DiskNumber $TargetDisk.Number -Size 10GB -AssignDriveLetter
Format-Volume -Partition $TempPartition -FileSystem NTFS -NewFileSystemLabel "TempWIM" -Confirm:$false | Out-Null

$TempDriveLetter = ($TempPartition | Get-Volume).DriveLetter
if ($TempDriveLetter -ne 'D') {
    Write-Host "Reassigning drive letter to D..."
    Set-Partition -DiskNumber $TargetDisk.Number -PartitionNumber $TempPartition.PartitionNumber -NewDriveLetter D
    $TempDriveLetter = 'D'
}

$WimPath = "$TempDriveLetter`:\install.wim"

Write-Host "Downloading install.wim to $WimPath..."
Invoke-WebRequest -Uri "http://10.1.192.20/install.wim" -OutFile $WimPath

#=======================================================================
#   Apply install.wim to disk (after wiping it)
#=======================================================================
Write-Host "Wiping target disk and applying image..."

# Remove all existing partitions
Get-Partition -DiskNumber $TargetDisk.Number | Remove-Partition -Confirm:$false

# Initialize disk and create standard layout
Initialize-Disk -Number $TargetDisk.Number -PartitionStyle GPT
New-Partition -DiskNumber $TargetDisk.Number -Size 100MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Format-Volume -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
$OSPartition = New-Partition -DiskNumber $TargetDisk.Number -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $OSPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false

$OSDrive = ($OSPartition | Get-Volume).DriveLetter

# Apply Windows Image
Write-Host "Applying install.wim to $OSDrive`:"
dism /Apply-Image /ImageFile:$WimPath /Index:1 /ApplyDir:"$OSDrive`:\"

# Make bootable
bcdboot "$OSDrive`:\Windows" /s "$OSDrive`:" /f UEFI

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
$OSDeployPath = "$OSDrive`:\ProgramData\OSDeploy"
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

$AutopilotPath = "$OSDrive`:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
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

    schtasks /run /tn "Microsoft\Windows\EnterpriseMgmt\Schedule created by enrollment client for automatically setting up the device"
    Write-Output 'Enrollment task triggered.'

    rundll32.exe shell32.dll,Control_RunDLL "sysdm.cpl,,4"
} catch {
    Write-Output \"Error during autopilot script: $_\"
} finally {
    Stop-Transcript
}"
'@

$FirstLogonPath = "$OSDrive`:\Windows\Setup\Scripts"
New-Item -Path $FirstLogonPath -ItemType Directory -Force | Out-Null
$FirstLogonScript | Out-File "$FirstLogonPath\SetupComplete.cmd" -Encoding ascii -Force

#=======================================================================
# Final Step: Cleanup and Reboot
#=======================================================================
Write-Host "`nDeployment complete. Rebooting..." -ForegroundColor Green
try {
    Stop-Transcript
} catch {
    Write-Warning "Failed to stop transcript: $_"
}

Start-Sleep -Seconds 5
# Restart-Computer -Force
