# ========== Logging Setup ==========
$LogFile = "X:\DeployScript.log"
"[$(Get-Date -Format 'u')] Starting Deployment Script..." | Out-File $LogFile -Append
function Log {
    param([string]$Message)
    "[$(Get-Date -Format 'u')] $Message" | Out-File $LogFile -Append
}
Log "=== Starting Windows 11 Deployment ==="

# ========== Select Target Disk ==========
$Disk = Get-Disk | Where-Object {
    $_.OperationalStatus -eq 'Online' -and
    ($_.PartitionStyle -eq 'RAW' -or $_.Size -gt 30GB)
} | Sort-Object Size -Descending | Select-Object -First 1

if (-not $Disk) {
    Log "❌ No suitable target disk found."
    exit 1
}

$DiskNumber = $Disk.Number
Log "✔ Targeting Disk $DiskNumber"

# ========== Disk Partitioning ==========
try {
    Clear-Disk -Number $DiskNumber -RemoveData -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT
    Log "✔ Disk cleared and initialized"
    
    # EFI System Partition
    $EFI = New-Partition -DiskNumber $DiskNumber -Size 100MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" -AssignDriveLetter
    Format-Volume -Partition $EFI -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    Log "✔ EFI partition created"

    # Microsoft Reserved Partition (no format, no letter)
    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null
    Log "✔ MSR partition created"

    # Primary partition (C:)
    $Primary = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $Primary -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-Partition -PartitionNumber $Primary.PartitionNumber -DiskNumber $DiskNumber -NewDriveLetter "C"
    Log "✔ Windows partition created and formatted as C:"
}
catch {
    Log "❌ Disk partitioning failed: $_"
    exit 1
}

# ========== Optional 10GB D: Data Partition ==========
$RemainingSize = ($Disk | Get-PartitionSupportedSize -PartitionNumber $Primary.PartitionNumber).SizeMax
if ($RemainingSize -gt 10GB) {
    try {
        $Data = New-Partition -DiskNumber $DiskNumber -Size 10GB -AssignDriveLetter
        Format-Volume -Partition $Data -FileSystem NTFS -NewFileSystemLabel "Data" -Confirm:$false
        Set-Partition -PartitionNumber $Data.PartitionNumber -DiskNumber $DiskNumber -NewDriveLetter "D"
        Log "✔ Optional 10GB D: data partition created"
    } catch {
        Log "⚠️ Failed to create optional D: partition: $_"
    }
}

# ========== Download and Apply WIM ==========
$WimUrl = "http://10.1.192.20/install.wim"
$LocalWim = "C:\install.wim"
try {
    Log "📥 Downloading install.wim from $WimUrl"
    Invoke-WebRequest -Uri $WimUrl -OutFile $LocalWim
    Log "✔ Downloaded install.wim to $LocalWim"
} catch {
    Log "❌ Failed to download WIM: $_"
    exit 1
}

try {
    Log "📦 Applying WIM to C:"
    dism.exe /Apply-Image /ImageFile:$LocalWim /Index:1 /ApplyDir:C:\ | Out-Null
    Log "✔ WIM applied"
} catch {
    Log "❌ Failed to apply image: $_"
    exit 1
}

# ========== Configure Boot ==========
try {
    bcdboot C:\Windows /s $($EFI.DriveLetter): /f UEFI
    Log "✔ Boot configuration completed"
} catch {
    Log "❌ Failed to configure boot: $_"
}

# ========== Prompt for GroupTag ==========
$GroupTag = "NotSet"
do {
    Write-Host "Select System Type:" -ForegroundColor Yellow
    Write-Host "1: Productivity Desktop"
    Write-Host "2: Productivity Laptop"
    Write-Host "3: Line of Business"
    $choice = Read-Host "Enter choice"
    switch ($choice) {
        '1' { $GroupTag = "ProductivityDesktop" }
        '2' { $GroupTag = "ProductivityLaptop" }
        '3' { $GroupTag = "LineOfBusinessDesktop" }
        default { Write-Host "Invalid choice"; $GroupTag = "NotSet" }
    }
} until ($GroupTag -ne "NotSet")
Log "✔ Selected GroupTag: $GroupTag"

# ========== Write OOBE.json ==========
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
$OOBEPath = "C:\ProgramData\OSDeploy"
New-Item -ItemType Directory -Path $OOBEPath -Force | Out-Null
$OOBEJson | Out-File "$OOBEPath\OOBE.json" -Encoding ascii -Force
Log "✔ Wrote OOBE.json"

# ========== Write Autopilot Config ==========
$AutoPilotJson = @{
    CloudAssignedOobeConfig       = 131
    CloudAssignedTenantId         = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
    CloudAssignedDomainJoinMethod = 0
    ZtdCorrelationId              = (New-Guid).Guid
    CloudAssignedTenantDomain     = "obgpharma.onmicrosoft.com"
    CloudAssignedUserUpn          = ""
    CloudAssignedGroupTag         = $GroupTag
} | ConvertTo-Json -Depth 10

$AutoPilotPath = "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
New-Item -Path $AutoPilotPath -ItemType Directory -Force | Out-Null
$AutoPilotJson | Out-File "$AutoPilotPath\AutopilotConfigurationFile.json" -Encoding ascii -Force
Log "✔ Wrote AutopilotConfigurationFile.json"

# ========== SetupComplete.cmd for Hardware Hash ==========
$SetupComplete = @'
@echo off
PowerShell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -Command "
$LogPath = 'C:\Windows\Temp\AutopilotRegister.log'
'Starting Autopilot Script' | Out-File $LogPath -Append
try {
    if (Get-Command 'mdmdiagnosticstool.exe' -ErrorAction SilentlyContinue) {
        mdmdiagnosticstool.exe -CollectHardwareHash -Output 'C:\HardwareHash.csv'
        mdmdiagnosticstool.exe -area Autopilot -cab 'C:\AutopilotDiag.cab'
    }
    schtasks /run /tn 'Microsoft\\Windows\\EnterpriseMgmt\\Schedule created by enrollment client for automatically setting up the device'
} catch {
    'Error during autopilot script' | Out-File $LogPath -Append
}
"
'@

$SetupScripts = "C:\Windows\Setup\Scripts"
New-Item -ItemType Directory -Path $SetupScripts -Force | Out-Null
$SetupComplete | Out-File "$SetupScripts\SetupComplete.cmd" -Encoding ascii -Force
Log "✔ SetupComplete.cmd written"

# ========== Final ==========
Log "✅ Deployment completed. Rebooting..."
Start-Sleep -Seconds 5
# Restart-Computer -Force
