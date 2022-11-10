#=======================================================================
#   OS: Params and Start-OSDCloud
#=======================================================================
$Params = @{
    OSBuild = "22H2"
    OSEdition = "Enterprise"
    OSLanguage = "en-gb"
    OSLicense = "Volume"
    SkipAutopilot = $true
    SkipODT = $true
}
#Start-OSDCloud @Params


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
                    "Microsoft.MicrosoftStickyNotes",
                    "Microsoft.MSPaint",
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
                          "IsPresent":  true
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
$AutopilotOOBEJson = @'
{
    "Assign":  {
                   "IsPresent":  true
               },
    "GroupTag":  "ProductivityDesktop",
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
'@
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