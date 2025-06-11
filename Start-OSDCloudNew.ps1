Write-Host "Starting Deployment Script..." -ForegroundColor Cyan
Start-Transcript -Path "X:\DeployScript.log" -Append

try {
    # Select disk: Online, GPT or RAW, size > 30GB, largest first
    $Disk = Get-Disk | Where-Object { $_.OperationalStatus -eq 'Online' -and ($_.PartitionStyle -eq 'RAW' -or $_.PartitionStyle -eq 'GPT') -and $_.Size -gt 30GB } | Sort-Object Size -Descending | Select-Object -First 1
    if (-not $Disk) { throw "No suitable disk found." }
    $DiskNumber = $Disk.Number
    Write-Host "Selected disk $DiskNumber (Size: $([math]::Round($Disk.Size/1GB,2)) GB)"

    # Clean and initialize disk
    Write-Host "Cleaning disk $DiskNumber..."
    Clear-Disk -Number $DiskNumber -RemoveData -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT

    # Create EFI system partition (100 MB, FAT32)
    Write-Host "Creating EFI partition..."
    $EfiPartition = New-Partition -DiskNumber $DiskNumber -Size 100MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}" -AssignDriveLetter

    # Wait for EFI volume to become ready
    $EfiVolume = $null
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 1
        $EfiVolume = Get-Volume -Partition $EfiPartition -ErrorAction SilentlyContinue
        if ($EfiVolume) { break }
    }
    if (-not $EfiVolume) { throw "EFI volume not found after partition creation." }

    Format-Volume -Partition $EfiPartition -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $EfiPartition.PartitionNumber -NewDriveLetter "S"

    # Create MSR partition (128 MB, no drive letter)
    Write-Host "Creating MSR partition..."
    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null

    # Create Data partition (10 GB NTFS) for WIM storage
    Write-Host "Creating data partition for WIM storage..."
    $DataPartition = New-Partition -DiskNumber $DiskNumber -Size 10GB -AssignDriveLetter
    $DataVolume = $null
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 1
        $DataVolume = Get-Volume -Partition $DataPartition -ErrorAction SilentlyContinue
        if ($DataVolume) { break }
    }
    if (-not $DataVolume) { throw "Data volume not found." }

    Format-Volume -Partition $DataPartition -FileSystem NTFS -NewFileSystemLabel "Data" -Confirm:$false
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $DataPartition.PartitionNumber -NewDriveLetter "D"

    # Create Windows partition (remaining space NTFS)
    Write-Host "Creating Windows partition..."
    $WindowsPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter
    $WindowsVolume = $null
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 1
        $WindowsVolume = Get-Volume -Partition $WindowsPartition -ErrorAction SilentlyContinue
        if ($WindowsVolume) { break }
    }
    if (-not $WindowsVolume) { throw "Windows volume not found." }

    Format-Volume -Partition $WindowsPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $WindowsPartition.PartitionNumber -NewDriveLetter "C"

    Write-Host "Partitions created: EFI (S:), Data (D:), Windows (C:)"

    # Download WIM file
    $WimUrl = "http://10.1.192.20/install.wim"
    $LocalWim = "D:\install.wim"
    Write-Host "Downloading WIM from $WimUrl to $LocalWim..."
    Invoke-WebRequest -Uri $WimUrl -OutFile $LocalWim -UseBasicParsing

    # Apply Windows image
    Write-Host "Applying Windows image to C: drive..."
    dism.exe /Apply-Image /ImageFile:$LocalWim /Index:1 /ApplyDir:C:\

    # Setup boot configuration
    Write-Host "Setting up boot configuration..."
    bcdboot C:\Windows /s S: /f UEFI

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
            default { Write-Host "Invalid choice, please try again." }
        }
    } until ($GroupTag -ne "NotSet")

    # Create OOBE.json
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
    New-Item -Path $OOBEPath -ItemType Directory -Force | Out-Null
    $OOBEJson | Out-File "$OOBEPath\OOBE.json" -Encoding ascii -Force

    # Create AutopilotConfigurationFile.json
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

    # Create SetupComplete.cmd
    $FirstLogonScript = @'
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
    schtasks /run /tn 'Microsoft\Windows\EnterpriseMgmt\Schedule created by enrollment client for automatically setting up the device'
    Write-Output 'Enrollment task triggered.'
    rundll32.exe shell32.dll,Control_RunDLL 'sysdm.cpl,,4'
} catch {
    Write-Output 'Error during autopilot script: $_'
} finally {
    Stop-Transcript
}"
'@
    $SetupScripts = "C:\Windows\Setup\Scripts"
    New-Item -Path $SetupScripts -ItemType Directory -Force | Out-Null
    $FirstLogonScript | Out-File "$SetupScripts\SetupComplete.cmd" -Encoding ascii -Force

    Write-Host "`nDeployment complete. The system will reboot in 10 seconds..." -ForegroundColor Green
    Start-Sleep -Seconds 10
    # Uncomment below to enable reboot
    # Restart-Computer -Force
}
catch {
    Write-Error "Deployment failed: $_"
}
finally {
    try { Stop-Transcript } catch {}
}
