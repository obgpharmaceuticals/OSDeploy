Write-Host "Start Process New"

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
#   OS: Format disk and apply install.wim from HTTP
#=======================================================================

$WimUrl = "http://10.1.192.20/install.wim"
$ImageIndex = 6  # Adjust this index as needed

try {
    Write-Host "Preparing disk..."
    $Disk = Get-Disk | Where-Object IsBoot -eq $true
    $Disk | Initialize-Disk -PartitionStyle GPT -PassThru | Out-Null

    $Partition = New-Partition -DiskNumber $Disk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $Partition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null

    $TargetDrive = ($Partition | Get-Volume).DriveLetter + ":"
    $WimLocal = "$TargetDrive\install.wim"

    Write-Host "Downloading install.wim to $WimLocal..."
    Invoke-WebRequest -Uri $WimUrl -OutFile $WimLocal

    Write-Host "Applying image index $ImageIndex from $WimLocal..."
    dism /Apply-Image /ImageFile:$WimLocal /Index:$ImageIndex /ApplyDir:$TargetDrive\

    Write-Host "Setting up bootloader..."
    bcdboot "$TargetDrive\Windows" /s $TargetDrive /f UEFI
} catch {
    Write-Warning "Deployment failed: $_"
    Exit 1
}

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
