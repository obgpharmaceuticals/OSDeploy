# Start transcript logging
Start-Transcript -Path "X:\DeployScript.log" -Append

try {
    Write-Host "Starting Windows 11 deployment..." -ForegroundColor Cyan

    # Prompt for system type
    Write-Host "Select system type:"
    Write-Host "1. Productivity Desktop"
    Write-Host "2. Productivity Laptop"
    Write-Host "3. Line of Business Desktop"
    $choice = Read-Host "Enter choice (1-3)"

    switch ($choice) {
        '1' { $GroupTag = "ProductivityDesktop" }
        '2' { $GroupTag = "ProductivityLaptop" }
        '3' { $GroupTag = "LineOfBusinessDesktop" }
        default { throw "Invalid selection. Deployment aborted." }
    }

    Write-Host "Selected GroupTag: $GroupTag"

    # Select disk 0, clean, and partition
    Write-Host "Partitioning disk..." -ForegroundColor Yellow
    $diskpartScript = @"
select disk 0
clean
convert gpt
create partition efi size=100
format quick fs=fat32 label="System"
assign letter=S
create partition msr size=16
create partition primary
shrink minimum=10240
format quick fs=ntfs label="Windows"
assign letter=W
create partition primary
format quick fs=ntfs label="Data"
assign letter=D
exit
"@
    $diskpartScript | diskpart

    # Apply Windows image
    Write-Host "Applying Windows image..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri "http://10.1.192.20/install.wim" -OutFile "X:\install.wim"
    dism /Apply-Image /ImageFile:"X:\install.wim" /Index:1 /ApplyDir:W:\

    # Configure boot files
    Write-Host "Configuring boot files..." -ForegroundColor Yellow
    bcdboot W:\Windows /s S: /f UEFI

    # Create AutopilotConfigurationFile.json
    $autopilotConfig = @{
        CloudAssignedTenantId = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain = "obgpharma.onmicrosoft.com"
        CloudAssignedDeviceName = ""
        CloudAssignedAadServerData = ""
        CloudAssignedOobeConfig = 27
        ZtdCorrelationId = [guid]::NewGuid().Guid
        CloudAssignedLanguage = "en-GB"
        CloudAssignedRegion = "GB"
        Version = 2049
        GroupTag = $GroupTag
    }
    $autopilotPath = "W:\Windows\Provisioning\Autopilot\AutopilotConfigurationFile.json"
    New-Item -Path (Split-Path $autopilotPath) -ItemType Directory -Force | Out-Null
    $autopilotConfig | ConvertTo-Json -Depth 3 | Set-Content -Path $autopilotPath -Encoding UTF8

    # Create OOBE.json
    $oobeConfig = @{
        oobe = @{
            setupAutopilot = $true
            removeAppx = $true
            updateDrivers = $true
            updateWindows = $true
        }
    }
    $oobePath = "W:\Windows\OOBE\OOBE.json"
    New-Item -Path (Split-Path $oobePath) -ItemType Directory -Force | Out-Null
    $oobeConfig | ConvertTo-Json -Depth 3 | Set-Content -Path $oobePath -Encoding UTF8

    # SetupComplete.cmd with updated PSGallery logic + logging to C:\Autopilot
    $setupCompletePath = "W:\Windows\Setup\Scripts\SetupComplete.cmd"
    $setupCompleteContent = @"
@echo off
set LOGDIR=C:\Autopilot
set LOGFILE=%LOGDIR%\Autopilot-Setup.log

if not exist %LOGDIR% mkdir %LOGDIR%
echo ==== AUTOPILOT SETUP ==== >> %LOGFILE%
echo Timestamp: %DATE% %TIME% >> %LOGFILE%
echo Using TLS 1.2 for secure downloads >> %LOGFILE%

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; ^
    Install-PackageProvider -Name NuGet -Force -Scope AllUsers -Confirm:\$false; ^
    if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) { ^
        Register-PSRepository -Name PSGallery -SourceLocation 'https://www.powershellgallery.com/api/v2' -InstallationPolicy Trusted ^
    } else { ^
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted ^
    }; ^
    Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/MicrosoftDocs/windows-itpro-docs/main/windows/deployment/windows-autopilot/scripts/Get-WindowsAutoPilotInfo.ps1' -OutFile 'C:\Autopilot\Get-WindowsAutoPilotInfo.ps1'; ^
    & 'C:\Autopilot\Get-WindowsAutoPilotInfo.ps1' -Online -TenantId 'c95ebf8f-ebb1-45ad-8ef4-463fa94051ee' -AppId 'faa1bc75-81c7-4750-ac62-1e5ea3ac48c5' -AppSecret 'ouu8Q~h2IxPhfb3GP~o2pQOvn2HSmBkOm2D8hcB-' -GroupTag '$GroupTag' -ErrorAction Stop" ^
    >> %LOGFILE% 2>&1
"@
    New-Item -Path (Split-Path $setupCompletePath) -ItemType Directory -Force | Out-Null
    Set-Content -Path $setupCompletePath -Value $setupCompleteContent -Encoding ASCII

    Write-Host "Deployment complete. Rebooting..." -ForegroundColor Green
    Restart-Computer
}
catch {
    Write-Error "Deployment failed: $_"
}
finally {
    Stop-Transcript
}
