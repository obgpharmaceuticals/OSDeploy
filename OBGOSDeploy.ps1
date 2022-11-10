#=======================================================================
#   OS: Params and Start-OSDCloud
#=======================================================================
$Params = @{
    OSBuild = "20H1"
    OSEdition = "Enterprise"
    OSLanguage = "en-gb"
    OSLicense = "Volume"
    SkipAutopilot = $true
    SkipODT = $true
}
Start-OSDCloud @Params

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
