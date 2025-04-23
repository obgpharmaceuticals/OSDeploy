#=======================================================================
#   Selection: Selection menu items
#=======================================================================
function Show-GroupTagMenu {
    param (
        [string]$Title = 'Computer Type'
    )
    Write-Host "================ $Title ================="
    
    Write-Host "1: Productivity Desktop"
    Write-Host "2: Productivity Laptop"
    Write-Host "3: Line of Business"
}

#=======================================================================
#   Selection: Choose the type of system which is being deployed
#=======================================================================
$GroupTag = "NotSet"
do {
    Show-GroupTagMenu
    $selection = Read-Host "Please make a selection"
    switch ($selection) {
        '1' {
            $GroupTag = "ProductivityDesktop"
        }
        '2' {
            $GroupTag = "ProductivityLaptop"
        }
        '3' {
            $GroupTag = "LineOfBusinessDesktop"
        }
    }
} until ($GroupTag -ne "NotSet")

#=======================================================================
#   Selection: Auto picking the latest Windows 11 build
#=======================================================================
$ImageLocation = "Cloud"
$OS = "Windows 11 22H2 x64"  # Latest build as of the script's context.

#=======================================================================
#   OS: Set up the OSD parameters for launch
#=======================================================================
$Params = @{
    OSName = $OS
    OSEdition = "Enterprise"
    OSLanguage = "en-US"  # Set language to US English
    OSLicense = "Volume"
    ZTI = $true
    UseWindowsCatalogue = $true  # Assuming this flag enables driver installations from the Windows Update Catalog
}

#=======================================================================
#  OS: Start-OSDCloud
#=======================================================================
Write-Host "Starting OSD Cloud"
# Start-OSDCloud @Params
Start-OSDCloudGUI
#=======================================================================
#   PostOS: OOBE Staging
#=======================================================================
$OOBEJson = @"
{
    "Updates": [],
    "RemoveAppx": [
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

# Create necessary directories and output JSON
if (!(Test-Path "C:\ProgramData\OSDeploy")) {
    New-Item "C:\ProgramData\OSDeploy" -ItemType Directory -Force
}

$OOBEJson | Out-File -FilePath "C:\ProgramData\OSDeploy\OOBE.json" -Encoding ascii -Force

Write-Host -ForegroundColor Green "Creating C:\Windows\System32\OOBE.CMD"
$OOBETasksCMD = @"
PowerShell -NoL -Com Set-ExecutionPolicy RemoteSigned -Force
Set Path = %PATH%;C:\Program Files\WindowsPowerShell\Scripts
Start /Wait PowerShell -NoL -C Install-Module OSD -Force -Verbose
Start /Wait PowerShell -NoL -C Invoke-WebPSScript https://raw.githubusercontent.com/obgpharmaceuticals/OSDeploy/main/OOBE.ps1
"@

$OOBETasksCMD | Out-File -FilePath 'C:\Windows\System32\OOBE.CMD' -Encoding ascii -Force

#=======================================================================
# UnattendXml
#=======================================================================
$UnattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31
