# Select system type
Write-Host "Select System Type:" -ForegroundColor Yellow
Write-Host "1. Productivity Desktop"
Write-Host "2. Productivity Laptop"
Write-Host "3. Line of Business Desktop"
$choice = Read-Host "Enter choice [1,2,3]"

switch ($choice) {
    '1' { $GroupTag = "ProductivityDesktop" }
    '2' { $GroupTag = "ProductivityLaptop" }
    '3' { $GroupTag = "LineOfBusinessDesktop" }
    default { Write-Error "Invalid choice"; exit }
}

Write-Host "Wiping and reinitializing system disk..."

# Assume disk 0 is target disk, modify if needed
$disk = Get-Disk -Number 0

# Clean disk completely
Clear-Disk -Number $disk.Number -RemoveData -Confirm:$false

# Initialize as GPT
Initialize-Disk -Number $disk.Number -PartitionStyle GPT

# Create partitions:
# EFI System Partition (100 MB)
$efi = New-Partition -DiskNumber $disk.Number -Size 100MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}"
Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel "SYSTEM" -Confirm:$false

# MSR Partition (16 MB)
New-Partition -DiskNumber $disk.Number -Size 16MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null

# OS partition (rest of disk)
$osPartition = New-Partition -DiskNumber $disk.Number -UseMaximumSize
Format-Volume -Partition $osPartition -FileSystem NTFS -NewFileSystemLabel "OS" -Confirm:$false

# Assign drive letter C:
$osPartition | Set-Partition -NewDriveLetter C

# Apply Windows image directly from network path
$WIMPath = "\\10.1.192.20\install.wim"  # Use UNC path or http if supported
$ImageIndex = 1  # Select appropriate image index from WIM

Write-Host "Applying Windows image to C:..."

dism /Apply-Image /ImageFile:$WIMPath /Index:$ImageIndex /ApplyDir:C:\

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to apply Windows image"
    exit 1
}

# Configure boot files
bcdboot C:\Windows /s $efi.DriveLetter: /f UEFI

Write-Host "Image applied successfully. Continuing setup..."

# Setup Autopilot folder, OOBE configs, app removals, etc.
# ... your logic here to create provisioning files with $GroupTag, tenant IDs ...

# Reboot to continue OOBE
# Restart-Computer -Force
