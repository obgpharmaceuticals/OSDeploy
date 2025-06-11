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

    # Create partitions without drive letters
    Write-Host "Creating partitions..."
    $EfiPartition     = New-Partition -DiskNumber $DiskNumber -Size 100MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}" -IsActive:$true
    $MsrPartition     = New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}"
    $DataPartition    = New-Partition -DiskNumber $DiskNumber -Size 10GB -GptType "{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}"
    $WindowsPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -GptType "{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}"

    # Wait to allow volume recognition
    Start-Sleep -Seconds 2

    # Assign drive letters explicitly
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $EfiPartition.PartitionNumber -NewDriveLetter S
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $DataPartition.PartitionNumber -NewDriveLetter D
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $WindowsPartition.PartitionNumber -NewDriveLetter W

    # Format partitions
    Write-Host "Formatting partitions..."
    Format-Volume -DriveLetter S -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    Format-Volume -DriveLetter D -FileSystem NTFS -NewFileSystemLabel "Data" -Confirm:$false
    Format-Volume -DriveLetter W -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false

    Write-Host "Partitions created: EFI (S:), Data (D:), Windows (W:)"

    # Download WIM file to Data partition
    $WimUrl = "http://10.1.192.20/install.wim"
    $LocalWim = "D:\install.wim"
    Write-Host "Downloading WIM from $WimUrl to $LocalWim..."
    Invoke-WebRequest -Uri $WimUrl -OutFile $LocalWim -UseBasicParsing

    # Apply WIM image to Windows partition (W:)
    Write-Host "Applying Windows image to W: drive..."
    dism.exe /Apply-Image /ImageFile:$LocalWim /Index:1 /ApplyDir:W:\

    # Setup boot files in EFI partition
    Write-Host "Setting up boot configuration..."
    bcdboot W:\Windows /s S: /f UEFI

    # Prompt for device type and set GroupTag
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
    $OOBEPath = "W:\ProgramData\OSDeploy"
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
    $AutoPilotPath = "W:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
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
    schtasks /run /tn "Microsoft\Windows\EnterpriseMgmt\Schedule created by enrollment client for automatically setting up the device"
    Write-Output 'Enrollment task triggered.'
    rundll32.exe shell32.dll,Control_RunDLL "sysdm.cpl,,4"
} catch {
    Write-Output "Error during autopilot script: $_"
} finally {
    Stop-Transcript
}"
'@
    $SetupScripts = "W:\Windows\Setup\Scripts"
    New-Item -Path $SetupScripts -ItemType Directory -Force | Out-Null
    $FirstLogonScript | Out-File "$SetupScripts\SetupComplete.cmd" -Encoding ascii -Force

    Write-Host "`nDeployment complete. The system will reboot in 10 seconds..." -ForegroundColor Green
    Start-Sleep -Seconds 10
    # Restart-Computer -Force
}
catch {
    Write-Error "Deployment failed: $_"
}
finally {
    try { Stop-Transcript } catch {}
}
