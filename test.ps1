Write-Host "Start Process New"

try {
    Start-Transcript -Path "X:\DeployScript.log" -Append
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
#   OS: Set up OSDCloud parameters
#=======================================================================

$Params = @{
    OSName     = "Windows 11 23H2 x64"
    OSEdition  = "Enterprise"
    OSLanguage = "en-gb"
    OSLicense  = "Volume"
    ZTI        = $true
}

Write-Host "Starting OSDCloud deployment..."
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
#   Capture Autopilot Hardware Hash and Autopilot Logs
#=======================================================================

$HardwareHashPath = "C:\HardwareHash.csv"
if (Get-Command "mdmdiagnosticstool.exe" -ErrorAction SilentlyContinue) {
    Start-Process -FilePath "mdmdiagnosticstool.exe" -ArgumentList "-CollectHardwareHash -Output $HardwareHashPath" -Wait
    Write-Host "Hardware hash captured to $HardwareHashPath"

    $DiagOutput = "C:\autopilot.cab"
    Start-Process -FilePath "mdmdiagnosticstool.exe" -ArgumentList "-area Autopilot -cab $DiagOutput" -Wait
    Write-Host "Autopilot diagnostics written to $DiagOutput"
} else {
    Write-Warning "mdmdiagnosticstool.exe not found. Skipping hardware hash and diagnostics."
}

#=======================================================================
# Final Step: Stop transcript only (no unattended applied)
#=======================================================================
Write-Host "\nFinished deployment phase. No Unattend applied to allow clean OOBE boot." -ForegroundColor Green
try {
    Stop-Transcript
} catch {
    Write-Warning "Failed to stop transcript: $_"
}

Start-Sleep -Seconds 5
Restart-Computer -Force
