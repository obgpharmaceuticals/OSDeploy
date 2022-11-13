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
    
    Write-Host "1: Standard - Cloud"
    Write-Host "2: Standard - Local"
    Write-Host "3: Custom - Cloud"
    Write-Host "4: Custom - Local"
}

#=======================================================================
#   OS: Params and Start-OSDCloud
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
             $GroupTag = "LineOfBusiness"
         }
     }
 }
 until ($GroupTag -ne "NotSet")

$selection = "" 
$ImageLocation = "NotSet"
$ImageURLDefault = "http://10.1.100.25/install.wim"
do
{
    Show-ImageMenu
    $selection = Read-Host "Please make a selection"
    switch ($selection)
    {
        '1' {
            $ImageLocation = "Cloud"
        } '2' {
            $ImageLocation = "Local"
            $ImageIndex = 3
        } '3' {
            $ImageLocation = "CloudCustom"
            $ImageURL = Read-Host "Enter image URL"
        } '4' {
            $ImageLocation = "LocalCustom"
            $ImageURL = Read-Host "Enter image URL"
        }
    }
}
until ($ImageLocation -ne "NotSet")

If($ImageURL -eq "" -or $ImageURL -eq $null) {
    $ImageURL = $ImageURLDefault
}


if($ImageLocation -eq "Local"){
    $Params = @{
        SkipAutopilot = $true
        SkipODT = $true
        ZTI = $true
        ImageFileUrl = $ImageURL 
        ImageIndex = $ImageIndex
        }
}
elseif($ImageLocation -eq "LocalCustom"){
    $Params = @{
        SkipAutopilot = $true
        SkipODT = $true
        ZTI = $true
        ImageFileUrl = $ImageURL 
        }
}
elseif($ImageLocation -eq "Cloud"){
        $Params = @{
            OSVersion = "Windows 10"
            OSBuild = "20H2"
            OSEdition = "Enterprise"
            OSLanguage = "en-gb"
            OSLicense = "Volume"
            SkipAutopilot = $true
            SkipODT = $true
            ZTI = $true
        }
}
elseif($ImageLocation -eq "CloudCustom"){
        $Params = @{
            SkipAutopilot = $true
            SkipODT = $true
            ZTI = $true
        }    
}

Start-OSDCloud @Params

#=======================================================================
#   PostOS: OOBE Staging
#=======================================================================

$OOBEDeployJson = @'
{
    "Autopilot":  {
                      "IsPresent":  false
                  },
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
    "UpdateDrivers":  {
                          "IsPresent":  true
                      },
    "UpdateWindows":  {
                          "IsPresent":  false
                      }
}
'@

If (!(Test-Path "C:\ProgramData\OSDeploy")) {
    New-Item "C:\ProgramData\OSDeploy" -ItemType Directory -Force | Out-Null
}
$OOBEDeployJson | Out-File -FilePath "C:\ProgramData\OSDeploy\OSDeploy.OOBEDeploy.json" -Encoding ascii -Force

#=======================================================================
#   PostOS: AutopilotOOBE Staging
#=======================================================================
$AutopilotOOBEJson = @"
{
    "Assign":  {
                   "IsPresent":  true
               },
    "GroupTag":  `"$GroupTag`",
    "GroupTagOptions":  [
                            "ProductivityDesktop",
                            "ProductivityLaptop",
                            "LineOfBusiness"
                        ],
    "Hidden":  [
                   "AddToGroup",
                   "AssignedComputerName",
                   "AssignedUser",
                   "PostAction"
               ],
    "PostAction":  "Quit",
    "Run":  "NetworkingWireless",
    "Docs":  "https://autopilotoobe.osdeploy.com/",
    "Title":  "OBG Autopilot Registration"
}
"@
$AutopilotOOBEJson | Out-File -FilePath "C:\ProgramData\OSDeploy\OSDeploy.AutopilotOOBE.json"


Write-Host -ForegroundColor Green "Create C:\Windows\System32\OOBE.CMD"
$OOBETasksCMD = @'
PowerShell -NoL -Com Set-ExecutionPolicy RemoteSigned -Force
Set Path = %PATH%;C:\Program Files\WindowsPowerShell\Scripts
Start /Wait PowerShell -NoL -C Install-Module AutopilotOOBE -Force -Verbose
Start /Wait PowerShell -NoL -C Install-Module OSD -Force -Verbose
Start /Wait PowerShell -NoL -C Start-AutopilotOOBE
Start /Wait PowerShell -NoL -C Start-OOBEDeploy
Start /Wait PowerShell -NoL -C Restart-Computer -Force
'@
$OOBETasksCMD | Out-File -FilePath 'C:\Windows\System32\OOBE.CMD' -Encoding ascii -Force

#=======================================================================
# UnattendXml
#=======================================================================
$UnattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Description>OSDCloud Specialize</Description>
                    <Path>oobe.cmd</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
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

Restart-Computer
