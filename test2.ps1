Write-Host "=== Start Deployment Process ===" -ForegroundColor Cyan

#=================== Initialize Logging ===================#
function Start-DeploymentLog {
    $LogPath = "X:\DeployScript.log"
    try {
        Start-Transcript -Path $LogPath -Append
    } catch {
        Write-Warning "Failed to start transcript: $_"
    }
}

#=================== Disk Partitioning ===================#
function Initialize-DiskLayout {
    Write-Host "Locating target disk..."
    $Disk = Get-Disk | Where-Object { ($_.OperationalStatus -eq 'Online' -and $_.PartitionStyle -eq 'RAW') -or $_.Size -gt 30GB } | Sort-Object Size -Descending | Select-Object -First 1
    if (-not $Disk) { throw "No suitable target disk found." }

    $DiskNumber = $Disk.Number
    Write-Host "Preparing Disk $DiskNumber..."

    Clear-Disk -Number $DiskNumber -RemoveData -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT

    # Data Partition (10GB)
    $PartitionD = New-Partition -DiskNumber $DiskNumber -Size 10GB -AssignDriveLetter
    Format-Volume -Partition $PartitionD -FileSystem NTFS -NewFileSystemLabel "Data" -Confirm:$false
    Set-Partition -PartitionNumber $PartitionD.PartitionNumber -DiskNumber $DiskNumber -NewDriveLetter "D"

    # Windows Partition (Remaining)
    $PartitionC = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $PartitionC -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-Partition -PartitionNumber $PartitionC.PartitionNumber -DiskNumber $DiskNumber -NewDriveLetter "C"
}

#=================== Download and Apply WIM ===================#
function Deploy-WindowsImage {
    param (
        [string]$WimUrl = "http://10.1.192.20/install.wim"
    )
    $LocalWim = "D:\install.wim"
    Write-Host "Downloading Windows Image from $WimUrl..."
    Invoke-WebRequest -Uri $WimUrl -OutFile $LocalWim

    Write-Host "Applying WIM to C: drive..."
    dism.exe /Apply-Image /ImageFile:$LocalWim /Index:1 /ApplyDir:C:\

    Write-Host "Configuring bootloader..."
    bcdboot C:\Windows /s C: /f UEFI
}

#=================== Prompt for Device Type ===================#
function Get-DeviceGroupTag {
    $Tag = "NotSet"
    do {
        Write-Host "Select System Type:" -ForegroundColor Yellow
        Write-Host "1: Productivity Desktop"
        Write-Host "2: Productivity Laptop"
        Write-Host "3: Line of Business"
        $input = Read-Host "Enter choice"
        switch ($input) {
            '1' { $Tag = "ProductivityDesktop" }
            '2' { $Tag = "ProductivityLaptop" }
            '3' { $Tag = "LineOfBusinessDesktop" }
            default { Write-Host "Invalid selection." }
        }
    } until ($Tag -ne "NotSet")
    return $Tag
}

#=================== Generate OOBE.json ===================#
function Write-OOBEConfig {
    param (
        [string]$GroupTag
    )
    $OOBEJson = @"
{
    "Updates": [],
    "RemoveAppx": [
        "MicrosoftTeams", "Microsoft.GamingApp", "Microsoft.GetHelp",
        "Microsoft.MicrosoftOfficeHub", "Microsoft.MicrosoftSolitaireCollection",
        "Microsoft.People", "Microsoft.PowerAutomateDesktop",
        "Microsoft.WindowsFeedbackHub", "Microsoft.XboxGamingOverlay",
        "Microsoft.XboxIdentityProvider", "Microsoft.YourPhone"
    ],
    "UpdateDrivers": true,
    "UpdateWindows": true,
    "AutopilotOOBE": true,
    "GroupTagID": "$GroupTag"
}
"@
    $Path = "C:\ProgramData\OSDeploy"
    New-Item -Path $Path -ItemType Directory -Force | Out-Null
    $OOBEJson | Out-File "$Path\OOBE.json" -Encoding ascii -Force
}

#=================== Generate Autopilot JSON ===================#
function Write-AutopilotConfig {
    param (
        [string]$GroupTag
    )
    $AutopilotJson = @{
        CloudAssignedOobeConfig       = 131
        CloudAssignedTenantId         = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedDomainJoinMethod = 0
        ZtdCorrelationId              = (New-Guid).Guid
        CloudAssignedTenantDomain     = "obgpharma.onmicrosoft.com"
        CloudAssignedUserUpn          = ""
        CloudAssignedGroupTag         = $GroupTag
    } | ConvertTo-Json -Depth 10

    $Path = "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
    New-Item -Path $Path -ItemType Directory -Force | Out-Null
    $AutopilotJson | Out-File "$Path\AutopilotConfigurationFile.json" -Encoding ascii -Force
}

#=================== SetupComplete Script ===================#
function Write-SetupComplete {
    $ScriptContent = @'
@echo off
PowerShell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -Command "
$LogPath = 'C:\Windows\Temp\AutopilotRegister.log'
Start-Transcript -Path $LogPath -Append
try {
    if (Get-Command 'mdmdiagnosticstool.exe' -ErrorAction SilentlyContinue) {
        $HardwareHash = 'C:\HardwareHash.csv'
        mdmdiagnosticstool.exe -CollectHardwareHash -Output $HardwareHash
        Write-Output 'Hardware hash collected to $HardwareHash'

        mdmdiagnosticstool.exe -area Autopilot -cab 'C:\AutopilotDiag.cab'
        Write-Output 'Autopilot diagnostics collected.'
    }

    schtasks /run /tn "Microsoft\Windows\EnterpriseMgmt\Schedule created by enrollment client for automatically setting up the device"
    Write-Output 'Enrollment task triggered.'

    rundll32.exe shell32.dll,Control_RunDLL "sysdm.cpl,,4"
} catch {
    Write-Output \"Error during autopilot script: $_\"
} finally {
    Stop-Transcript
}"
'@

    $SetupPath = "C:\Windows\Setup\Scripts"
    New-Item -Path $SetupPath -ItemType Directory -Force | Out-Null
    $ScriptContent | Out-File "$SetupPath\SetupComplete.cmd" -Encoding ascii -Force
}

#=================== Record Deployment Info ===================#
function Write-DeploymentInfo {
    param (
        [string]$GroupTag
    )
    @"
Deployment Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Group Tag: $GroupTag
Deployed By: OSDCloud PXE
"@ | Out-File "C:\ProgramData\OSDeploy\DeploymentInfo.txt" -Encoding utf8 -Force
}

#=================== Final Reboot ===================#
function Reboot-System {
    Write-Host "`nDeployment complete. Rebooting into full OS..." -ForegroundColor Green
    Start-Sleep -Seconds 5
    Restart-Computer -Force
}

#=================== Execute Deployment ===================#
Start-DeploymentLog
Initialize-DiskLayout
Deploy-WindowsImage
$GroupTag = Get-DeviceGroupTag
Write-OOBEConfig -GroupTag $GroupTag
Write-AutopilotConfig -GroupTag $GroupTag
Write-SetupComplete
Write-DeploymentInfo -GroupTag $GroupTag
Stop-Transcript
Reboot-System
