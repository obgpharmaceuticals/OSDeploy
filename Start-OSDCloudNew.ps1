# Start transcript logging
Start-Transcript -Path "X:\DeployScript.log" -Append

try {
    Write-Host "Starting Windows 11 OBG deployment..." -ForegroundColor Cyan

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

    # Find first suitable disk
    $Disk = Get-Disk | Where-Object { $_.IsSystem -eq $false -and $_.OperationalStatus -eq "Online" -and $_.BusType -in @("NVMe","SATA","SCSI","ATA") } | Sort-Object -Property Size -Descending | Select-Object -First 1
    if (-not $Disk) { Write-Error "No suitable disk found."; exit 1 }
    $DiskNumber = $Disk.Number
    Write-Host "Selected disk number $DiskNumber ($($Disk.FriendlyName)) with BusType $($Disk.BusType)"

    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -Confirm:$false
    Set-Disk -Number $DiskNumber -IsOffline $false
    Set-Disk -Number $DiskNumber -IsReadOnly $false

    # Partitioning
    $ESP = New-Partition -DiskNumber $DiskNumber -Size 512MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
    Format-Volume -Partition $ESP -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    $ESP | Set-Partition -NewDriveLetter S
    Write-Host "EFI partition assigned to S"

    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null

    $OSPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize
    Format-Volume -Partition $OSPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $OSPartition.PartitionNumber -NewDriveLetter C

    Write-Host "Disk $DiskNumber partitioned successfully."

    # Determine client IP
    $ClientIP = (Get-WmiObject Win32_NetworkAdapterConfiguration | 
        Where-Object { $_.IPEnabled -eq $true -and $_.IPAddress -ne $null } |
        ForEach-Object { $_.IPAddress } |
        Where-Object { $_ -notlike "169.*" -and $_ -ne "127.0.0.1" } |
        Select-Object -First 1)
    if (-not $ClientIP) { throw "Could not determine client IP address." }
    Write-Host "Client IP detected: $ClientIP"

    # Deployment server mapping
    $DeploymentServers = @{
        "10.1.192" = "10.1.192.20"
        "10.3.192" = "10.3.192.20"
        "10.5.192" = "10.5.192.20"
    }
    $Subnet = ($ClientIP -split "\.")[0..2] -join "."
    if ($DeploymentServers.ContainsKey($Subnet)) {
        $ServerIP = $DeploymentServers[$Subnet]
        Write-Host "Deployment server selected: $ServerIP"
    } else { throw "No deployment server configured for subnet $Subnet" }

    $NetworkPath = "\\$ServerIP\ReadOnlyShare"
    $DriveLetter = "M:"
    net use $DriveLetter /delete /yes > $null 2>&1
    Write-Host "Mapping $DriveLetter to $NetworkPath..."
    $mapResult = net use $DriveLetter $NetworkPath /persistent:no 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to map $DriveLetter to $NetworkPath. $mapResult" }

    $WimPath = "m:\install.wim"
    if (-not (Test-Path $WimPath)) { throw "WIM file not found at $WimPath" }
    Write-Host "Applying Windows image..."
    $dism = Start-Process -FilePath dism.exe -ArgumentList "/Apply-Image","/ImageFile:$WimPath","/Index:6","/ApplyDir:C:\" -Wait -PassThru
    if ($dism.ExitCode -ne 0) { throw "DISM failed with exit code $($dism.ExitCode)" }

    # --- OSDCloud installation + driver injection ---
    try {
        Write-Host "Installing OSDCloud module and injecting drivers..." -ForegroundColor Cyan
        Set-ExecutionPolicy Bypass -Scope Process -Force

        # Trust PSGallery
        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Name PSGallery -SourceLocation 'https://www.powershellgallery.com/api/v2' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        } else { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted }

        # Install OSDCloud if missing
        if (-not (Get-Module -ListAvailable -Name OSDCloud)) {
            Install-Module -Name OSDCloud -Force -SkipPublisherCheck -AllowClobber -Scope AllUsers
        }

        Import-Module OSDCloud -Force -ErrorAction Stop

        # Download driver pack
        $DriverFolder = "C:\OSDDrivers"
        if (-not (Test-Path $DriverFolder)) { New-Item -Path $DriverFolder -ItemType Directory -Force }

        Write-Host "Downloading and injecting drivers..."
        Get-OSDCloudDriverPack -DestinationPath $DriverFolder -Download -ErrorAction Stop
        Add-WindowsDriver -Path "C:\" -Driver $DriverFolder -Recurse -ForceUnsigned -ErrorAction Stop
        Write-Host "Driver injection completed."
    } catch { Write-Warning "Driver injection failed: $_. Continuing..." }

    # Disable ZDP offline
    reg load HKLM\TempHive C:\Windows\System32\config\SOFTWARE
    reg add "HKLM\TempHive\Microsoft\Windows\CurrentVersion\OOBE" /v DisableZDP /t REG_DWORD /d 1 /f
    reg unload HKLM\TempHive
    Write-Host "ZDP disabled."

    # Boot files
    if (-not (Test-Path "S:\EFI\Microsoft\Boot")) { New-Item -Path "S:\EFI\Microsoft\Boot" -ItemType Directory -Force | Out-Null }
    Write-Host "Running bcdboot..."
    $bcdResult = bcdboot C:\Windows /s S: /f UEFI
    Write-Host $bcdResult
    if (-not (Test-Path "S:\EFI\Microsoft\Boot\bootmgfw.efi")) { throw "bcdboot failed" }
    if (-not (Test-Path "S:\EFI\Boot")) { New-Item -Path "S:\EFI\Boot" -ItemType Directory -Force | Out-Null }
    Copy-Item -Path "S:\EFI\Microsoft\Boot\bootmgfw.efi" -Destination "S:\EFI\Boot\bootx64.efi" -Force
    Write-Host "Boot files created."

    # Prepare Autopilot folders and JSONs
    $TargetFolders = @("C:\Windows\Panther\Unattend","C:\Windows\Setup\Scripts","C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot","C:\Autopilot")
    foreach ($Folder in $TargetFolders) { if (-not (Test-Path $Folder)) { New-Item -Path $Folder -ItemType Directory -Force | Out-Null } }

    $AutopilotFolder = "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
    $AutopilotConfig = @{
        CloudAssignedTenantId    = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain = "obgpharma.onmicrosoft.com"
        GroupTag                 = $GroupTag
    }
    $AutopilotConfig | ConvertTo-Json -Depth 3 | Out-File "$AutopilotFolder\AutopilotConfigurationFile.json" -Encoding utf8

    $OOBEJson = @{
        CloudAssignedTenantId         = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain     = "obgpharma.onmicrosoft.com"
        DeviceType                    = $GroupTag
        EnableUserStatusTracking      = $true
        EnableUserConfirmation        = $true
        EnableProvisioningDiagnostics = $true
        DeviceLicensingType           = "WindowsEnterprise"
        Language                      = "en-GB"
        SkipZDP                       = $true
        SkipUserStatusPage            = $false
        SkipAccountSetup              = $false
        SkipOOBE                      = $false
        RemovePreInstalledApps        = @("Microsoft.ZuneMusic","Microsoft.XboxApp","Microsoft.XboxGameOverlay","Microsoft.XboxGamingOverlay","Microsoft.XboxSpeechToTextOverlay","Microsoft.YourPhone","Microsoft.Getstarted","Microsoft.3DBuilder")
    }
    $OOBEJson | ConvertTo-Json -Depth 5 | Out-File "$AutopilotFolder\OOBE.json" -Encoding utf8

    Write-Host "Deployment script completed. Rebooting in 5 seconds..."
    Start-Sleep -Seconds 5
    # Restart-Computer -Force
}
catch { Write-Error "Deployment failed: $_" }
finally { try { Stop-Transcript } catch {} }
