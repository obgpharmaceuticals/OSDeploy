#=======================================================================
#   Prompt for Group Tag
#=======================================================================
function Show-GroupTagMenu {
    param (
        [string]$Title = 'Select Device Type'
    )
    Write-Host "================ $Title ================" -ForegroundColor Cyan
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

#=======================================================================
#   Get Latest Windows 11 Enterprise x64 Volume License (en-GB)
#=======================================================================
$OS = Get-OSDCloudOperatingSystem |
    Where-Object {
        $_.Name -like "Windows 11*" -and
        $_.Edition -eq "Enterprise" -and
        $_.Architecture -eq "x64" -and
        $_.License -eq "Volume" -and
        $_.Language -eq "en-gb"
    } |
    Sort-Object ReleaseId -Descending |
    Select-Object -First 1

if (-not $OS) {
    Write-Error "Could not locate a suitable Windows 11 image. Check your internet connection and OSDCloud module."
    exit 1
}
write-host "OS Pickup"
#=======================================================================
#   Define OSDCloud Parameters
#=======================================================================
$Params = @{
    OSName     = $OS.Name
    OSEdition  = $OS.Edition
    OSLanguage = $OS.Language
    OSLicense  = $OS.License
    ZTI        = $true
}

#=======================================================================
#   Create OOBEW11 JSON File
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

$ProgramData = "C:\ProgramData\OSDeploy"
New-Item -ItemType Directory -Path $ProgramData -Force | Out-Null
$OOBEJson | Out-File "$ProgramData\OOBEW11.json" -Encoding ascii -Force

#=======================================================================
#   Create OOBEW11.CMD for Audit Mode Execution
#=======================================================================
$OOBETasksCMD = @"
PowerShell -NoL -Com Set-ExecutionPolicy RemoteSigned -Force
Start /Wait PowerShell -NoL -C Install-Module OSD -Force -Verbose
Start /Wait PowerShell -NoL -C Invoke-WebPSScript https://raw.githubusercontent.com/obgpharmaceuticals/OSDeploy/main/OOBEW11.ps1
"@

$OOBETasksCMD | Out-File 'C:\Windows\System32\OOBEW11.CMD' -Encoding ascii -Force

#=======================================================================
#   Unattend.xml to Trigger OOBE Script Post-Install
#=======================================================================
$UnattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <Reseal>
                <Mode>Audit</Mode>
            </Reseal>
        </component>
    </settings>
    <settings pass="auditUser">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Description>Start OOBEW11</Description>
                    <Path>OOBEW11.CMD</Path>
                    <WillReboot>Always</WillReboot>
                </RunSynchronousCommand>
            </RunSynchronous>
            <Reseal>
                <Mode>OOBE</Mode>
            </Reseal>
        </component>
    </settings>
</unattend>
'@

$Panther = 'C:\Windows\Panther'
New-Item -Path $Panther -ItemType Directory -Force | Out-Null
$UnattendPath = "$Panther\Unattend.xml"
$UnattendXml | Out-File -FilePath $UnattendPath -Encoding utf8 -Force

#=======================================================================
#   Apply Unattend File
#=======================================================================
Use-WindowsUnattend -Path 'C:\' -UnattendPath $UnattendPath -Verbose

#=======================================================================
#   Prevent BIOS Updates During Deployment (Lenovo Example)
#=======================================================================
New-Item -Path "HKLM:\SOFTWARE\Policies\Lenovo\BIOS" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Lenovo\BIOS" -Name "DisableBIOSUpdate" -Value 1 -Type DWord

#=======================================================================
#   Start OSDCloud Deployment
#=======================================================================
Write-Host "`nStarting OSDCloud for Windows 11 x64 Enterprise..." -ForegroundColor Green
Start-OSDCloud @Params
