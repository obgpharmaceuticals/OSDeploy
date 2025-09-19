# Start transcript logging 
Start-Transcript -Path "X:\DeployScript.log" -Append

# --- Added: Ensure OSD module is present so Get-OSDCloudDriver works ---
try {
    # Make sure NuGet provider is installed (needed for Install-Module)
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force
    }

    # Install OSD module if missing
    if (-not (Get-Module -ListAvailable -Name OSD)) {
        Install-Module -Name OSD -Force -Scope CurrentUser
    }

    # Import OSD so its functions (e.g. Get-OSDCloudDriver) are ready
    Import-Module OSD -Force
    Write-Host "OSD module installed and imported successfully."
}
catch {
    Write-Warning "Failed to install or import OSD module: $_"
}
# --- End OSD module import section ---

try {
    Write-Host "Starting OBG Windows 11 deployment..." -ForegroundColor Cyan

    # Prompt for system type
    Write-Host "Select system type:"
    Write-Host "1. Productivity Desktop"
    Write-Host "2. Productivity Laptop"
    Write-Host "3. Line of Business Desktop"
    $selection = Read-Host "Enter choice (1-3)"
    switch ($selection) {
        '1' { $GroupTag = "ProductivityDesktop11" }
        '2' { $GroupTag = "ProductivityLaptop11" }
        '3' { $GroupTag = "LineOfBusinessDesktop11" }
        default {
            Write-Warning "Invalid choice. Defaulting to ProductivityDesktop"
            $GroupTag = "ProductivityDesktop11"
        }
    }
    Write-Host "GroupTag set to: $GroupTag"

    # Always wipe Disk 0
    $DiskNumber = 0

    # Find the first disk that is online, fixed, and has the largest size (usually your boot disk)
    $Disk = Get-Disk | Where-Object { $_.IsSystem -eq $false -and $_.OperationalStatus -eq "Online" -and $_.BusType -in @("NVMe", "SATA", "SCSI", "ATA") } | Sort-Object -Property Size -Descending | Select-Object -First 1

    if (-not $Disk) {
        Write-Error "No suitable disk found for installation."
        exit 1
    }

    $DiskNumber = $Disk.Number
    Write-Host "Selected disk number $DiskNumber ($($Disk.FriendlyName)) with BusType $($Disk.BusType)"

    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -Confirm:$false
    Set-Disk -Number $DiskNumber -IsOffline $false
    Set-Disk -Number $DiskNumber -IsReadOnly $false

    # EFI partition size 512MB (safe for all modern firmware)
    $ESP = New-Partition -DiskNumber $DiskNumber -Size 512MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
    Format-Volume -Partition $ESP -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    $ESP | Set-Partition -NewDriveLetter S
    Write-Host "EFI partition assigned to drive letter: S"

    # MSR partition 128MB
    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null

    # OS partition fills the rest of the disk
    $OSPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize
    Format-Volume -Partition $OSPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $OSPartition.PartitionNumber -NewDriveLetter C

    Write-Host "Disk $DiskNumber partitioned successfully."

    # --- Determine client IP using WMI (WinPE compatible) ---
    $ClientIP = (Get-WmiObject Win32_NetworkAdapterConfiguration | 
                 Where-Object { $_.IPEnabled -eq $true -and $_.IPAddress -ne $null } |
                 ForEach-Object { $_.IPAddress } |
                 Where-Object { $_ -notlike "169.*" -and $_ -ne "127.0.0.1" } |
                 Select-Object -First 1)

    if (-not $ClientIP) { throw "Could not determine client IP address." }

    Write-Host "Client IP detected: $ClientIP"

    # Define subnet to deployment server mapping
    $DeploymentServers = @{
        "10.1.192" = "10.1.192.20"
        "10.3.192" = "10.3.192.20"
        "10.5.192" = "10.5.192.20"
    }

    # Extract first three octets of client IP
    $Subnet = ($ClientIP -split "\.")[0..2] -join "."

    if ($DeploymentServers.ContainsKey($Subnet)) {
        $ServerIP = $DeploymentServers[$Subnet]
        Write-Host "Deployment server selected: $ServerIP"
    } else {
        throw "No deployment server configured for subnet $Subnet"
    }

    $NetworkPath = "\\$ServerIP\ReadOnlyShare"
    $DriveLetter = "M:"
    net use $DriveLetter /delete /yes > $null 2>&1
    Write-Host "Mapping $DriveLetter to $NetworkPath..."
    $mapResult = net use $DriveLetter $NetworkPath /persistent:no 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to map $DriveLetter to $NetworkPath. Error details: $mapResult"
    }

    $WimPath = "m:\install.wim"
    if (-not (Test-Path $WimPath)) {
        throw "WIM file not found at $WimPath"
    }
    Write-Host "Applying Windows image from $WimPath to C:..."
    $dism = Start-Process -FilePath dism.exe -ArgumentList "/Apply-Image", "/ImageFile:$WimPath", "/Index:6", "/ApplyDir:C:\" -Wait -PassThru
    if ($dism.ExitCode -ne 0) {
        throw "DISM failed with exit code $($dism.ExitCode)"
    }

    # === Driver download and injection ===
    Write-Host "Starting live driver download and injection..." -ForegroundColor Cyan
    try {
        $ComputerModel  = (Get-MyComputerModel).Trim()
        $ComputerVendor = (Get-MyComputerManufacturer).Trim()
        Write-Host "Detected hardware: $ComputerVendor $ComputerModel"

        # Download the latest driver pack from the OEM to C:\OSDDrivers
        $DriverPath = Get-OSDCloudDriver -Model $ComputerModel -Destination "C:\OSDDrivers"
        Write-Host "Driver package downloaded to $DriverPath"

        # Inject drivers into the offline Windows image (C:\)
        Invoke-OSDCloudDriver -Path "C:\" -DriverPath $DriverPath
        Write-Host "Driver injection into offline image complete."
    }
    catch {
        Write-Warning "Driver injection failed or model not supported: $_"
    }
    # === End driver injection section ===

    # (Remaining deployment steps unchanged…)
    # ...[rest of your script continues exactly as before]...
}
catch {
    Write-Error "Deployment failed: $_"
}
finally {
    try { Stop-Transcript } catch {}
}
