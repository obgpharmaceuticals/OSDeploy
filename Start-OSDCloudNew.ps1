# Start transcript
Start-Transcript -Path "X:\DeployScript.log" -Append

try {
    Write-Host "Starting deployment test..." -ForegroundColor Cyan

    # Prompt for system type
    Write-Host "Select system type:"
    Write-Host "1. Productivity Desktop"
    Write-Host "2. Productivity Laptop"
    Write-Host "3. Line of Business Desktop"
    $selection = Read-Host "Enter choice (1-3)"
    switch ($selection) {
        '1' { $GroupTag = "ProductivityDesktop" }
        '2' { $GroupTag = "ProductivityLaptop" }
        '3' { $GroupTag = "LineOfBusinessDesktop" }
        default {
            Write-Warning "Invalid choice. Defaulting to ProductivityDesktop"
            $GroupTag = "ProductivityDesktop"
        }
    }
    Write-Host "GroupTag set to: $GroupTag"

    # Select and prepare disk
    $Disk = Get-Disk | Where-Object {
        $_.OperationalStatus -eq 'Online' -and
        ($_.PartitionStyle -eq 'RAW' -or $_.PartitionStyle -eq 'GPT') -and
        $_.Size -gt 30GB
    } | Sort-Object Size -Descending | Select-Object -First 1

    if (-not $Disk) { throw "No suitable disk found." }
    $DiskNumber = $Disk.Number
    Write-Host "Selected disk $DiskNumber (Size: $([math]::Round($Disk.Size/1GB,2)) GB)"

    # Clean and initialize disk
    Write-Host "Cleaning disk $DiskNumber..."
    Clear-Disk -Number $DiskNumber -RemoveData -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT

    # Create partitions WITHOUT drive letters assigned
    Write-Host "Creating EFI partition (100 MB)..."
    $EfiPartition = New-Partition -DiskNumber $DiskNumber -Size 100MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
    Write-Host "Creating MSR partition (128 MB)..."
    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null
    Write-Host "Creating Data partition (10 GB)..."
    $DataPartition = New-Partition -DiskNumber $DiskNumber -Size 10GB
    Write-Host "Creating Windows partition (remaining space)..."
    $WindowsPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize

    # Format and assign drive letters, waiting to ensure system updates volume info
    Write-Host "Formatting EFI partition and assigning drive letter S:"
    Format-Volume -Partition $EfiPartition -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    Start-Sleep -Seconds 3
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $EfiPartition.PartitionNumber -NewDriveLetter S

    Write-Host "Formatting Data partition and assigning drive letter D:"
    Format-Volume -Partition $DataPartition -FileSystem NTFS -NewFileSystemLabel "Data" -Confirm:$false
    Start-Sleep -Seconds 3
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $DataPartition.PartitionNumber -NewDriveLetter D

    Write-Host "Formatting Windows partition and assigning drive letter C:"
    Format-Volume -Partition $WindowsPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Start-Sleep -Seconds 3
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $WindowsPartition.PartitionNumber -NewDriveLetter C

    Write-Host "Partitions created with drive letters: EFI (S:), Data (D:), Windows (C:)"

    # Download Windows install.wim to Data partition
    #    $WimUrl = "http://10.1.192.20/install.wim"
    #    $LocalWim = "D:\install.wim"
    #    Write-Host "Downloading WIM from $WimUrl to $LocalWim..."
    #    Invoke-WebRequest -Uri $WimUrl -OutFile $LocalWim -UseBasicParsing

    # Apply WIM image to C:
    Write-Host "Applying Windows image to C: drive..."
    # dism.exe /Apply-Image /ImageFile:$LocalWim /Index:1 /ApplyDir:C:\
    dism.exe /Apply-Image /ImageFile:E:\install.wim /Index:1 /ApplyDir:C:\

    # Setup boot files in EFI partition
    Write-Host "Setting up boot configuration..."
    bcdboot C:\Windows /s S: /f UEFI

    # Create AutopilotConfigurationFile.json in Windows partition
    $AutopilotConfig = @{
        CloudAssignedTenantId = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain = "obgpharma.onmicrosoft.com"
        GroupTag = $GroupTag
    }
    $AutopilotConfigPath = "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot\AutopilotConfigurationFile.json"
    Write-Host "Creating AutopilotConfigurationFile.json..."
    $AutopilotConfig | ConvertTo-Json -Depth 3 | Out-File -FilePath $AutopilotConfigPath -Encoding utf8

    # Create OOBE.json in Windows partition for Autopilot OOBE and app removals
    $OOBEJson = @{
        "CloudAssignedTenantId" = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        "CloudAssignedTenantDomain" = "obgpharma.onmicrosoft.com"
        "DeviceType" = $GroupTag
        "EnableUserStatusTracking" = $true
        "EnableUserConfirmation" = $true
        "EnableProvisioningDiagnostics" = $true
        "DeviceLicensingType" = "WindowsEnterprise"
        "Language" = "en-GB"
        "RemovePreInstalledApps" = @(
            "Microsoft.ZuneMusic",
            "Microsoft.XboxApp",
            "Microsoft.XboxGameOverlay",
            "Microsoft.XboxGamingOverlay",
            "Microsoft.XboxSpeechToTextOverlay",
            "Microsoft.YourPhone",
            "Microsoft.Getstarted",
            "Microsoft.3DBuilder"
        )
    }
    $OOBEJsonPath = "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot\OOBE.json"
    Write-Host "Creating OOBE.json..."
    $OOBEJson | ConvertTo-Json -Depth 5 | Out-File -FilePath $OOBEJsonPath -Encoding utf8

    # Create SetupComplete.cmd to upload Autopilot hardware hash on first logon
    $SetupCompletePath = "C:\Windows\Setup\Scripts\SetupComplete.cmd"
    Write-Host "Creating SetupComplete.cmd..."
    $SetupCompleteContent = @"
@echo off
powershell.exe -ExecutionPolicy Bypass -NoProfile -Command `
    "Import-Module WindowsAutopilotIntune; `
    \$ErrorActionPreference = 'Stop'; `
    Get-WindowsAutopilotInfo -Online -OutputFile 'C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot\hardwarehash.csv'; `
    Write-Host 'Uploading hardware hash to Intune...'; `
    # You can insert here your custom upload logic or API call if needed `
    "
exit
"@
    # Ensure the directory exists
    New-Item -ItemType Directory -Path (Split-Path $SetupCompletePath) -Force | Out-Null
    $SetupCompleteContent | Out-File -FilePath $SetupCompletePath -Encoding ASCII

    Write-Host "SetupComplete.cmd created successfully."

    Write-Host "Deployment script completed successfully. Rebooting in 5 seconds..."
    Start-Sleep -Seconds 5
    # Restart-Computer -Force
}
catch {
    Write-Error "Deployment failed: $_"
}
finally {
    try { Stop-Transcript } catch {}
}
