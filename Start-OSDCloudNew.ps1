Write-Host "Start Process New"

#=======================================================================
#   Selection: Choose the type of system which is being deployed
#=======================================================================

$GroupTag = "NotSet"
do {
    Write-Host "================ Computer Type ================"
    Write-Host "1: Productivity Desktop"
    Write-Host "2: Productivity Laptop"
    Write-Host "3: Line of Business"
    $selection = Read-Host "Please make a selection"
    switch ($selection) {
        '1' { $GroupTag = "ProductivityDesktop" }
        '2' { $GroupTag = "ProductivityLaptop" }
        '3' { $GroupTag = "LineOfBusinessDesktop" }
    }
} until ($GroupTag -ne "NotSet")

#=======================================================================
#   OS: Set up the OSD parameters for launch
#=======================================================================

$Params = @{
    OSName     = "Windows 11 23H2 x64"
    OSEdition  = "Enterprise"
    OSLanguage = "en-gb"
    OSLicense  = "Volume"
    ZTI        = $true
}

#=======================================================================
#  OS: Start-OSDCloud
#=======================================================================
Write-Host "Starting OSD Cloud"
Start-OSDCloud @Params

#=======================================================================
#   PostOS: OOBE Staging
#=======================================================================

# Create OOBE.json
$OOBEJson = @"
{
    "Updates":     [],
    "RemoveAppx":  [
        "MicrosoftTeams",
        "Microsoft.BingWeather",
        "Microsoft.BingNews",
        "Microsoft.GamingApp",
        "Microsoft.GetHelp",
        "Microsoft.Getstarted",
        "Microsoft.Messaging",
        "Microsoft.MicrosoftOfficeHub",
        "Microsoft.MicrosoftSolitaireCollection",
        "Microsoft.People",
        "Microsoft.PowerAutomateDesktop",
        "Microsoft.StorePurchaseApp",
        "Microsoft.Todos",
        "microsoft.windowscommunicationsapps",
        "Microsoft.WindowsFeedbackHub",
        "Microsoft.WindowsMaps",
        "Microsoft.WindowsSoundRecorder",
        "Microsoft.Xbox.TCUI",
        "Microsoft.XboxGameOverlay",
        "Microsoft.XboxGamingOverlay",
        "Microsoft.XboxIdentityProvider",
        "Microsoft.XboxSpeechToTextOverlay",
        "Microsoft.YourPhone",
        "Microsoft.ZuneMusic",
        "Microsoft.ZuneVideo"
    ],
    "UpdateDrivers": true,
    "UpdateWindows": true,
    "AutopilotOOBE": true,
    "GroupTagID": "$GroupTag"
}
"@

$OSDeployPath = "C:\ProgramData\OSDeploy"
If (!(Test-Path $OSDeployPath)) {
    New-Item $OSDeployPath -ItemType Directory -Force
}
$OOBEJson | Out-File -FilePath "$OSDeployPath\OOBE.json" -Encoding ascii -Force

#=======================================================================
# Autopilot Configuration
#=======================================================================

$AutopilotConfig = @{
    CloudAssignedOobeConfig        = 131
    CloudAssignedTenantId          = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"  # <--- Replace this
    CloudAssignedDomainJoinMethod  = 0
    ZtdCorrelationId               = (New-Guid).Guid
    CloudAssignedTenantDomain      = "obgpharma.onmicrosoft.com"  # <--- Replace this
    CloudAssignedUserUpn           = ""
    CloudAssignedGroupTag          = $GroupTag
} | ConvertTo-Json -Depth 3

$AutopilotPath = "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
If (!(Test-Path $AutopilotPath)) {
    New-Item $AutopilotPath -ItemType Directory -Force
}
$AutopilotConfig | Out-File -FilePath "$AutopilotPath\AutopilotConfigurationFile.json" -Encoding ascii -Force

#=======================================================================
# UnattendXml: go directly to OOBE
#=======================================================================

$UnattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
            </OOBE>
            <TimeZone>UTC</TimeZone>
            <RegisteredOrganization>MyOrg</RegisteredOrganization>
            <RegisteredOwner>AutoPilot</RegisteredOwner>
            <DoNotCleanTaskBar>true</DoNotCleanTaskBar>
        </component>
    </settings>
</unattend>
'@

$Panther = 'C:\Windows\Panther'
if (-NOT (Test-Path $Panther)) {
    New-Item -Path $Panther -ItemType Directory -Force | Out-Null
}
$UnattendPath = "$Panther\Unattend.xml"
Write-Host "Writing unattend to $UnattendPath"
$UnattendXml | Out-File -FilePath $UnattendPath -Encoding utf8 -Force
Use-WindowsUnattend -Path 'C:\' -UnattendPath $UnattendPath -Verbose

#=======================================================================
# Final Step: Reboot
#=======================================================================
Write-Host "`nRebooting Now"
Write-Host "Restart-Computer -Force"
