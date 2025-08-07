# Start transcript logging
Start-Transcript -Path "X:\DeployScript.log" -Append

try {
    Write-Host "Starting Windows 11 deployment..." -ForegroundColor Cyan

    # Prompt for system type
    Write-Host "Select system type:"
    Write-Host "1. Productivity Desktop"
    Write-Host "2. Productivity Laptop"
    Write-Host "3. Line of Business Desktop"
    $choice = Read-Host "Enter your choice (1-3)"

    switch ($choice) {
        '1' { $GroupTag = "ProductivityDesktop" }
        '2' { $GroupTag = "ProductivityLaptop" }
        '3' { $GroupTag = "LineOfBusinessDesktop" }
        default {
            Write-Host "Invalid choice. Defaulting to ProductivityDesktop"
            $GroupTag = "ProductivityDesktop"
        }
    }

    # Wipe and partition Disk 0
    Get-Disk 0 | Set-Disk -IsReadOnly $false -IsOffline $false
    Get-Disk 0 | Clear-Disk -RemoveData -Confirm:$false
    Initialize-Disk -Number 0 -PartitionStyle GPT

    $ESP = New-Partition -DiskNumber 0 -Size 100MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}" -AssignDriveLetter
    Format-Volume -Partition $ESP -FileSystem FAT32 -NewFileSystemLabel "System"

    $OS = New-Partition -DiskNumber 0 -UseMaximumSize -GptType "{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}" -AssignDriveLetter
    Format-Volume -Partition $OS -FileSystem NTFS -NewFileSystemLabel "Windows"

    $OSDrive = ($OS | Get-Volume).DriveLetter

    # Download and apply image
    $WimUrl = "http://10.1.192.20/install.wim"
    $WimPath = "X:\install.wim"
    Invoke-WebRequest -Uri $WimUrl -OutFile $WimPath

    dism /Apply-Image /ImageFile:$WimPath /Index:1 /ApplyDir:"$OSDrive`:\" /Compact:Recovery

    # Set up boot
    bcdboot "$OSDrive`:\Windows" /s "$($ESP.DriveLetter):" /f UEFI

    # Create AutopilotConfigurationFile.json
    $AutopilotConfig = @{
        CloudAssignedTenantId    = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain = "obgpharma.onmicrosoft.com"
        CloudAssignedDeviceName  = ""
        CloudAssignedProfileAssigned = $true
        CloudAssignedProfileName = $GroupTag
        CloudAssignedGroupTag    = $GroupTag
        Version = 2049
    }

    $AutopilotConfig | ConvertTo-Json -Depth 5 | Out-File -Encoding ASCII "$OSDrive`:\AutopilotConfigurationFile.json"

    # Create OOBE.json
    $OOBEConfig = @{
        "oobe" = @{
            "language" = "en-GB"
            "region" = "GB"
            "keyboard" = "en-GB"
            "privacy" = @{
                "diagnostics" = "full"
                "tailoredExperiences" = "enabled"
                "advertisingId" = "enabled"
            }
            "userAccountType" = "azureAD"
            "hideEULA" = $true
            "hidePrivacySettings" = $true
            "hideOemRegistration" = $true
            "hideLocalAccount" = $true
            "hideDomainAccount" = $true
            "acceptOEMTerms" = $true
            "skipExpressSettings" = $true
        }
        "updates" = @{
            "enable" = $true
            "installDrivers" = $true
        }
        "apps" = @{
            "remove" = @("Microsoft.ZuneMusic", "Microsoft.XboxApp", "Microsoft.Microsoft3DViewer")
        }
    }

    $OOBEConfig | ConvertTo-Json -Depth 10 | Out-File -Encoding ASCII "$OSDrive`:\OOBE.json"

    # Download Get-WindowsAutopilotInfo
    Invoke-WebRequest -Uri "https://aka.ms/get-windowsautopilotinfo" -OutFile "$OSDrive`:\Get-WindowsAutoPilotInfo.ps1"

    # Create SetupComplete.cmd
    $SetupCmd = @'
@echo off
set RETRIES=5
set COUNT=0

:retry
powershell -ExecutionPolicy Bypass -Command "try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -Force -Scope AllUsers -ErrorAction Stop
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
    Install-Module -Name WindowsAutopilotIntune -Force -Scope AllUsers
    Install-Script -Name Get-WindowsAutoPilotInfo -Force -Scope AllUsers
    .\Get-WindowsAutoPilotInfo.ps1 -Online -GroupTag '$GroupTag' -TenantId 'c95ebf8f-ebb1-45ad-8ef4-463fa94051ee' -AppId 'faa1bc75-81c7-4750-ac62-1e5ea3ac48c5' -AppSecret 'ouu8Q~h2IxPhfb3GP~o2pQOvn2HSmBkOm2D8hcB-'
} catch {
    Write-Host 'Autopilot upload failed: ' + $_.Exception.Message
    exit 1
}"
if %ERRORLEVEL% NEQ 0 (
    set /A COUNT+=1
    if %COUNT% LSS %RETRIES% (
        timeout /t 15
        goto retry
    )
)
exit /b 0
'@

    $SetupCompletePath = "$OSDrive`:\Windows\Setup\Scripts"
    New-Item -Path $SetupCompletePath -ItemType Directory -Force | Out-Null
    $SetupCmd | Out-File -FilePath "$SetupCompletePath\SetupComplete.cmd" -Encoding ASCII

    # Done
    Write-Host "Deployment complete. Rebooting..."
    Restart-Computer

} catch {
    Write-Error "Deployment failed: $_"
} finally {
    Stop-Transcript
}
