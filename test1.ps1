Write-Host "Start Process New"

try {
    Start-Transcript -Path "C:\DeployScript.log" -Append
} catch {}

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
#   Download WIM before touching disks
#=======================================================================

$WimUrl = "http://10.1.192.20/install.wim"
$ImageIndex = 6

# Detect target disk (largest non-boot)
$TargetDisk = Get-Disk | Where-Object {
    $_.IsBoot -eq $false -and $_.IsSystem -eq $false -and $_.IsOffline -eq $false -and $_.IsReadOnly -eq $false
} | Sort-Object Size -Descending | Select-Object -First 1

if (-not $TargetDisk) {
    throw "No suitable disk found."
}

# Find safe download location
$DownloadVolume = Get-Volume | Where-Object {
    $_.DriveLetter -ne $null -and
    $_.FileSystem -ne $null -and
    ($_ | Get-Partition).DiskNumber -ne $TargetDisk.Number
} | Sort-Object SizeRemaining -Descending | Select-Object -First 1

if (-not $DownloadVolume) {
    throw "No safe location to download WIM."
}

$WimLocal = "$($DownloadVolume.DriveLetter):\install.wim"

Write-Host "Downloading install.wim to $WimLocal..."
try {
    Start-BitsTransfer -Source $WimUrl -Destination $WimLocal
} catch {
    throw "Download failed: $_"
}

#=======================================================================
#   Wipe Disk and Apply WIM
#=======================================================================

Write-Host "Wiping disk $($TargetDisk.Number)..."
$TargetDisk | Clear-Disk -RemoveData -Confirm:$false
$TargetDisk | Initialize-Disk -PartitionStyle GPT -PassThru | Out-Null

$Partition = New-Partition -DiskNumber $TargetDisk.Number -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $Partition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null

$TargetDrive = ($Partition | Get-Volume).DriveLetter + ":"

Write-Host "Applying image..."
dism /Apply-Image /ImageFile:$WimLocal /Index:$ImageIndex /ApplyDir:$TargetDrive\

Write-Host "Installing bootloader..."
bcdboot "$TargetDrive\Windows" /s $TargetDrive /f UEFI

# Optional: Remove WIM
Remove-Item -Path $WimLocal -Force -ErrorAction SilentlyContinue

#=======================================================================
#   Create OOBE.json
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
#   Create AutopilotConfigurationFile.json
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
#   SetupComplete.cmd for Autopilot Registration
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
        mdmdiagnosticstool.exe -area Autopilot -cab 'C:\AutopilotDiag.cab'
    }

    schtasks /run /tn 'Microsoft\Windows\EnterpriseMgmt\Schedule created by enrollment client for automatically setting up the device'
    rundll32.exe shell32.dll,Control_RunDLL 'sysdm.cpl,,4'
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
#   Finalize
#=======================================================================

Write-Host "`nDeployment complete. Rebooting..." -ForegroundColor Green
Start-Sleep -Seconds 5
try { Stop-Transcript } catch {}
# Restart-Computer -Force
