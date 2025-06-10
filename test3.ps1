Write-Host "Start Process Test2"

try {
    Start-Transcript -Path "x:\DeployScript.log" -Append
} catch {
    Write-Warning "Failed to start transcript: $_"
}


#=================== Device Type Prompt ===================#
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
        default { Write-Host "Invalid choice"; $GroupTag = "NotSet" }
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

#=================== Write Autopilot Config ===================#
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

#=================== SetupComplete.cmd ===================#
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
