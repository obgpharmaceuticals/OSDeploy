Write-Host "`nStarting Deployment Script..." -ForegroundColor Cyan
Start-Sleep -Seconds 2

# Create log file
$LogPath = "X:\DeployScript.log"
Start-Transcript -Path $LogPath -Append

#=======================================================================
#   Selection: Choose the type of system which is being deployed
#=======================================================================
$GroupTag = "NotSet"

do {
    Write-Host "`n================ Computer Type ================" -ForegroundColor Yellow
    Write-Host "1: Productivity Desktop"
    Write-Host "2: Productivity Laptop"
    Write-Host "3: Line of Business"
    try {
        $selection = Read-Host "Please make a selection"
    } catch {
        Write-Warning "Input failed. Trying again in 5 seconds..."
        Start-Sleep -Seconds 5
        continue
    }

    switch ($selection) {
        '1' { $GroupTag = "ProductivityDesktop" }
        '2' { $GroupTag = "ProductivityLaptop" }
        '3' { $GroupTag = "LineOfBusinessDesktop" }
        default {
            Write-Warning "Invalid selection. Please choose 1, 2, or 3."
            $GroupTag = "NotSet"
        }
    }
} until ($GroupTag -ne "NotSet")

Write-Host "`nGroup selected: $GroupTag" -ForegroundColor Green
Start-Sleep -Seconds 1

#=======================================================================
#   OS: Set up OSDCloud parameters
#=======================================================================
$Params = @{
    OSName     = "Windows 11 23H2 x64"
    OSEdition  = "Enterprise"
    OSLan
