# Start transcript logging 
Start-Transcript -Path "X:\DeployScript.log" -Append

try {
    Write-Host "Starting Windows 11 deployment..." -ForegroundColor Cyan

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

    $DiskNumber = 0

    Write-Host "Clearing disk $DiskNumber including OEM partitions..."
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false

    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -Confirm:$false
    Set-Disk -Number $DiskNumber -IsOffline $false
    Set-Disk -Number $DiskNumber -IsReadOnly $false

    $ESP = New-Partition -DiskNumber $DiskNumber -Size 260MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
    Format-Volume -Partition $ESP -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    $ESP | Set-Partition -NewDriveLetter S
    Write-Host "EFI partition assigned to drive letter: S"

    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null

    $OSPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize
    Format-Volume -Partition $OSPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $OSPartition.PartitionNumber -NewDriveLetter C

    Write-Host "Disk prepared successfully. Windows partition is now C:."

    Write-Host "Waiting for network connectivity..."
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-Connection -ComputerName 10.1.192.20 -Count 1 -Quiet) {
            Write-Host "Network is available."
            break
        }
        Start-Sleep -Seconds 2
        if ($i -eq 29) { throw "Network not available after timeout." }
    }

    $NetworkPath = "\\10.1.192.20\ReadOnlyShare"
    $DriveLetter = "M:"
    net use $DriveLetter /delete /yes > $null 2>&1
    Write-Host "Mapping $DriveLetter to $NetworkPath..."
    $mapResult = net use $DriveLetter $NetworkPath /persistent:no 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to map $DriveLetter to $NetworkPath. Error details: $mapResult"
    }

    $WimPath = "M:\install.wim"
    if (-not (Test-Path $WimPath)) {
        throw "WIM file not found at $WimPath"
    }
    Write-Host "Applying Windows image from $WimPath to C:..."
    $dism = Start-Process -FilePath dism.exe -ArgumentList "/Apply-Image", "/ImageFile:$WimPath", "/Index:1", "/ApplyDir:C:\" -Wait -PassThru
    if ($dism.ExitCode -ne 0) {
        throw "DISM failed with exit code $($dism.ExitCode)"
    }

    if (-not (Test-Path "C:\Windows\Boot\EFI\bootmgfw.efi")) {
        Write-Warning "Boot files missing in C:\Windows\Boot\EFI. Trying to proceed anyway..."
    } else {
        Write-Host "Boot files found. Continuing..."
    }

    if (-not (Test-Path "S:\EFI\Microsoft\Boot")) {
        Write-Host "Creating EFI folder structure..."
        New-Item -Path "S:\EFI\Microsoft\Boot" -ItemType Directory -Force | Out-Null
    }

    Write-Host "Running bcdboot to create UEFI boot entry..."
    $bcdResult = bcdboot C:\Windows /s S: /f UEFI
    Write-Host $bcdResult

    if (-not (Test-Path "S:\EFI\Microsoft\Boot\bootmgfw.efi")) {
        throw "bcdboot failed to write boot files. Disk will not boot."
    }

    if (-not (Test-Path "S:\EFI\Boot")) {
        New-Item -Path "S:\EFI\Boot" -ItemType Directory -Force | Out-Null
    }
    Copy-Item -Path "S:\EFI\Microsoft\Boot\bootmgfw.efi" -Destination "S:\EFI\Boot\bootx64.efi" -Force
    Write-Host "Boot files created successfully."

    $TargetFolders = @(
        "C:\Windows\Panther\Unattend",
        "C:\Windows\Setup\Scripts",
        "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
    )

    foreach ($Folder in $TargetFolders) {
        if (-not (Test-Path $Folder)) {
            New-Item -Path $Folder -ItemType Directory -Force | Out-Null
        }
    }

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
        SkipUserStatusPage            = $true
        SkipAccountSetup              = $true
        SkipOOBE                      = $true
        RemovePreInstalledApps        = @(
            "Microsoft.ZuneMusic", "Microsoft.XboxApp", "Microsoft.XboxGameOverlay",
            "Microsoft.XboxGamingOverlay", "Microsoft.XboxSpeechToTextOverlay",
            "Microsoft.YourPhone", "Microsoft.Getstarted", "Microsoft.3DBuilder"
        )
    }
    $OOBEJson | ConvertTo-Json -Depth 5 | Out-File "$AutopilotFolder\OOBE.json" -Encoding utf8

    # FIXED: Clean unattend (no specialize section!)
    $UnattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>en-GB</InputLocale>
      <SystemLocale>en-GB</SystemLocale>
      <UILanguage>en-GB</UILanguage>
      <UserLocale>en-GB</UserLocale>
    </component>
  </settings>
</unattend>
"@
    Set-Content -Path "C:\Windows\Panther\Unattend\Unattend.xml" -Value $UnattendXml -Encoding UTF8

    $AutoPilotScriptPath = "C:\Autopilot\Get-WindowsAutoPilotInfo.ps1"
    $AutoPilotScriptURL = "http://10.1.192.20/Get-WindowsAutoPilotInfo.ps1"
    New-Item -ItemType Directory -Path "C:\Autopilot" -Force | Out-Null
    try {
        Invoke-WebRequest -Uri $AutoPilotScriptURL -OutFile $AutoPilotScriptPath -UseBasicParsing -ErrorAction Stop
        Write-Host "Downloaded Get-WindowsAutoPilotInfo.ps1 successfully."
    } catch {
        Write-Warning "Failed to download Autopilot script: $_"
    }

    $TaskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"Start-Transcript -Path C:\Autopilot-Diag.txt -Append; ` 
        & 'C:\Autopilot\Get-WindowsAutoPilotInfo.ps1' -TenantId 'c95ebf8f-ebb1-45ad-8ef4-463fa94051ee' -AppId 'faa1bc75-81c7-4750-ac62-1e5ea3ac48c5' -AppSecret 'ouu8Q~h2IxPhfb3GP~o2pQOvn2HSmBkOm2D8hcB-' -GroupTag '$GroupTag' -Online -Assign; ` 
        Set-ItemProperty -Path 'HKLM:\SYSTEM\Setup' -Name OOBEInProgress -Value 0 -Force; ` 
        Set-ItemProperty -Path 'HKLM:\SYSTEM\Setup\Status\SysprepStatus' -Name CleanupState -Value 2 -Force; ` 
        Set-ItemProperty -Path 'HKLM:\SYSTEM\Setup\Status\SysprepStatus' -Name GeneralizationState -Value 7 -Force; ` 
        Stop-Transcript`""
    $TaskTrigger = New-ScheduledTaskTrigger -AtLogOn
    $TaskPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    Register-ScheduledTask -TaskName "AutopilotUpload" -Action $TaskAction -Trigger $TaskTrigger -Principal $TaskPrincipal -Force

    Write-Host "Scheduled Task created to upload Autopilot info after OOBE."
    Write-Host "Deployment script completed. Rebooting in 5 seconds..."
    Start-Sleep -Seconds 5
    Restart-Computer -Force

}
catch {
    Write-Error "Deployment failed: $_"
}
finally {
    try { Stop-Transcript } catch {}
}
