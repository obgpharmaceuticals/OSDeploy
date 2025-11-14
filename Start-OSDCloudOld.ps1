# Deploy-Win11-OptionA.ps1
# Run under WinPE (with PowerShell support present). This script:
#  1) runs Autopilot upload from WinPE (pre-image-apply)
#  2) applies WIM
#  3) installs boot files
#  4) writes minimal SetupComplete.cmd that schedules FirstBootTasks.ps1
#  5) places FirstBootTasks.ps1 into the applied image
# NOTE: adjust paths (drive letter mapping) to match your environment.

# Start transcript to X: (WinPE RAM mount)
Start-Transcript -Path "X:\DeployScript.log" -Append

try {
    Write-Host "=== Windows 11 deployment (Option A) starting ===" -ForegroundColor Cyan

    # --- select system type (same UI as before) ---
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

    # --- Disk prep (unchanged) ---
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
    # Detect client IP
    $ClientIP = (Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true -and $_.IPAddress -ne $null } | ForEach-Object { $_.IPAddress } | Where-Object { $_ -notlike "169.*" -and $_ -ne "127.0.0.1" } | Select-Object -First 1)
    if (-not $ClientIP) { throw "Could not determine client IP address." }
    $Subnet = ($ClientIP -split "\.")[0..2] -join "."

    $DeploymentServers = @{
        "10.1.192" = "10.1.192.20"
        "10.3.192" = "10.3.192.20"
        "10.5.192" = "10.5.192.20"
    }
    if ($DeploymentServers.ContainsKey($Subnet)) { $ServerIP = $DeploymentServers[$Subnet] } else { throw "No deployment server configured for subnet $Subnet" }

    $NetworkPath = "\\$ServerIP\ReadOnlyShare"
    $DriveLetter = "M:"
    # remove any stale mapping
    net use $DriveLetter /delete /yes > $null 2>&1
    net use $DriveLetter $NetworkPath /persistent:no | Out-Null

    # --- AUTOPILOT UPLOAD in WinPE (before WIM apply) ---
    Write-Host "Attempting Autopilot upload from WinPE..."
    # copy autopilot script from share (you said you keep it on share)
    $AutoPilotScriptURL = "$DriveLetter\Get-WindowsAutoPilotInfo.ps1"
    $AutoPilotScriptPath = "X:\Get-WindowsAutoPilotInfo.ps1"   # run from WinPE RAM if you prefer
    if (Test-Path $AutoPilotScriptURL) {
        Copy-Item -Path $AutoPilotScriptURL -Destination $AutoPilotScriptPath -Force
    } else {
        Write-Warning "Autopilot script not found on share at $AutoPilotScriptURL; skipping Autopilot upload."
        $AutoPilotScriptPath = $null
    }

    # Get AppSecret securely if available on share
    $AppSecretFile = "$DriveLetter\autopilot\appsecret.txt"   # recommended location on deployment share, readable only by deploy admins
    if (Test-Path $AppSecretFile) {
        $AppSecret = Get-Content -Path $AppSecretFile -ErrorAction Stop | Select-Object -First 1
        Write-Host "AppSecret loaded from deployment share."
    } else {
        # Fallback: prompt (safe fallback in WinPE)
        Write-Warning "AppSecret file not found at $AppSecretFile. Prompting for AppSecret (avoid embedding in scripts)."
        $AppSecret = Read-Host -AsSecureString "Enter AppSecret (input hidden)"
        # convert to plain for script usage (only if necessary)
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AppSecret)
        $AppSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }

    if ($AutoPilotScriptPath) {
        # ensure network connectivity quick test
        $netOk = $true
        try {
            $netOk = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction Stop
        } catch {
            $netOk = $false
        }
        if (-not $netOk) { Write-Warning "WinPE network test failed; Autopilot upload may fail." }

        # run the autopilot script in WinPE (this must be a WinPE with PowerShell + TLS support)
        $apArgs = @(
            '-NoProfile','-ExecutionPolicy','Bypass',
            '-File', $AutoPilotScriptPath,
            '-Online',
            '-Assign',
            '-GroupTag', $GroupTag,
            '-TenantId', 'c95ebf8f-ebb1-45ad-8ef4-463fa94051ee',
            '-AppId', 'faa1bc75-81c7-4750-ac62-1e5ea3ac48c5',
            '-AppSecret', $AppSecret
        )
        Write-Host "Running Get-WindowsAutoPilotInfo.ps1..."
        $proc = Start-Process -FilePath powershell.exe -ArgumentList $apArgs -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            Write-Warning "Autopilot upload finished with exit code $($proc.ExitCode). Check script output on server/share."
        } else {
            Write-Host "Autopilot upload completed successfully from WinPE."
        }
    }

    # --- Apply WIM to C: ---
    $WimPath = "$DriveLetter\installnew.wim"
    if (-not (Test-Path $WimPath)) { throw "WIM file not found at $WimPath" }
    Write-Host "Applying Windows image from $WimPath (Index 5) to C:\ ..."
    Start-Process -FilePath dism.exe -ArgumentList "/Apply-Image","/ImageFile:$WimPath","/Index:5","/ApplyDir:C:\" -Wait -PassThru

    # --- Boot files ---
    if (-not (Test-Path "S:\EFI\Microsoft\Boot")) { New-Item -Path "S:\EFI\Microsoft\Boot" -ItemType Directory -Force | Out-Null }
    bcdboot C:\Windows /s S: /f UEFI
    if (-not (Test-Path "S:\EFI\Boot")) { New-Item -Path "S:\EFI\Boot" -ItemType Directory -Force | Out-Null }
    Copy-Item -Path "S:\EFI\Microsoft\Boot\bootmgfw.efi" -Destination "S:\EFI\Boot\bootx64.efi" -Force

    # --- Ensure required folders exist in applied image ---
    $Folders = @( "C:\Windows\Panther\Unattend", "C:\Windows\Setup\Scripts", "C:\Autopilot", "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot", "C:\Drivers", "C:\Setup" )
    foreach ($Folder in $Folders) {
        if (-not (Test-Path $Folder)) { New-Item -Path $Folder -ItemType Directory -Force | Out-Null }
    }

    # --- Copy autopilot script into applied image for audit/logging (optional) ---
    if ($AutoPilotScriptPath) {
        Copy-Item -Path $AutoPilotScriptPath -Destination "C:\Autopilot\Get-WindowsAutoPilotInfo.ps1" -Force
    }

    # --- Write minimal SetupComplete.cmd into applied image (this schedules FirstBootTasks) ---
    $SetupCompleteContent = @"
@echo off
REM Minimal SetupComplete to avoid OOBE hang
if not exist C:\SetupLogs mkdir C:\SetupLogs
set LOGFILE=C:\SetupLogs\SetupComplete.log
echo ==== SetupComplete start ==== >> %LOGFILE%
echo %DATE% %TIME% >> %LOGFILE%

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
"Try {
    \$Action = New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File \"C:\Setup\FirstBootTasks.ps1\"'
    \$Trigger = New-ScheduledTaskTrigger -AtStartup
    \$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 00:30:00
    Register-ScheduledTask -TaskName 'OBG_FirstBootTasks' -Action \$Action -Trigger \$Trigger -Settings \$Settings -RunLevel Highest -Force
    Write-Output 'Scheduled FirstBootTasks' >> '%LOGFILE%'
} Catch {
    Write-Output 'Failed to schedule FirstBootTasks: ' + \$_.Exception.Message >> '%LOGFILE%'
}"
echo ==== SetupComplete end ==== >> %LOGFILE%
exit /B 0
"@

    $SetupCompletePath = "C:\Windows\Setup\Scripts\SetupComplete.cmd"
    $SetupCompleteContent | Set-Content -Path $SetupCompletePath -Encoding ASCII -Force
    Write-Host "SetupComplete.cmd written to $SetupCompletePath"

    # --- Write FirstBootTasks.ps1 into image (C:\Setup\FirstBootTasks.ps1) ---
    $FirstBootPs = @'
# FirstBootTasks.ps1 - run as SYSTEM via scheduled task
$log = "C:\SetupLogs\FirstBootTasks.log"
Start-Transcript -Path $log -Append

Try {
    Write-Output "FirstBootTasks started: $(Get-Date)"

    # 1) Expand driver packs if the helper exists
    if (Get-Command -Name Expand-StagedDriverPack -ErrorAction SilentlyContinue) {
        try {
            Expand-StagedDriverPack -ErrorAction Stop
            Write-Output "Driver pack expanded."
        } catch {
            Write-Warning "Expand-StagedDriverPack failed: $_"
        }
    } else {
        Write-Output "Expand-StagedDriverPack not found; skipping."
    }

    # 2) Add drivers to driverstore - robust loop
    $driverFolder = 'C:\Drivers\sccm'
    if (Test-Path $driverFolder) {
        Get-ChildItem -Path $driverFolder -Filter '*.inf' -Recurse | ForEach-Object {
            try {
                Write-Output "Adding driver $($_.FullName)"
                pnputil.exe /add-driver "$($_.FullName)" /install /subdirs | Out-Null
            } catch {
                Write-Warning "pnputil failed for $($_.FullName): $_"
            }
        }
    } else {
        Write-Output "Driver folder not found: $driverFolder"
    }

    # 3) Install PSWindowsUpdate and apply updates (best-effort)
    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Force -Confirm:$false -ErrorAction Stop
        }
        Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
        Import-Module PSWindowsUpdate -ErrorAction Stop

        Get-WindowsUpdate -AcceptAll -Install -IgnoreReboot -Verbose -ErrorAction Stop
        Write-Output "Windows updates requested."
    } catch {
        Write-Warning "PSWindowsUpdate failed (will retry via Windows Update or WSUS): $_"
    }

    # 4) Remove scheduled task after completion
    Unregister-ScheduledTask -TaskName 'OBG_FirstBootTasks' -Confirm:$false -ErrorAction SilentlyContinue

    Write-Output "FirstBootTasks completed at $(Get-Date)."
} Catch {
    Write-Warning "FirstBootTasks unexpected error: $_"
} Finally {
    Stop-Transcript
    # optionally restart if you want:
    # Restart-Computer -Force
}
'@

    $firstBootPath = "C:\Setup\FirstBootTasks.ps1"
    $FirstBootPs | Set-Content -Path $firstBootPath -Encoding UTF8 -Force
    Write-Host "FirstBootTasks.ps1 written to $firstBootPath"

    # --- Requirement flag for Win32 app (unchanged) ---
    New-Item -Path "HKLM:\SOFTWARE\OBG" -ErrorAction SilentlyContinue | Out-Null
    New-Item -Path "HKLM:\SOFTWARE\OBG\Signals" -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\OBG\Signals" -Name "ReadyForWin32" -PropertyType DWord -Value 1 -Force | Out-Null

    # --- Save-MyDriverPack remains (you asked to keep it) ---
    # This will run in WinPE; it may stage drivers into C:\Drivers (depending on how Save-MyDriverPack works in your environment)
    if (Get-Command -Name Save-MyDriverPack -ErrorAction SilentlyContinue) {
        try {
            Write-Host "Running Save-MyDriverPack -expand (WinPE)"
            Save-MyDriverPack -expand
        } catch {
            Write-Warning "Save-MyDriverPack failed in WinPE: $_"
        }
    } else {
        Write-Host "Save-MyDriverPack not present in this WinPE environment; skipping."
    }

    Write-Host "Drivers and files staged. Rebooting into applied OS in 5 seconds..."
    Start-Sleep -Seconds 5
    # Restart-Computer -Force

} catch {
    Write-Error "Deployment failed: $_"
} finally {
    try { Stop-Transcript } catch {}
}
