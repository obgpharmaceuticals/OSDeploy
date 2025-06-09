Write-Host "Start Process New Test JD"

try {
    Start-Transcript -Path "C:\DeployScript.log" -Append
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
#   OS: Download WIM before wiping the disk
#=======================================================================

$WimUrl = "http://10.1.192.20/install.wim"
$ImageIndex = 6

# Step 1: Locate the target disk to wipe
$TargetDisk = Get-Disk | Where-Object {
    $_.IsBoot -eq $false -and $_.IsSystem -eq $false -and $_.IsOffline -eq $false -and $_.IsReadOnly -eq $false
} | Sort-Object -Property Size -Descending | Select-Object -First 1

if (-not $TargetDisk) {
    throw "No suitable target disk found for Windows deployment."
}

# Step 2: Find a volume NOT on the target disk to store the WIM
$SafeVolumes = Get-Volume | Where-Object {
    $_.DriveLetter -ne $null -and
    $_.FileSystem -ne $null -and
    ($_ | Get-Partition).DiskNumber -ne $TargetDisk.Number
}

$DownloadVolume = $SafeVolumes | Sort-Object -Property SizeRemaining -Descending | Select-Object -First 1

if (-not $DownloadVolume) {
    throw "No volume found to safely store install.wim before wiping disk $($TargetDisk.Number)."
}

$WimLocal = "$($DownloadVolume.DriveLetter):\install.wim"

Write-Host "Downloading install.wim to $WimLocal..."
Invoke-WebRequest -Uri $WimUrl -OutFile $WimLocal

#=======================================================================
#   Format target disk and apply image
#=======================================================================

Write-Host "Wiping disk $($TargetDisk.Number)..."
$TargetDisk | Clear-Disk -RemoveData -Confirm:$false
$TargetDisk | Initialize-Disk -PartitionStyle GPT -PassThru | Out-Null

$Partition = New-Partition -DiskNumber $TargetDisk.Number -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $Partition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null

$TargetDrive = ($Partition | Get-Volume).DriveLetter + ":"

Write-Host "Applying Windows image from $WimLocal to $TargetDrive..."
dism /Apply-Image /ImageFile:$WimLocal /Index:$ImageIndex /ApplyDir:$TargetDrive\

Write-Host "Setting up bootloader..."
bcdboot "$TargetDrive\Windows" /s $TargetDrive /f UEFI

# Optional: Clean up downloaded WIM
Remove-Item -Path $WimLocal -Force

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

$OSDeployPath = "$TargetDrive\ProgramData\OSDeploy"
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

$AutopilotPath = "$TargetDrive\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
New-Item -Path $AutopilotPath -ItemType Directory -Force | Out-Null
$AutopilotConfig | Out-File -FilePath "$AutopilotPath\AutopilotConfigurationFile.json" -Encoding ascii -Force

#=======================================================================
#   First Boot Script: SetupComplete.cmd for Autopilot
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

$FirstLogonPath = "$TargetDrive\Windows\Setup\Scripts"
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
