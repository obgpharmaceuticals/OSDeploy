Write-Host "Start Process"

try {
    # Prompt for Group Tag
    function Show-GroupTagMenu {
        param ([string]$Title = 'Computer Type')
        Write-Host "================ $Title ================"
        Write-Host "1: Productivity Desktop"
        Write-Host "2: Productivity Laptop"
        Write-Host "3: Line of Business"
    }

    $GroupTag = "NotSet"
    do {
        Show-GroupTagMenu
        $selection = Read-Host "Please make a selection"
        switch ($selection) {
            '1' { $GroupTag = "ProductivityDesktop" }
            '2' { $GroupTag = "ProductivityLaptop" }
            '3' { $GroupTag = "LineOfBusinessDesktop" }
        }
    } until ($GroupTag -ne "NotSet")

    # Define latest Windows 11 image
    $Params = @{
        OSName     = "Windows 11 23H2 x64"
        OSEdition  = "Enterprise"
        OSLanguage = "en-gb"
        OSLicense  = "Volume"
        ZTI        = $true
    }

    Write-Host "Starting OSDCloud deployment..."
    Start-OSDCloud @Params

    # Post-deployment OOBE setup
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

    if (!(Test-Path "C:\ProgramData\OSDeploy")) {
        New-Item "C:\ProgramData\OSDeploy" -ItemType Directory -Force
    }
    $OOBEJson | Out-File -FilePath "C:\ProgramData\OSDeploy\OOBE.json" -Encoding ascii -Force

    $OOBETasksCMD = @"
PowerShell -NoL -Com Set-ExecutionPolicy RemoteSigned -Force
Set Path = %PATH%;C:\Program Files\WindowsPowerShell\Scripts
Start /Wait PowerShell -NoL -C Install-Module OSD -Force -Verbose
Start /Wait PowerShell -NoL -C Invoke-WebPSScript https://raw.githubusercontent.com/yourrepo/oobew11.ps1?$(Get-Random)
"@
    $OOBETasksCMD | Out-File -FilePath 'C:\Windows\System32\oobew11.cmd' -Encoding ascii -Force

    # Configure Unattend.xml to run oobew11.cmd
    $UnattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="auditUser">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Description>OOBE</Description>
                    <Path>oobew11.cmd</Path>
                    <WillReboot>Never</WillReboot>
                </RunSynchronousCommand>
            </RunSynchronous>
            <Reseal>
                <Mode>OOBE</Mode>
            </Reseal>
        </component>
    </settings>
</unattend>
'@

    if (-not (Test-Path 'C:\Windows\Panther')) {
        New-Item -Path 'C:\Windows\Panther' -ItemType Directory -Force | Out-Null
    }
    $UnattendPath = 'C:\Windows\Panther\Unattend.xml'
    $UnattendXml | Out-File -FilePath $UnattendPath -Encoding utf8 -Force
    Use-WindowsUnattend -Path 'C:\' -UnattendPath $UnattendPath -Verbose

    Write-Host "Deployment script completed."
    Read-Host "Press Enter to finish"
}
catch {
    $err = $_.Exception.Message
    Write-Host -ForegroundColor Red "\nAn error occurred: $err"
    $logPath = "X:\Temp\OSDCloud_Error.log"
    New-Item -Path (Split-Path $logPath) -ItemType Directory -Force | Out-Null
    "\n[$(Get-Date)] $err" | Out-File -FilePath $logPath -Append -Encoding utf8
    Read-Host "\nPress Enter to view the error and continue"
}
