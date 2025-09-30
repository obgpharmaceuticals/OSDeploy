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

    # === Disk preparation (unchanged) ===
    $Disk = Get-Disk | Where-Object {
        $_.IsSystem -eq $false -and $_.OperationalStatus -eq "Online" -and
        $_.BusType -in @("NVMe","SATA","SCSI","ATA")
    } | Sort-Object -Property Size -Descending | Select-Object -First 1
    if (-not $Disk) { throw "No suitable disk found." }
    $DiskNumber = $Disk.Number
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -Confirm:$false
    Set-Disk -Number $DiskNumber -IsOffline $false
    Set-Disk -Number $DiskNumber -IsReadOnly $false
    $ESP = New-Partition -DiskNumber $DiskNumber -Size 512MB -GptType "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
    Format-Volume -Partition $ESP -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
    $ESP | Set-Partition -NewDriveLetter S
    New-Partition -DiskNumber $DiskNumber -Size 128MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}" | Out-Null
    $OSPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize
    Format-Volume -Partition $OSPartition -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $OSPartition.PartitionNumber -NewDriveLetter C

    # === Map deployment share, apply WIM, create boot files (unchanged) ===
    # ... [your existing network mapping and DISM code here] ...

    # === Autopilot JSONs (unchanged) ===
    $AutopilotFolder = "C:\ProgramData\Microsoft\Windows\Provisioning\Autopilot"
    New-Item -Path $AutopilotFolder -ItemType Directory -Force | Out-Null
    $AutopilotConfig = @{
        CloudAssignedTenantId    = "c95ebf8f-ebb1-45ad-8ef4-463fa94051ee"
        CloudAssignedTenantDomain = "obgpharma.onmicrosoft.com"
        GroupTag                 = $GroupTag
    }
    $AutopilotConfig | ConvertTo-Json -Depth 3 | Out-File "$AutopilotFolder\AutopilotConfigurationFile.json" -Encoding utf8
    # ... [OOBE.json creation unchanged] ...

    # Download Autopilot script
    $AutoPilotScriptPath = "C:\Autopilot\Get-WindowsAutoPilotInfo.ps1"
    $AutoPilotScriptURL  = "\\10.1.192.20\ReadOnlyShare\Get-WindowsAutoPilotInfo.ps1"
    Invoke-WebRequest -Uri $AutoPilotScriptURL -OutFile $AutoPilotScriptPath -UseBasicParsing -ErrorAction Stop

    # === NEW SetupComplete.cmd ===
    $PrimaryUserUPN = "fooUser@obg.co.uk"   # <-- change to the desired user
    $SetupCompletePath = "C:\Windows\Setup\Scripts\SetupComplete.cmd"
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

REM === Step 1: Upload hardware hash ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -TenantId %TENANT% -AppId %APPID% -AppSecret %APPSECRET% -GroupTag "%GROUPTAG%" -Online -Assign >> %LOGFILE% 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: upload failed >> %LOGFILE%
    exit /b 1
)

REM === Step 2: Poll and assign primary user ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$Headers = @{ Authorization = ('Bearer ' + (Invoke-RestMethod -Method Post -Uri 'https://login.microsoftonline.com/%TENANT%/oauth2/v2.0/token' -Body @{client_id='%APPID%';scope='https://graph.microsoft.com/.default';client_secret='%APPSECRET%';grant_type='client_credentials'}).access_token) }; ^
   for(\$i=0;\$i -lt 20;\$i++){ ^
      \$d=Invoke-RestMethod -Headers \$Headers -Uri 'https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities' | Select-Object -ExpandProperty value | Where-Object { \$_.groupTag -eq '%GROUPTAG%' }; ^
      if(\$d){ Invoke-RestMethod -Headers \$Headers -Method Post -Uri ('https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities/'+\$d.id+'/assignUserToDevice') -Body (@{userPrincipalName='%ASSIGNUSER%'} | ConvertTo-Json) -ContentType 'application/json'; break } ^
      Start-Sleep -Seconds 15 ^
   }" >> %LOGFILE% 2>&1

echo Completed Autopilot upload + user assignment >> %LOGFILE%
"@
    Set-Content -Path $SetupCompletePath -Value $SetupCompleteContent -Encoding ASCII
    Write-Host "SetupComplete.cmd created with user auto-assignment."

    Restart-Computer -Force

} catch {
    Write-Error "Deployment failed: $_"
} finally {
    try { Stop-Transcript } catch {}
}
