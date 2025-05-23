# Ensure OSD Module is imported
if (-not (Get-Module -ListAvailable -Name OSD)) {
    Install-Module OSD -Force -Scope CurrentUser
}
Import-Module OSD

Clear-Host
Write-Host "🌐 Starting OSDCloud Deployment..." -ForegroundColor Cyan

# Prompt for device type
$DeviceType = Read-Host "Enter device type: (1) Productivity Desktop, (2) Productivity Laptop, (3) Line of Business"

switch ($DeviceType) {
    '1' { $GroupTag = 'Productivity-Desktop' }
    '2' { $GroupTag = 'Productivity-Laptop' }
    '3' { $GroupTag = 'Line-of-Business' }
    default {
        Write-Host "❌ Invalid selection. Defaulting to 'Productivity-Desktop'"
        $GroupTag = 'Productivity-Desktop'
    }
}

Write-Host "📌 Group Tag set to: $GroupTag" -ForegroundColor Green

# Configure OSDCloud deployment settings
$OSDCloudConfig = @{
    OSVersion        = "Windows 11"
    OSEdition        = "Enterprise"
    OSBuild          = "23H2"
    OSLanguage       = "en-us"
    OSImageIndex     = 6
    OSLicense        = "Retail"
    ZtdJoin          = "AAD"             # Enable Autopilot
    ZtdGroupTag      = $GroupTag         # ✅ Correct property name
    ZtdSkipPrivacy   = $true
    ZtdSkipEULA      = $true
    ZtdSkipKeyboard  = $true
    ZtdOOBESkip      = $false
    OOBEDeploy       = $true
    SkipAutopilot    = $true
    FirmwareType     = "UEFI"
}

# Confirm action
Write-Host "`n💣 This will wipe Disk 0 and deploy Windows 11 with Autopilot enrollment!" -ForegroundColor Yellow
Read-Host "Press [ENTER] to continue..."

# Wipe and partition Disk 0
Write-Host "🧼 Wiping Disk 0..." -ForegroundColor Red
Clear-Disk -Number 0 -RemoveData -Confirm:$false
Initialize-Disk -Number 0 -PartitionStyle GPT
New-Partition -DiskNumber 0 -UseMaximumSize -AssignDriveLetter | Format-Volume -FileSystem NTFS -NewFileSystemLabel "OSDisk" -Confirm:$false

# Start the cloud deployment
Start-OSDCloud @OSDCloudConfig
