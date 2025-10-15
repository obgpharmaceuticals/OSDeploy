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

    # === Disk preparation ===
    $Disk = Get-Disk | Where-Object { $_.IsSystem -eq $false -and $_.OperationalStatus -eq "Online" -and $_.BusType -in @("NVMe","SATA","SCSI","ATA") } | Sort-Object -Property Size -Descending | Select-Object -First 1
    if (-not $Disk) { throw "No suitable disk found." }
    $DiskNumber = $Disk.Number

    Write-Host "Clearing and partitioning disk $DiskNumber ($($Disk.FriendlyName))"
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -Confirm:$false
    Set-Disk -Number $DiskNumber -IsOffline $false
    Set-Disk -Number $DiskNumber -IsReadOnly $false

    # EFI 512MB
    $ESP = New-Partition -DiskNumber $DiskNumber -Size 512MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
    Format-Volume -Partition $ESP -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    $ESP | Set-Partition -NewDriveLetter S

    # MSR 128MB
    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null

    # OS partition rest of disk
    $OSPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize
    Format-Volume -Partition $OSPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $OSPartition.PartitionNumber -NewDriveLetter C

    # === Map deployment share and apply WIM ===
    $ClientIP = (Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true -and $_.IPAddress -ne $null } | ForEach-Object { $_.IPAddress } | Where-Object { $_ -notlike "169.*" -and $_ -ne "127.0.0.1" } | Select-Object -First 1)
    if (-not $ClientIP) { throw "Could not determine client IP address." }

    $DeploymentServers = @{
        "10.1.192" = "10.1.192.20"
        "10.3.192" = "10.3.192.20"
        "10.5.192" = "10.5.192.20"
    }
    $Subnet = ($ClientIP -split "\.")[0..2] -join "."
    if ($DeploymentServers.ContainsKey($Subnet)) { $ServerIP = $DeploymentServers[$Subnet] } else { throw "No deployment server configured for subnet $Subnet" }

    $NetworkPath = "\\$ServerIP\ReadOnlyShare"
    $DriveLetter = "M:"
    net use $DriveLetter /delete /yes > $null 2>&1
    net use $DriveLetter $NetworkPath /persistent:no | Out-Null

    $WimPath = "$DriveLetter\install.wim"
    if (-not (Test-Path $WimPath)) { throw "WIM file not found at $WimPath" }

    Write-Host "Applying Windows image..."
    Start-Process -FilePath dism.exe -ArgumentList "/Apply-Image","/ImageFile:$WimPath","/Index:6","/ApplyDir:C:\" -Wait -PassThru

    # === Boot files ===
    if (-not (Test-Path "S:\EFI\Microsoft\Boot")) { New-Item -Path "S:\EFI\Microsoft\Boot" -ItemType Directory -Force | Out-Null }
    bcdboot C:\Windows /s S: /f UEFI
    if (-not (Test-Path "S:\EFI\Boot")) { New-Item -Path "S:\EFI\Boot" -ItemType Directory -Force | Out-Null }
    Copy-Item -Path "S:\EFI\Microsoft\Boot\bootmgfw.efi" -Destination "S:\EFI\Boot\bootx64.efi" -Force

    # === Ensure required folders exist ===
    $Folders = @( "C:\Windows\Panther\Unattend", "C:\Windows\Setup\Scripts", "C:\Autopilot", "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot" )
    foreach ($Folder in $Folders) {
        if (-not (Test-Path $Folder)) { New-Item -Path $Folder -ItemType Directory -Force | Out-Null }
    }

    # === Copy Autopilot script from network share ===
    $AutoPilotScriptPath = "C:\Autopilot\Get-WindowsAutoPilotInfo.ps1"
    $AutoPilotScriptURL = "$DriveLetter\Get-WindowsAutoPilotInfo.ps1"
    Copy-Item -Path $AutoPilotScriptURL -Destination $AutoPilotScriptPath -Force

    # === Autopilot JSONs ===
    $AutopilotFolder = "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
    $AutopilotConfig = @{
        CloudAssignedTenantId = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain = "obgpharma.onmicrosoft.com"
        GroupTag = $GroupTag
    }
    $AutopilotConfig | ConvertTo-Json -Depth 3 | Out-File "$AutopilotFolder\AutopilotConfigurationFile.json" -Encoding utf8

    $OOBEJson = @{
        CloudAssignedTenantId = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain = "obgpharma.onmicrosoft.com"
        DeviceType = $GroupTag
        EnableUserStatusTracking = $true
        EnableUserConfirmation = $true
        EnableProvisioningDiagnostics = $true
        DeviceLicensingType = "WindowsEnterprise"
        Language = "en-GB"
        SkipZDP = $true
        SkipUserStatusPage = $false
        SkipAccountSetup = $false
        SkipOOBE = $false
        RemovePreInstalledApps = @(
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
    $OOBEJson | ConvertTo-Json -Depth 5 | Out-File "$AutopilotFolder\OOBE.json" -Encoding utf8

    # === Unattend.xml ===
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
    Set-Content -Path "C:\Windows\Panther\Unattend\Unattend.xml" -Value $UnattendXml -Encoding UTF8

    # === SetupComplete.cmd ===
    $PrimaryUserUPN = "fooUser@obg.co.uk" # <-- replace with desired user
    $SetupCompleteContent = @"
@echo off
set LOGFILE=C:\Autopilot-AssignUser.txt
set SCRIPT=C:\Autopilot\Get-WindowsAutoPilotInfo.ps1
set GROUPTAG=$GroupTag
set TENANT=c95ebf8f-ebb1-45ad-8ef4-463fa94051ee
set APPID=faa1bc75-81c7-4750-ac62-1e5ea3ac48c5
set APPSECRET=ouu8Q~h2IxPhfb3GP~o2pQOvn2HSmBkOm2D8hcB-
set ASSIGNUSER=$PrimaryUserUPN

echo ==== AUTOPILOT UPLOAD + USER ASSIGN ==== >> %LOGFILE%
echo %DATE% %TIME% >> %LOGFILE%
timeout /t 30 /nobreak > nul
timeout /t 10 /nobreak > nul

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -TenantId %TENANT% -AppId %APPID% -AppSecret %APPSECRET% -GroupTag "%GROUPTAG%" -Online -Assign >> %LOGFILE% 2>&1

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
"$Headers = @{ Authorization = ('Bearer ' + (Invoke-RestMethod -Method Post -Uri 'https://login.microsoftonline.com/%TENANT%/oauth2/v2.0/token' -Body @{client_id='%APPID%';scope='https://graph.microsoft.com/.default';client_secret='%APPSECRET%';grant_type='client_credentials'}).access_token) }; ^
for(\$i=0;\$i -lt 20;\$i++){ ^
\$d=Invoke-RestMethod -Headers \$Headers -Uri 'https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities' | Select-Object -ExpandProperty value | Where-Object { \$_.groupTag -eq '%GROUPTAG%' }; ^
if(\$d){ Invoke-RestMethod -Headers \$Headers -Method Post -Uri ('https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities/'+\$d.id+'/assignUserToDevice') -Body (@{userPrincipalName='%ASSIGNUSER%'} | ConvertTo-Json) -ContentType 'application/json'; break } ^
Start-Sleep -Seconds 15 ^
}" >> %LOGFILE% 2>&1

echo Completed Autopilot upload + user assignment >> %LOGFILE%
"@
    Set-Content -Path "C:\Windows\Setup\Scripts\SetupComplete.cmd" -Value $SetupCompleteContent -Encoding ASCII
    Write-Host "SetupComplete.cmd created successfully."

    # --- Requirement flag for Win32 app ---
    New-Item -Path "HKLM:\SOFTWARE\OBG" -ErrorAction SilentlyContinue | Out-Null
    New-Item -Path "HKLM:\SOFTWARE\OBG\Signals" -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\OBG\Signals" -Name "ReadyForWin32" -PropertyType DWord -Value 1 -Force | Out-Null

    # --- Install OSDCloud and save drivers (KEEP HERE) ---
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Install-Module OSDCloud -Force -AllowClobber -SkipPublisherCheck
    Import-Module OSDCloud

    # THIS IS IMPORTANT: Save-MyDriverPack STAYS HERE
    Save-MyDriverPack -expand

    Write-Host "Drivers and features updated. Rebooting in 5 seconds..."
    Start-Sleep -Seconds 5
    # Restart-Computer -Force

} catch {
    Write-Error "Deployment failed: $_"
} finally {
    try { Stop-Transcript } catch {}
}
