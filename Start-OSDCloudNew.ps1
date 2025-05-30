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
#   Mount ISO from network share (authenticated)
#=======================================================================

$SmbUser = "osduser"
$SmbPassword = "YourSecurePassword"  # Replace with actual password
$SecurePass = ConvertTo-SecureString $SmbPassword -AsPlainText -Force
$Cred = New-Object System.Management.Automation.PSCredential ($SmbUser, $SecurePass)

Write-Host "Mounting network share \\10.1.192.20\ISOS"
New-PSDrive -Name "Z" -PSProvider FileSystem -Root "\\10.1.192.20\ISOS" -Credential (New-Object System.Management.Automation.PSCredential ("osduser", (ConvertTo-SecureString "osduser" -AsPlainText -Force))) -Persist


$ISOLocalPath = "Z:\Windows11_23H2.iso"
$MountPath = "X:\MountISO"
New-Item -ItemType Directory -Path $MountPath -Force | Out-Null

Write-Host "Mounting ISO"
Mount-DiskImage -ImagePath $ISOLocalPath -StorageType ISO -PassThru | Get-Volume | ForEach-Object {
    $ISODriveLetter = $_.DriveLetter
}

$WimSource = "$ISODriveLetter`:\sources\install.wim"
$WimDest = "X:\OS\install.wim"
Copy-Item -Path $WimSource -Destination $WimDest -Force

# Optional: List images in WIM to verify index
# Get-WindowsImage -ImagePath $WimDest

#=======================================================================
#   OSDCloud: Deployment using local WIM file
#=======================================================================

$Params = @{
    OSLicense  = "Volume"
    OSEdition  = "Enterprise"
    ZTI        = $true
    WIMFile    = $WimDest
    Index      = 6  # Adjust if needed based on Get-WindowsImage
}

Write-Host "Starting OSDCloud with local WIM"
Start-OSDCloud @Params

#=======================================================================
#   PostOS: OOBE Staging
#=======================================================================

$OOBEJson = @"
{
    "Updates":     [],
    "RemoveAppx":  [
        "MicrosoftTeams", "Microsoft.BingWeather", "Microsoft.BingNews",
        "Microsoft.GamingApp", "Microsoft.GetHelp", "Microsoft.Getstarted",
        "Microsoft.Messaging", "Microsoft.MicrosoftOfficeHub",
        "Microsoft.MicrosoftSolitaireCollection", "Microsoft.People",
        "Microsoft.PowerAutomateDesktop", "Microsoft.StorePurchaseApp",
        "Microsoft.Todos", "microsoft.windowscommunicationsapps",
        "Microsoft.WindowsFeedbackHub", "Microsoft.WindowsMaps",
        "Microsoft.WindowsSoundRecorder", "Microsoft.Xbox.TCUI",
        "Microsoft.XboxGameOverlay", "Microsoft.XboxGamingOverlay",
        "Microsoft.XboxIdentityProvider", "Microsoft.XboxSpeechToTextOverlay",
        "Microsoft.YourPhone", "Microsoft.ZuneMusic", "Microsoft.ZuneVideo"
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

#=======================================================================
#   OOBE Script Setup
#=======================================================================

Write-Host -ForegroundColor Green "Create C:\Windows\System32\oobew11.cmd"
$OOBETasksCMD = @"
PowerShell -NoL -Com Set-ExecutionPolicy RemoteSigned -Force
Set Path = %PATH%;C:\Program Files\WindowsPowerShell\Scripts
Start /Wait PowerShell -NoL -C Install-Module OSD -Force -Verbose
Start /Wait PowerShell -NoL -C Invoke-WebPSScript https://raw.githubusercontent.com/obgpharmaceuticals/OSDeploy/main/oobew11.ps1
"@
$OOBETasksCMD | Out-File -FilePath 'C:\Windows\System32\oobew11.cmd' -Encoding ascii -Force

#=======================================================================
#   Unattended Setup Configuration
#=======================================================================

$UnattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral"
                   versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <Reseal>
                <Mode>Audit</Mode>
            </Reseal>
        </component>
    </settings>
    <settings pass="auditUser">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral"
                   versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Description>OOBE</Description>
                    <Path>oobew11.cmd</Path>
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
if (-not (Test-Path $Panther)) {
    New-Item -Path $Panther -ItemType Directory -Force | Out-Null
}
$UnattendPath = "$Panther\Unattend.xml"
$UnattendXml | Out-File -FilePath $UnattendPath -Encoding utf8 -Force

Use-WindowsUnattend -Path 'C:\' -UnattendPath $UnattendPath -Verbose

#=======================================================================
#   Reboot to apply
#=======================================================================

Write-Host "`nRebooting Now"
Write-Host "Restart-Computer -Force -Verbose"
