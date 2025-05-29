# Ensure OSD module is available and import it
if (-not (Get-Module -ListAvailable -Name OSD)) {
    Install-Module -Name OSD -Force -Scope CurrentUser
}
Import-Module OSD

Clear-Host
Write-Host "Starting OSDCloud Deployment..." -ForegroundColor Cyan

# Prompt for device type and set Group Tag accordingly
$DeviceType = Read-Host "Enter device type: (1) Productivity Desktop, (2) Productivity Laptop, (3) Line of Business"

switch ($DeviceType) {
    '1' { $GroupTag = 'ProductivityDesktop' }
    '2' { $GroupTag = 'ProductivityLaptop' }
    '3' { $GroupTag = 'LineOfBusinessDesktop' }
    default {
        Write-Host "Invalid selection. Defaulting to 'ProductivityDesktop'" -ForegroundColor Yellow
        $GroupTag = 'ProductivityDesktop'
    }
}

Write-Host "Autopilot Group Tag set to: $GroupTag" -ForegroundColor Green

# Configure OSDCloud deployment settings for Azure AD Join
$OSDCloudConfig = @{
    OSName         = "Windows 11 23H2 x64"
    OSEdition      = "Enterprise"
    OSLanguage     = "en-us"
    OSLicense      = "Volume"
    ZtdJoin        = $true
    ZtdJoinType    = "AAD"
    ZtdGroupTag    = $GroupTag
}

# Start OSDCloud deployment
Write-Host "Launching OSDCloud..." -ForegroundColor Cyan
Start-OSDCloud @OSDCloudConfig

Read-Host "`nDeployment complete. Press ENTER to exit"
