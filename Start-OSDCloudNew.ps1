# Start transcript logging
Start-Transcript -Path "X:\DeployScript.log" -Append

try {
    Write-Host "Starting Windows 11 deployment..." -ForegroundColor Cyan

    # Prompt for system type
    Write-Host "Select system type:"
    Write-Host "1. Productivity Desktop"
    Write-Host "2. Productivity Laptop"
    Write-Host "3. Line of Business Desktop"
    $selection = Read-Host "Enter selection (1, 2, or 3)"
    switch ($selection) {
        '1' { $GroupTag = 'ProductivityDesktop' }
        '2' { $GroupTag = 'ProductivityLaptop' }
        '3' { $GroupTag = 'LineOfBusinessDesktop' }
        default {
            Write-Host "Invalid selection. Defaulting to ProductivityDesktop"
            $GroupTag = 'ProductivityDesktop'
        }
    }

     # Always wipe Disk 0
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

    # Apply Windows image
    $imageUrl = "http://10.1.192.20/install.wim"
    $imagePath = "X:\install.wim"
    Invoke-WebRequest -Uri $imageUrl -OutFile $imagePath
    dism /Apply-Image /ImageFile:$imagePath /Index:1 /ApplyDir:"$osDriveLetter`:\" 

    # Set up boot files
    bcdboot "$osDriveLetter`:\Windows" /s S: /f UEFI

    # Create AutopilotConfigurationFile.json
    $AutoPilotJSON = @{
        CloudAssignedTenantId = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain = "obgpharma.onmicrosoft.com"
        CloudAssignedDeviceName = ""
        CloudAssignedProfileAssigned = $true
        CloudAssignedProfileName = "Default"
        CloudAssignedDomainJoinMethod = 0
        ZtdCorrelationId = ""
        CloudAssignedLanguage = "en-GB"
        CloudAssignedGroupTag = $GroupTag
        Version = 2049
    } | ConvertTo-Json -Depth 3
    $AutoPilotJSON | Out-File -Encoding ASCII -FilePath "$osDriveLetter`:\Windows\Provisioning\Autopilot\AutopilotConfigurationFile.json"

    # Create OOBE.json
    $OOBEjson = @{
        version = "1.0.0"
        "cloudAssignedOobeConfig" = @{
            "skipEula" = $true
            "userType" = "Standard"
            "language" = "en-GB"
            "region" = "GB"
            "privacy" = @{
                "diagnosticsOptIn" = "Required"
            }
        }
        apps = @()
        policies = @()
        drivers = @{
            update = "yes"
        }
    } | ConvertTo-Json -Depth 4
    $OOBEjson | Out-File -Encoding ASCII -FilePath "$osDriveLetter`:\Windows\OOBE\OOBE.json"

    # Write SetupComplete.cmd
    $SetupComplete = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"$LogPath = 'C:\\Windows\\Temp\\AutopilotLog.txt'; ^
 Start-Transcript -Path $LogPath -Append; ^
 Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted; ^
 if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) { ^
     Install-PackageProvider -Name NuGet -Force; ^
 }; ^
 Install-Script -Name Get-WindowsAutopilotInfo -Force; ^
 $tries = 0; ^
 while ($tries -lt 5) { ^
     try { ^
         Get-WindowsAutopilotInfo -Online `
         -TenantId 'c95ebf8f-ebb1-45ad-8ef4-463fa94051ee' `
         -AppId 'faa1bc75-81c7-4750-ac62-1e5ea3ac48c5' `
         -AppSecret 'ouu8Q~h2IxPhfb3GP~o2pQOvn2HSmBkOm2D8hcB-' `
         -GroupTag '$GroupTag' -Assign -ErrorAction Stop; ^
         break; ^
     } catch { ^
         $tries++; ^
         Start-Sleep -Seconds 30; ^
     } ^
 }; ^
 Stop-Transcript"
'@
    $SetupCompletePath = "$osDriveLetter`:\Windows\Setup\Scripts"
    New-Item -ItemType Directory -Path $SetupCompletePath -Force
    $SetupComplete | Set-Content -Path "$SetupCompletePath\SetupComplete.cmd" -Encoding ASCII

    Write-Host "Deployment script complete. System ready to reboot."
}
catch {
    Write-Error "An error occurred: $_"
}
finally {
    Stop-Transcript
}
