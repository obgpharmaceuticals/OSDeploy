Write-Host "`nStarting Deployment Script..." -ForegroundColor Cyan
Start-Sleep -Seconds 2

# Create log file
$LogPath = "X:\DeployScript.log"
Start-Transcript -Path $LogPath -Append

#=======================================================================
#   Selection: Choose the type of system which is being deployed
#=======================================================================
$GroupTag = "NotSet"

do {
    Write-Host "`n================ Computer Type ================" -ForegroundColor Yellow
    Write-Host "1: Productivity Desktop"
    Write-Host "2: Productivity Laptop"
    Write-Host "3: Line of Business"
    try {
        $selection = Read-Host "Please make a selection"
    } catch {
        Write-Warning "Input failed. Trying again in 5 seconds..."
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

Write-Host "`nGroup selected: $GroupTag" -ForegroundColor Green
Start-Sleep -Seconds 1

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

Write-Host "`nStarting OSDCloud deployment..." -ForegroundColor Cyan
Start-OSDCloud @Params

#=======================================================================
#  Drivers: Inject Windows 11-only driver pack
#=======================================================================
Write-Host "`nChecking for Windows 11 drivers..." -ForegroundColor Cyan

$Model = (Get-MyComputerModel).Model
$DriverPack = Get-OSDCloudDriverPack | Where-Object {
    $_.OperatingSystem -eq 'Windows 11' -and
    $_.SystemSKUs -contains $Model -and
    $_.OSDCloudOSArch -eq 'x64'
} | Select-Object -First 1

if ($null -eq $DriverPack) {
    Write-Warning "No compatible driver pack found for: $Model"
} else {
    Install-OSDCloudDriverPack -DriverPack $DriverPack
    Write-Host "Injected drivers for $Model"
}

#=======================================================================
#   OOBE: Write OOBE.json for cleanup
#=======================================================================
$OOBEJson = @"
{
    "Updates": [],
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
#   Capture Hardware Hash (Optional)
#=======================================================================
$HardwareHashPath = "C:\HardwareHash.csv"
Start-Process -FilePath "mdmdiagnosticstool.exe" -ArgumentList "-CollectHardwareHash -Output $HardwareHashPath" -Wait

$TargetCopyPath = "D:\AutopilotHashes"
if (Test-Path $TargetCopyPath) {
    Copy-Item -Path $HardwareHashPath -Destination $TargetCopyPath -Force
    Write-Host "Hardware hash copied to $TargetCopyPath"
}

#=======================================================================
#   Unattend.xml: Auto-start OOBE
#=======================================================================
$UnattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" ... >
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" ... >
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
            </OOBE>
            <TimeZone>UTC</TimeZone>
            <RegisteredOrganization>MyOrg</RegisteredOrganization>
            <RegisteredOwner>AutoPilot</RegisteredOwner>
        </component>
    </settings>
</unattend>
'@

$Panther = 'C:\Windows\Panther'
New-Item -Path $Panther -ItemType Directory -Force | Out-Null
$UnattendPath = "$Panther\Unattend.xml"
$UnattendXml | Out-File -FilePath $UnattendPath -Encoding utf8 -Force
Use-WindowsUnattend -Path 'C:\' -UnattendPath $UnattendPath -Verbose

#=======================================================================
# Final Step: Reboot into OOBE
#=======================================================================
Write-Host "`nRebooting into OOBE for Autopilot..." -ForegroundColor Green
Stop-Transcript
Restart-Computer -Force
