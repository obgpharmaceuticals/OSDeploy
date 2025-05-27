# Ensure OSD Module is imported
if (-not (Get-Module -ListAvailable -Name OSD)) {
    Install-Module OSD -Force -Scope CurrentUser
}
Import-Module OSD

Clear-Host
Write-Host "Starting OSDCloud Deployment..." -ForegroundColor Cyan

# Prompt for device type
$DeviceType = Read-Host "Enter device type: (1) Productivity Desktop, (2) Productivity Laptop, (3) Line of Business"

switch ($DeviceType) {
    '1' { $GroupTag = 'ProductivityDesktop' }
    '2' { $GroupTag = 'ProductivityLaptop' }
    '3' { $GroupTag = 'LineOfBusinessDesktop' }
    default {
        Write-Host "Invalid selection. Defaulting to 'ProductivityDesktop'"
        $GroupTag = 'ProductivityDesktop'
    }
}

Write-Host "Group Tag set to: $GroupTag" -ForegroundColor Green

# Configure OSDCloud deployment settings
$OSDCloudConfig = @{
    OSName         = "Windows 11 23H2 x64"
    OSEdition      = "Enterprise"
    OSLanguage     = "en-us"
    OSLicense      = "Volume"
    ZtdJoin          = "AAD"          
    ZtdGroupTag      = $GroupTag         
    ZtdSkipPrivacy   = $true
    ZtdSkipEULA      = $true
    ZtdSkipKeyboard  = $true
    ZtdOOBESkip      = $false
    OOBEDeploy       = $true
    SkipAutopilot    = $false
    FirmwareType     = "UEFI"
}

# Confirm action
Write-Host "`nThis will wipe Disk 0 and deploy Windows 11 with Autopilot enrollment!" -ForegroundColor Yellow
# Read-Host "Press [ENTER] to continue..."

# Wipe and partition Disk 0
Write-Host "Wiping Disk 0..." -ForegroundColor Red
Clear-Disk -Number 0 -RemoveData -Confirm:$false
Initialize-Disk -Number 0 -PartitionStyle GPT
New-Partition -DiskNumber 0 -UseMaximumSize -AssignDriveLetter | Format-Volume -FileSystem NTFS -NewFileSystemLabel "OSDisk" -Confirm:$false

# Start the cloud deployment
# Read-Host "Ready to install, press a key"
Start-OSDCloud @OSDCloudConfig
Read-Host "Finished, press a key" 
