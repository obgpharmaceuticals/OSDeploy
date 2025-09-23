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

    # Find the first disk that is online, fixed, and has the largest size
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

    # EFI partition size 512MB
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

    Write-Host "Disabling ZDP offline in the image..."
    reg load HKLM\TempHive C:\Windows\System32\config\SOFTWARE
    reg add "HKLM\TempHive\Microsoft\Windows\CurrentVersion\OOBE" /v DisableZDP /t REG_DWORD /d 1 /f
    reg unload HKLM\TempHive
    Write-Host "ZDP has been disabled offline successfully."

    # Boot files
    if (-not (Test-Path "S:\EFI\Microsoft\Boot")) {
        New-Item -Path "S:\EFI\Microsoft\Boot" -ItemType Directory -Force | Out-Null
    }
    Write-Host "Running bcdboot to create UEFI boot entry..."
    $bcdResult = bcdboot C:\Windows /s S: /f UEFI
    Write-Host $bcdResult
    Copy-Item -Path "S:\EFI\Microsoft\Boot\bootmgfw.efi" -Destination "S:\EFI\Boot\bootx64.efi" -Force
    Write-Host "Boot files created successfully."

    # Create required folders
    $TargetFolders = @(
        "C:\Windows\Panther\Unattend",
        "C:\Windows\Setup\Scripts",
        "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot",
        "C:\Autopilot"
    )
    foreach ($Folder in $TargetFolders) {
        if (-not (Test-Path $Folder)) {
            New-Item -Path $Folder -ItemType Directory -Force | Out-Null
        }
    }

    # Generate Autopilot JSON
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
            "Microsoft.ZuneMusic", "Microsoft.XboxApp", "Microsoft.XboxGameOverlay",
            "Microsoft.XboxGamingOverlay", "Microsoft.XboxSpeechToTextOverlay",
            "Microsoft.YourPhone", "Microsoft.Getstarted", "Microsoft.3DBuilder"
        )
    }
    $OOBEJson | ConvertTo-Json -Depth 5 | Out-File "$AutopilotFolder\OOBE.json" -Encoding utf8

    # Copy to legacy path
    try {
        $LegacyAutoPilotDir = "C:\Windows\Provisioning\Autopilot"
        if (-not (Test-Path $LegacyAutoPilotDir)) { New-Item -Path $LegacyAutoPilotDir -ItemType Directory -Force | Out-Null }
        Copy-Item -Path "$AutopilotFolder\AutopilotConfigurationFile.json" -Destination "$LegacyAutoPilotDir\AutopilotConfigurationFile.json" -Force
        Copy-Item -Path "$AutopilotFolder\OOBE.json" -Destination "$LegacyAutoPilotDir\OOBE.json" -Force
        Write-Host "Copied Autopilot JSONs to legacy path for early pickup."
    } catch {
        Write-Warning "Could not copy Autopilot files to legacy path: $_"
    }

    # Unattend.xml
    $UnattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-GB</InputLocale>
      <SystemLocale>en-GB</SystemLocale>
      <UILanguage>en-GB</UILanguage>
      <UserLocale>en-GB</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
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
    $UnattendPath = "C:\Windows\Panther\Unattend\Unattend.xml"
    Set-Content -Path $UnattendPath -Value $UnattendXml -Encoding UTF8

    # Download Get-WindowsAutoPilotInfo.ps1
    $AutoPilotScriptPath = "C:\Autopilot\Get-WindowsAutoPilotInfo.ps1"
    $AutoPilotScriptURL = "http://10.1.192.20/Get-WindowsAutoPilotInfo.ps1"
    try {
        Invoke-WebRequest -Uri $AutoPilotScriptURL -OutFile $AutoPilotScriptPath -UseBasicParsing -ErrorAction Stop
        Write-Host "Downloaded Get-WindowsAutoPilotInfo.ps1 successfully."
    } catch {
        Write-Warning "Failed to download Autopilot script: $_"
    }

    # ----------------------------
    # SetupComplete.cmd (fixed)
    # ----------------------------
$SetupCompleteContent = @"
@echo off
REM ============================
REM SetupComplete.cmd for Autopilot registration and driver injection
REM ============================
set LOGFILE=C:\Autopilot\Autopilot-Diag.txt
set SCRIPT=C:\Autopilot\Get-WindowsAutoPilotInfo.ps1
set GROUPTAG=$GroupTag

echo ==== AUTOPILOT SETUP ==== >> %LOGFILE%
echo Timestamp: %DATE% %TIME% >> %LOGFILE%

powershell.exe -NoProfile -Command "Start-Sleep -Seconds 10"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Try { 
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -Force -Scope AllUsers -Confirm:\$false
    if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) { 
        Register-PSRepository -Name PSGallery -SourceLocation 'https://www.powershellgallery.com/api/v2' -InstallationPolicy Trusted 
    } else { 
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted 
    } 
} Catch { Add-Content -Path '%LOGFILE%' -Value ('PSGallery registration failed: ' + \$_.Exception.Message) }"

if exist "%SCRIPT%" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -TenantId "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee" -AppId "faa1bc75-81c7-4750-ac62-1e5ea3ac48c5" -AppSecret "ouu8Q~h2IxPhfb3GP~o2pQOvn2HSmBkOm2D8hcB-" -GroupTag "%GROUPTAG%" -Online -Assign >> %LOGFILE% 2>&1
) else (
    echo ERROR: Script not found at %SCRIPT% >> %LOGFILE%
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Try { 
    Add-Content -Path '%LOGFILE%' -Value ('===== DRIVER INJECTION VIA WINDOWS UPDATE ===== Timestamp: ' + (Get-Date))
    Import-Module 'C:\Program Files\WindowsPowerShell\Modules\OSD\25.6.15.1\OSD.psm1' -ErrorAction Stop
    Import-Module 'C:\Program Files\WindowsPowerShell\Modules\OSDCloud\25.6.15.1\OSDCloud.psm1' -ErrorAction Stop
    $Model = (Get-CimInstance Win32_ComputerSystem).Model
    Add-Content -Path '%LOGFILE%' -Value ('Detected Model: ' + $Model)
    Get-WindowsUpdateDriver -Path 'C:\' -Force -Verbose *> '%LOGFILE%'
    Add-Content -Path '%LOGFILE%' -Value 'Driver injection complete.'
} Catch { Add-Content -Path '%LOGFILE%' -Value ('Driver injection failed: ' + \$_.Exception.Message) }"

powershell.exe -NoProfile -Command "Start-Sleep -Seconds 300"

echo SetupComplete.cmd finished at %DATE% %TIME% >> %LOGFILE%
"@
Set-Content -Path "C:\Windows\Setup\Scripts\SetupComplete.cmd" -Value $SetupCompleteContent -Encoding ASCII
Write-Host "SetupComplete.cmd created successfully."

    # Write ReadyForWin32 flag
    try {
        New-Item -Path "HKLM:\SOFTWARE\OBG" -ErrorAction SilentlyContinue | Out-Null
        New-Item -Path "HKLM:\SOFTWARE\OBG\Signals" -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path "HKLM:\SOFTWARE\OBG\Signals" -Name "ReadyForWin32" -PropertyType DWord -Value 1 -Force | Out-Null
        Write-Host "Wrote HKLM\SOFTWARE\OBG\Signals\ReadyForWin32 = 1 (use as Intune requirement rule)."
    } catch {
        Write-Warning "Failed to write ReadyForWin32 requirement flag: $_"
    }

    Write-Host "Deployment script completed. Rebooting in 5 seconds..."
    Start-Sleep -Seconds 5
    # Restart-Computer -Force

} catch {
    Write-Error "Deployment failed: $_"
} finally {
    try { Stop-Transcript } catch {}
}
