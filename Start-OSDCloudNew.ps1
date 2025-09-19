# Start transcript logging 
Start-Transcript -Path "X:\DeployScript.log" -Append

# --- Ensure OSD module is present ---
try {
    # Make sure NuGet provider is installed (needed for Install-Module)
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force
    }

    # Install OSD module if missing
    if (-not (Get-Module -ListAvailable -Name OSD)) {
        Install-Module -Name OSD -Force -Scope CurrentUser
    }

    # Import OSD so its functions are ready
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

    # --- Disk partitioning (unchanged) ---
    $Disk = Get-Disk | Where-Object { $_.IsSystem -eq $false -and $_.OperationalStatus -eq "Online" -and $_.BusType -in @("NVMe","SATA","SCSI","ATA") } |
            Sort-Object -Property Size -Descending | Select-Object -First 1
    if (-not $Disk) { Write-Error "No suitable disk found."; exit 1 }

    $DiskNumber = $Disk.Number
    Write-Host "Selected disk number $DiskNumber ($($Disk.FriendlyName)) with BusType $($Disk.BusType)"

    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -Confirm:$false
    Set-Disk -Number $DiskNumber -IsOffline $false
    Set-Disk -Number $DiskNumber -IsReadOnly $false

    # EFI partition
    $ESP = New-Partition -DiskNumber $DiskNumber -Size 512MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
    Format-Volume -Partition $ESP -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    $ESP | Set-Partition -NewDriveLetter S

    # MSR partition
    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null

    # OS partition
    $OSPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize
    Format-Volume -Partition $OSPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $OSPartition.PartitionNumber -NewDriveLetter C
    Write-Host "Disk $DiskNumber partitioned successfully."

    # --- Determine client IP and choose deployment server (unchanged) ---
    $ClientIP = (Get-WmiObject Win32_NetworkAdapterConfiguration |
                 Where-Object { $_.IPEnabled -eq $true -and $_.IPAddress -ne $null } |
                 ForEach-Object { $_.IPAddress } |
                 Where-Object { $_ -notlike "169.*" -and $_ -ne "127.0.0.1" } |
                 Select-Object -First 1) 
    if (-not $ClientIP) { throw "Could not determine client IP." }

    $DeploymentServers = @{
        "10.1.192" = "10.1.192.20"
        "10.3.192" = "10.3.192.20"
        "10.5.192" = "10.5.192.20"
    }
    $Subnet = ($ClientIP -split "\.")[0..2] -join "."
    if ($DeploymentServers.ContainsKey($Subnet)) {
        $ServerIP = $DeploymentServers[$Subnet]
    } else { throw "No deployment server configured for subnet $Subnet" }

    $NetworkPath = "\\$ServerIP\ReadOnlyShare"
    net use M: /delete /yes > $null 2>&1
    net use M: $NetworkPath /persistent:no
    if ($LASTEXITCODE -ne 0) { throw "Failed to map share $NetworkPath" }

    # Apply image
    $WimPath = "M:\install.wim"
    if (-not (Test-Path $WimPath)) { throw "WIM not found at $WimPath" }
    Start-Process dism.exe -ArgumentList "/Apply-Image","/ImageFile:$WimPath","/Index:6","/ApplyDir:C:\" -Wait -PassThru | Out-Null

    # === Driver download and injection (updated) ===
    Write-Host "Starting live driver download and injection..." -ForegroundColor Cyan
    try {
        $Model  = (Get-CimInstance Win32_ComputerSystem).Model
        Write-Host "Detected hardware model: $Model"

        # Downloads the correct OEM pack and injects it into the offline C:\Windows
        Start-OSDDriverPack -Model $Model -Download -Inject -Path 'C:\'
        Write-Host "Driver pack downloaded and injected successfully."
    }
    catch {
        Write-Warning "Driver injection failed or model not supported: $_"
    }
    # === End driver injection section ===

    # ...rest of your deployment script continues unchanged...
}
catch {
    Write-Error "Deployment failed: $_"
}
finally {
    try { Stop-Transcript } catch {}
}
