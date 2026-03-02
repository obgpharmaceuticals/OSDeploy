# Start transcript logging
Start-Transcript -Path "X:\DeployScript.log" -Append

try {
    Write-Host "Starting Windows 11 User-Driven Deployment..." -ForegroundColor Cyan

    # === User Selection for GroupTag ===
    Write-Host "Select system type (User-Driven Profiles):"
    Write-Host "1. Productivity Desktop"
    Write-Host "2. Productivity Laptop"
    Write-Host "3. Line of Business Desktop"
    Write-Host "4. Productivity Laptop UD Test"
    $selection = Read-Host "Enter choice (1-4)"

    switch ($selection) {
        '1' { $GroupTag = "ProductivityDesktop11" }
        '2' { $GroupTag = "ProductivityLaptop11" }
        '3' { $GroupTag = "LineOfBusinessDesktop11" }
        '4' { $GroupTag = "ProductivityLaptop11UD" }
        default {
            Write-Warning "Invalid choice. Defaulting to ProductivityDesktop"
            $GroupTag = "ProductivityDesktop11"
        }
    }
    Write-Host "GroupTag set to: $GroupTag"

    # === Disk Preparation ===
    $Disk = Get-Disk | Where-Object { $_.IsSystem -eq $false -and $_.OperationalStatus -eq "Online" -and $_.BusType -in @("NVMe","SATA","SCSI","ATA") } | Sort-Object -Property Size -Descending | Select-Object -First 1
    if (-not $Disk) { throw "No suitable disk found." }
    $DiskNumber = $Disk.Number

    Write-Host "Clearing and partitioning disk $DiskNumber ($($Disk.FriendlyName))"
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -Confirm:$false

    # EFI 512MB
    $ESP = New-Partition -DiskNumber $DiskNumber -Size 512MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
    Format-Volume -Partition $ESP -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    $ESP | Set-Partition -NewDriveLetter S

    # MSR 128MB
    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null

    # OS Partition
    $OSPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize
    Format-Volume -Partition $OSPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $OSPartition.PartitionNumber -NewDriveLetter C

    # === Map Deployment Share and Apply WIM ===
    $ClientIP = (Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true -and $_.IPAddress -ne $null } | ForEach-Object { $_.IPAddress } | Where-Object { $_ -notlike "169.*" -and $_ -ne "127.0.0.1" } | Select-Object -First 1)
    if (-not $ClientIP) { throw "Could not determine client IP address." }

    $DeploymentServers = @{ "10.1.192" = "10.1.192.20"; "10.3.192" = "10.3.192.
