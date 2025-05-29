Write-Host -ForegroundColor Cyan "Starting Deploy-Windows11 script..."
Start-Sleep -Seconds 3

#==================== GroupTag Selection ====================
function Show-GroupTagMenu {
    Write-Host "`n================ Select Computer Type ================"
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

#==================== Setup OSDCloud Parameters ====================
$Params = @{
    OSName     = "Windows 11 x64"
    OSEdition  = "Enterprise"
    OSLanguage = "en-gb"
    OSLicense  = "Volume"
    ZTI        = $true
}

Write-Host "`nStarting OSDCloud with Windows 11..." -ForegroundColor Cyan
Start-OSDCloud @Params

#==================== Write OOBEW11.json ====================
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

$ProgramDataPath = "C:\ProgramData\OSDeploy"
if (!(Test-Path $ProgramDataPath)) {
    New-Item -ItemType Directory -Path $ProgramDataPath -Force | Out-Null
}
$OOBEJson | Out-File "$ProgramDataPath\OOBEW11.json" -Encoding ascii -Force

#==================== Create OOBEW11.ps1 ====================
$OOBEScript = @'
Write-Host -ForegroundColor DarkGray "========================================================================="
Write-Host -ForegroundColor Green "Start OOBE"

$ProgramDataOSDeploy = "$env:ProgramData\OSDeploy"
$JsonPath = "$ProgramDataOSDeploy\OOBEW11.json"

# Transcript Logging
$Transcript = "$((Get-Date).ToString('yyyy-MM-dd-HHmmss'))-OOBEW11.log"
Start-Transcript -Path "$env:SystemRoot\Temp\$Transcript" -ErrorAction Ignore
$host.ui.RawUI.WindowTitle = "Running Start-OOBEDeploy $env:SystemRoot\Temp\$Transcript"

# Load JSON Config
if (Test-Path $JsonPath) {
    Write-Host -ForegroundColor Cyan "Importing Configuration: $JsonPath"
    $ImportOOBE = Get-Content -Raw -Path $JsonPath | ConvertFrom-Json
    $ImportOOBE.PSObject.Properties | ForEach-Object {
        if ($_.Value -match 'IsPresent=True') { $_.Value = $true }
        if ($_.Value -match 'IsPresent=False') { $_.Value = $false }
        if ($null -eq $_.Value) { return }
        Set-Variable -Name $_.Name -Value $_.Value -Force
    }
}

# Skip BIOS/Firmware Updates
$env:DISABLE_FIRMWARE_UPDATE = "1"

# Install PSWindowsUpdate if needed
if ($UpdateDrivers -or $UpdateWindows) {
    Install-Module PSWindowsUpdate -Force -Verbose
}

# Driver Updates
if ($UpdateDrivers) {
    Install-WindowsUpdate -Install -AcceptAll -UpdateType Driver -MicrosoftUpdate `
        -IgnoreReboot -ForceDownload -ForceInstall -ErrorAction SilentlyContinue
}

# Windows Updates
if ($UpdateWindows -and $Updates) {
    foreach ($item in $Updates) {
        Install-WindowsUpdate -KBArticleID $item -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
    }
}

# Remove AppX
if ($RemoveAppx) {
    foreach ($app in $RemoveAppx) {
        Write-Host "Removing $app"
        Remove-AppxOnline $app
    }
}

# Autopilot Registration
if ($AutopilotOOBE) {
    Install-Script Get-WindowsAutoPilotInfo -Force -Verbose
    Try {
        Get-WindowsAutoPilotInfo.ps1 -GroupTag $GroupTagID -Online -Assign
    } Catch {
        Write-Host "Autopilot failed"
    }
}

Start-Sleep -Seconds 120
'@

$OOBEScript | Out-File 'C:\ProgramData\OSDeploy\OOBEW11.ps1' -Encoding ascii -Force

#==================== Create OOBEW11.CMD ====================
$OOBECmd = @"
PowerShell -NoL -Com Set-ExecutionPolicy RemoteSigned -Force
Start /Wait PowerShell -NoL -C Install-Module OSD -Force -Verbose
Start /Wait PowerShell -NoL -C C:\ProgramData\OSDeploy\OOBEW11.ps1
"@
$OOBECmd | Out-File 'C:\Windows\System32\OOBEW11.CMD' -Encoding ascii -Force

#==================== Setup Unattend.xml ====================
$UnattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <Reseal>
                <Mode>Audit</Mode>
            </Reseal>
        </component>
    </settings>
    <settings pass="auditUser">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Description>OOBEW11</Description>
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

$UnattendPath = "C:\Windows\Panther\Unattend.xml"
if (!(Test-Path 'C:\Windows\Panther')) {
    New-Item -Path 'C:\Windows\Panther' -ItemType Directory -Force | Out-Null
}
$UnattendXml | Out-File -FilePath $UnattendPath -Encoding utf8 -Force
Use-WindowsUnattend -Path 'C:\' -UnattendPath $UnattendPath -Verbose

Write-Host "`nDeployment staging complete. Rebooting..." -ForegroundColor Green
# Restart-Computer -Force

Write-Host -ForegroundColor Yellow "Script complete. Press any key to continue..."
$x = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
