# Start transcript logging
Start-Transcript -Path "X:\DeployScript.log" -Append

try {
    Write-Host "Starting Windows 11 deployment..." -ForegroundColor Cyan

    # Prompt for system type and set GroupTag
    Write-Host "Select system type:"
    Write-Host "1. Productivity Desktop"
    Write-Host "2. Productivity Laptop"
    Write-Host "3. Line Of Business Desktop"
    $selection = Read-Host "Enter choice (1-3)"
    switch ($selection) {
        '1' { $GroupTag = "ProductivityDesktop" }
        '2' { $GroupTag = "ProductivityLaptop" }
        '3' { $GroupTag = "LineOfBusinessDesktop" }
        default { throw "Invalid selection." }
    }
    Write-Host "Selected GroupTag: $GroupTag" -ForegroundColor Green

    # Select disk and wipe
    $disk = Get-Disk | Where-Object { $_.PartitionStyle -ne 'RAW' -or $_.NumberOfPartitions -gt 0 } | Sort-Object Number | Select-Object -First 1
    if (-not $disk) { throw "No disk found to install Windows." }

    Write-Host "Cleaning disk $($disk.Number)..." -ForegroundColor Yellow
    $disk | Set-Disk -IsReadOnly $false
    $disk | Clear-Disk -RemoveData -Confirm:$false
    $disk | Initialize-Disk -PartitionStyle GPT

    # Create partitions
    $efi = New-Partition -DiskNumber $disk.Number -Size 100MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}" -AssignDriveLetter
    $msr = New-Partition -DiskNumber $disk.Number -Size 16MB  -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}"
    $os  = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter

    # Format partitions
    Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel "System"
    Format-Volume -Partition $os  -FileSystem NTFS  -NewFileSystemLabel "Windows"

    # Apply Windows image from network source
    $wimPath = "http://10.1.192.20/install.wim"
    $osDrive = ($os | Get-Volume).DriveLetter + ":"
    Write-Host "Applying image from $wimPath to $osDrive..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $wimPath -OutFile "X:\install.wim"
    dism /Apply-Image /ImageFile:X:\install.wim /Index:1 /ApplyDir:$osDrive\

    # Set up boot files
    Write-Host "Setting up boot files..." -ForegroundColor Yellow
    bcdboot "$osDrive\Windows" /s $($efi | Get-Volume).DriveLetter`:\ /f UEFI

    # Create Autopilot folder
    $AutopilotFolder = "$osDrive\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
    if (-not (Test-Path $AutopilotFolder)) {
        New-Item -Path $AutopilotFolder -ItemType Directory -Force | Out-Null
    }

    # Generate AutopilotConfigurationFile.json
    $AutoPilotConfig = @{
        CloudAssignedTenantId         = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain     = "obgpharma.onmicrosoft.com"
        CloudAssignedDeviceName       = ""
        CloudAssignedAutopilotUpdate  = $true
        Version                       = 2049
        CloudAssignedGroupTag         = $GroupTag
        CloudAssignedLanguage         = "en-GB"
        CloudAssignedRegion           = "GB"
        ZtdCorrelationId              = ""
    }
    $AutoPilotConfig | ConvertTo-Json -Depth 10 | Out-File "$AutopilotFolder\AutopilotConfigurationFile.json" -Encoding UTF8

    # Create OOBE.json
    $OOBEConfig = @{
        Settings = @{
            Language         = "en-GB"
            SkipKeyboard     = $false
            AcceptEULA       = $true
            SkipWorkOrSchool = $false
        }
    }
    $OOBEConfig | ConvertTo-Json -Depth 10 | Out-File "$AutopilotFolder\OOBE.json" -Encoding UTF8

    # Download Autopilot script
    $APScriptPath = "$osDrive\Windows\Get-WindowsAutoPilotInfo.ps1"
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/microsoft/WindowsAutopilotInfo/master/Get-WindowsAutoPilotInfo.ps1" -OutFile $APScriptPath

    # Write SetupComplete.cmd
    $SetupCompletePath = "$osDrive\Windows\Setup\Scripts\SetupComplete.cmd"
    if (-not (Test-Path (Split-Path $SetupCompletePath))) {
        New-Item -Path (Split-Path $SetupCompletePath) -ItemType Directory -Force | Out-Null
    }

    @"
@echo off
powershell -ExecutionPolicy Bypass -NoProfile -Command "Try { & '$APScriptPath' -Online -TenantId 'c95ebf8f-ebb1-45ad-8ef4-463fa94051ee' -AppId 'faa1bc75-81c7-4750-ac62-1e5ea3ac48c5' -AppSecret 'ouu8Q~h2IxPhfb3GP~o2pQOvn2HSmBkOm2D8hcB-' -GroupTag '$GroupTag' -ErrorAction Stop } Catch { Write-Output 'Autopilot upload failed: ' + \$_.Exception.Message }"
"@ | Out-File $SetupCompletePath -Encoding ASCII

    Write-Host "Deployment complete. Rebooting..." -ForegroundColor Green
    Restart-Computer
}
catch {
    Write-Host "Deployment failed: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Stop-Transcript
}
