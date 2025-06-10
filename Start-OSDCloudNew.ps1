$LogFile = "X:\DeployScript.log"
function Log { param($msg) "$(Get-Date -Format u) $msg" | Out-File $LogFile -Append }

Log "=== Starting Windows 11 Deployment ==="

try {
    # Select disk
    $Disk = Get-Disk | Where-Object {
        $_.OperationalStatus -eq 'Online' -and
        ($_.PartitionStyle -eq 'RAW' -or $_.Size -gt 30GB)
    } | Sort-Object Size -Descending | Select-Object -First 1

    if (-not $Disk) { throw "No suitable disk found." }
    $DiskNumber = $Disk.Number
    Log "Selected disk $DiskNumber (Size: $($Disk.Size/1GB) GB)"

    # Clear disk
    Log "Clearing disk $DiskNumber"
    Clear-Disk -Number $DiskNumber -RemoveData -Confirm:$false

    # Initialize
    Log "Initializing disk $DiskNumber with GPT"
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT

    # EFI Partition (100MB)
    Log "Creating EFI partition"
    $EFI = New-Partition -DiskNumber $DiskNumber -Size 100MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" -AssignDriveLetter
    Format-Volume -Partition $EFI -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false

    # MSR Partition (128MB)
    Log "Creating MSR partition"
    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null

    # Windows partition (rest)
    Log "Creating Windows partition"
    $Primary = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $Primary -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-Partition -PartitionNumber $Primary.PartitionNumber -DiskNumber $DiskNumber -NewDriveLetter "C"

    # Confirm partitions
    Log "Partitions created: EFI ($($EFI.DriveLetter):), Windows (C:)"

} catch {
    Log "ERROR in disk setup: $_"
    exit 1
}

# Download WIM
try {
    $WimUrl = "http://10.1.192.20/install.wim"
    $LocalWim = "C:\install.wim"
    Log "Downloading WIM from $WimUrl"
    Invoke-WebRequest -Uri $WimUrl -OutFile $LocalWim -UseBasicParsing
    Log "WIM downloaded successfully"
} catch {
    Log "ERROR downloading WIM: $_"
    exit 1
}

# Apply WIM
try {
    Log "Applying image to C:"
    dism.exe /Apply-Image /ImageFile:$LocalWim /Index:1 /ApplyDir:C:\ | Out-Null
    Log "Image applied successfully"
} catch {
    Log "ERROR applying image: $_"
    exit 1
}

# BCDBoot
try {
    Log "Configuring boot files"
    bcdboot C:\Windows /s $($EFI.DriveLetter): /f UEFI
    Log "Boot files configured"
} catch {
    Log "ERROR configuring boot: $_"
    exit 1
}

# Prompt for GroupTag
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
Log "GroupTag selected: $GroupTag"

# Rest of your OOBE.json, Autopilot config, SetupComplete.cmd writing here...
# (Can add logging similarly)

Log "Deployment script completed, restarting..."
Start-Sleep -Seconds 5
# Restart-Computer -Force
