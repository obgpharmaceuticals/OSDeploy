#=======================================================================
#   Selection: Selection menu items
#=======================================================================
function Show-GroupTagMenu 
{
    param (
        [string]$Title = 'Computer Type'
    )
    Write-Host "================ $Title ================"
    
    Write-Host "1: Productivity Desktop"
    Write-Host "2: Productivity Laptop"
    Write-Host "3: Line of Business"
}

function Show-ImageMenu
{
    param (
        [string]$Title = 'Image to Use'
    )
    Write-Host "================ $Title ================"
    
    Write-Host "1: Local Windows 10 22H2"
    Write-Host "2: Cloud Windows 10 22H2"
    Write-Host "3: Local Windows 10 20H2"
    Write-Host "4: Cloud Windows 10 21H2"
    Write-Host "5: Cloud Windows 11 22H2"
}

#=======================================================================
#   Selection: Choose the type of system which is being deployed
#=======================================================================

$GroupTag = "NotSet"
do
 {
     Show-GroupTagMenu
     $selection = Read-Host "Please make a selection"
     switch ($selection)
     {
         '1' {
             $GroupTag = "ProductivityDesktop"
         } '2' {
             $GroupTag = "ProductivityLaptop"
         } '3' {
             $GroupTag = "LineOfBusinessDesktop"
         }
     }
 }
 until ($GroupTag -ne "NotSet")

#=======================================================================
#   Selection: Image from the local repo or from MS cloud repo
#=======================================================================


    $selection = ""
    $ImageLocation = "NotSet"
    do
    {
        Show-ImageMenu
        $selection = Read-Host "Please make a selection"
        switch ($selection)
        {
            '1' {
                $ImageLocation = "Local"
                $ImageIndex = 3
                $OS = "Windows 10 22H2 x64"
                $ImageURL = "http://10.1.190.10/install.wim"
            } '2' {
                $ImageLocation = "Cloud"
                $OS = "Windows 10 22H2 x64"
            } '3' {
                $ImageLocation = "Local"
                $ImageIndex = 3
                $ImageURL = "http://10.1.190.10/20h2.wim"
            } '4' {
                $ImageLocation = "Cloud"
                $OS = "Windows 10 21H2 x64"
            } '5' {
                $ImageLocation = "Cloud"
                $OS = "Windows 11 22H2 x64"
            } 
        }
    }
    until ($ImageLocation -ne "NotSet")

#=======================================================================
#   OS: Set up the OSD parameters for launch
#=======================================================================

    if($ImageLocation -eq "Local"){
        $Params = @{
            ZTI = $true
            OSName = $OS
            SkipAutopilot = $true
            ImageFileUrl = $ImageURL
            ImageIndex = $ImageIndex
        }
    }
    elseif($ImageLocation -eq "Cloud"){
        $Params = @{
            OSName = $OS
            OSEdition = "Enterprise"
            OSLanguage = "en-gb"
            OSLicense = "Volume"
            ZTI = $true
            SkipAutopilot = $true
        }
    }

#=======================================================================
#  OS: Start-OSDCloud
#=======================================================================

Write-Host "Starting OSD Cloud"
Start-OSDCloud @Params

#=======================================================================
#   PostOS: OOBE Staging
#=======================================================================

$OOBEJson = @"
{
    "Updates":     [
                   ],
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

If (!(Test-Path "C:\ProgramData\OSDeploy")) {
    New-Item "C:\ProgramData\OSDeploy" -ItemType Directory -Force | Out-Null
}

$OOBEJson | Out-File -FilePath "C:\ProgramData\OSDeploy\OOBE.json" -Encoding ascii -Force

Write-Host -ForegroundColor Green "Create C:\Windows\System32\OOBE.CMD"
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
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <Reseal>
                <Mode>Audit</Mode>
            </Reseal>
        </component>
    </settings>
    <settings pass="auditUser">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                <Order>1</Order>
                <Description>OOBE</Description>
                <Path>oobe.cmd</Path>
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
    #=======================================================================
    # Directories
    #=======================================================================
    if (-NOT (Test-Path 'C:\Windows\Panther')) {
        New-Item -Path 'C:\Windows\Panther'-ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    #=======================================================================
    # Panther Unattend
    #=======================================================================
    $Panther = 'C:\Windows\Panther'
    $UnattendPath = "$Panther\Unattend.xml"

    Write-Verbose -Verbose "Setting $UnattendPath"
    $UnattendXml | Out-File -FilePath $UnattendPath -Encoding utf8 -Force
    #=======================================================================
    # Use-WindowsUnattend
    #=======================================================================
    Write-Verbose -Verbose "Use-WindowsUnattend -Path 'C:\' -UnattendPath $UnattendPath"
    Use-WindowsUnattend -Path 'C:\' -UnattendPath $UnattendPath -Verbose
    #=======================================================================
    
     
    Write-Host "`nRebooting Now"
    Restart-Computer -Force -Verbose

