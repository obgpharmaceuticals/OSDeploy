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
    $Disk = Get-Disk | Where-Object {
        $_.IsSystem -eq $false -and $_.OperationalStatus -eq "Online" -and
        $_.BusType -in @("NVMe","SATA","SCSI","ATA")
    } | Sort-Object -Property Size -Descending | Select-Object -First 1
    if (-not $Disk) { throw "No suitable disk found for installation." }

    $DiskNumber = $Disk.Number
    Write-Host "Selected disk number $DiskNumber ($($Disk.FriendlyName)) with BusType $($Disk.BusType)"

    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -Confirm:$false
    Set-Disk -Number $DiskNumber -IsOffline $false
    Set-Disk -Number $DiskNumber -IsReadOnly $false

    # EFI + MSR + OS partitions
    $ESP = New-Partition -DiskNumber $DiskNumber -Size 512MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
    Format-Volume -Partition $ESP -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    $ESP | Set-Partition -NewDriveLetter S
    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null
    $OSPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize
    Format-Volume -Partition $OSPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $OSPartition.PartitionNumber -NewDriveLetter C
    Write-Host "Disk $DiskNumber partitioned successfully."

    # --- Determine client IP (WinPE compatible) ---
    $ClientIP = (Get-WmiObject Win32_NetworkAdapterConfiguration |
                 Where-Object { $_.IPEnabled -eq $true -and $_.IPAddress } |
                 ForEach-Object { $_.IPAddress } |
                 Where-Object { $_ -notlike "169.*" -and $_ -ne "127.0.0.1" } |
                 Select-Object -First 1)
    if (-not $ClientIP) { throw "Could not determine client IP address." }
    Write-Host "Client IP detected: $ClientIP"

    # Deployment server selection
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

    # Map network share and apply image
    $NetworkPath = "\\$ServerIP\ReadOnlyShare"
    $DriveLetter = "M:"
    net use $DriveLetter /delete /yes > $null 2>&1
    Write-Host "Mapping $DriveLetter to $NetworkPath..."
    $mapResult = net use $DriveLetter $NetworkPath /persistent:no 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to map $DriveLetter: $mapResult" }

    $WimPath = "m:\install.wim"
    if (-not (Test-Path $WimPath)) { throw "WIM file not found at $WimPath" }
    Write-Host "Applying Windows image from $WimPath to C:..."
    $dism = Start-Process -FilePath dism.exe -ArgumentList "/Apply-Image","/ImageFile:$WimPath","/Index:6","/ApplyDir:C:\" -Wait -PassThru
    if ($dism.ExitCode -ne 0) { throw "DISM failed with exit code $($dism.ExitCode)" }

    # === OEM DRIVER DOWNLOAD & INJECTION (optional) ===
    Write-Host "Attempting to download and inject OEM drivers..." -ForegroundColor Cyan
    try {
        if (-not (Get-Module -ListAvailable -Name OSDCloud)) {
            Set-ExecutionPolicy Bypass -Scope Process -Force
            Install-Module OSDCloud -Force -SkipPublisherCheck -AllowClobber -Scope AllUsers -ErrorAction Stop
        }
        Import-Module OSDCloud -Force
        $DriverFolder = "C:\OSDDrivers"
        $DriverPath = Get-OSDCloudDriverPack -Path $DriverFolder -Download -ErrorAction Stop
        Write-Host "Driver pack downloaded to $DriverPath"
        Add-WindowsDriver -Path "C:\" -Driver $DriverPath -Recurse -ForceUnsigned -ErrorAction Stop
        Write-Host "Driver injection completed."
    }
    catch {
        Write-Warning "OSDCloud driver pack not available or injection failed. Continuing with Microsoft generic drivers..."
    }
    # === End driver section ===

    # Disable ZDP offline
    reg load HKLM\TempHive C:\Windows\System32\config\SOFTWARE
    reg add "HKLM\TempHive\Microsoft\Windows\CurrentVersion\OOBE" /v DisableZDP /t REG_DWORD /d 1 /f
    reg unload HKLM\TempHive
    Write-Host "ZDP disabled."

    # Boot files
    if (-not (Test-Path "C:\Windows\Boot\EFI\bootmgfw.efi")) {
        Write-Warning "Boot files missing. Trying to proceed anyway..."
    }
    if (-not (Test-Path "S:\EFI\Microsoft\Boot")) {
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

    # --- Autopilot & OOBE configuration (unchanged) ---
    $TargetFolders = @(
        "C:\Windows\Panther\Unattend",
        "C:\Windows\Setup\Scripts",
        "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot",
        "C:\Autopilot"
    )
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
        RemovePreInstalledApps        = @(
            "Microsoft.ZuneMusic","Microsoft.XboxApp","Microsoft.XboxGameOverlay",
            "Microsoft.XboxGamingOverlay","Microsoft.XboxSpeechToTextOverlay",
            "Microsoft.YourPhone","Microsoft.Getstarted","Microsoft.3DBuilder"
        )
    }
    $OOBEJson | ConvertTo-Json -Depth 5 | Out-File "$AutopilotFolder\OOBE.json" -Encoding utf8

    try {
        $LegacyAutoPilotDir = "C:\Windows\Provisioning\Autopilot"
        if (-not (Test-Path $LegacyAutoPilotDir)) { New-Item -Path $LegacyAutoPilotDir -ItemType Directory -Force | Out-Null }
        Copy-Item "$AutopilotFolder\AutopilotConfigurationFile.json" "$LegacyAutoPilotDir\" -Force
        Copy-Item "$AutopilotFolder\OOBE.json" "$LegacyAutoPilotDir\" -Force
        Write-Host "Copied Autopilot JSONs to legacy path."
    } catch { Write-Warning "Could not copy Autopilot files to legacy path: $_" }

    # Unattend.xml
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
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>1</ProtectYourPC>
        <HideLocalAccountScreen>false</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>false</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>false</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>false</HideWirelessSetupInOOBE>
        <SkipUserOOBE>false</SkipUserOOBE>
        <SkipMachineOOBE>false</SkipMachineOOBE>
      </OOBE>
    </component>
  </settings>
</unattend>
"@
    Set-Content -Path "C:\Windows\Panther\Unattend\Unattend.xml" -Value $UnattendXml -Encoding UTF8

    # Autopilot upload script & SetupComplete
    $AutoPilotScriptPath = "C:\Autopilot\Get-WindowsAutoPilotInfo.ps1"
    Invoke-WebRequest -Uri "http://10.1.192.20/Get-WindowsAutoPilotInfo.ps1" -OutFile $AutoPilotScriptPath -UseBasicParsing -ErrorAction SilentlyContinue

    $SetupCompletePath = "C:\Windows\Setup\Scripts\SetupComplete.cmd"
    $SetupCompleteContent = @"
@echo off
set LOGFILE=C:\Autopilot-Diag.txt
set SCRIPT=C:\Autopilot\Get-WindowsAutoPilotInfo.ps1
set GROUPTAG=$GroupTag
echo ==== AUTOPILOT SETUP ==== >> %LOGFILE%
echo Timestamp: %DATE% %TIME% >> %LOGFILE%
timeout /t 10 > nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; ^
   Install-PackageProvider -Name NuGet -Force -Scope AllUsers -Confirm:$false; ^
   if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) { ^
       Register-PSRepository -Name PSGallery -SourceLocation 'https://www.powershellgallery.com/api/v2' -InstallationPolicy Trusted ^
   } else { ^
       Set-PSRepository -Name PSGallery -InstallationPolicy Trusted ^
   }" >> %LOGFILE% 2>&1
if exist "%SCRIPT%" (
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%SCRIPT%" -TenantId "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee" -AppId "faa1bc75-81c7-4750-ac62-1e5ea3ac48c5" -AppSecret "ouu8Q~h2IxPhfb3GP~o2pQOvn2HSmBkOm2D8hcB-" -GroupTag "%GROUPTAG%" -Online -Assign >> %LOGFILE% 2>&1
) else (
    echo ERROR: Script not found at %SCRIPT% >> %LOGFILE%
)
timeout /t 300 /nobreak > nul
echo SetupComplete.cmd finished at %DATE% %TIME% >> %LOGFILE%
"@
    Set-Content -Path $SetupCompletePath -Value $SetupCompleteContent -Encoding ASCII
    Write-Host "SetupComplete.cmd created successfully."

    try {
        New-Item -Path "HKLM:\SOFTWARE\OBG\Signals" -Force | Out-Null
        New-ItemProperty -Path "HKLM:\SOFTWARE\OBG\Signals" -Name "ReadyForWin32" -PropertyType DWord -Value 1 -Force | Out-Null
        Write-Host "Wrote HKLM\SOFTWARE\OBG\Signals\ReadyForWin32 = 1"
    } catch { Write-Warning "Failed to write ReadyForWin32 requirement flag: $_" }

    Write-Host "Deployment script completed. Rebooting in 5 seconds..."
    Start-Sleep -Seconds 5
    # Restart-Computer -Force
}
catch {
    Write-Error "Deployment failed: $_"
}
finally {
    try { Stop-Transcript } catch {}
}
