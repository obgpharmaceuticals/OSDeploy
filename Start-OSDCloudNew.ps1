Start-Transcript -Path X:\DeployLog.txt

# Step 1: Prompt for System Type
Write-Host "Select System Type:" -ForegroundColor Yellow
Write-Host "1. Productivity Desktop"
Write-Host "2. Productivity Laptop"
Write-Host "3. Line of Business Desktop"
$choice = Read-Host "Enter a number (1-3)"

switch ($choice) {
    '1' { $GroupTag = "ProductivityDesktop" }
    '2' { $GroupTag = "ProductivityLaptop" }
    '3' { $GroupTag = "LineOfBusinessDesktop" }
    default { Write-Error "Invalid selection"; exit 1 }
}

# Step 2: Partition and Format Disk
$disk = Get-Disk | Where-Object IsSystem -eq $false | Sort-Object Number | Select-Object -First 1
$disk | Clear-Disk -RemoveData -Confirm:$false
Initialize-Disk -Number $disk.Number -PartitionStyle GPT
New-Partition -DiskNumber $disk.Number -Size 100MB -AssignDriveLetter | Format-Volume -FileSystem FAT32 -NewFileSystemLabel "System"
New-Partition -DiskNumber $disk.Number -Size 16MB -GptType "{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}"
$osPartition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
$osPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel "Windows"

# Step 3: Apply Windows Image
$WimURL = "http://10.1.192.20/install.wim"
$WimPath = "X:\install.wim"
curl.exe -o $WimPath $WimURL
dism.exe /Apply-Image /ImageFile:$WimPath /Index:1 /ApplyDir:$($osPartition.DriveLetter):\

# Step 4: Setup Boot
bcdboot "$($osPartition.DriveLetter):\Windows" /s S: /f UEFI

# Step 5: Autopilot Config Files
$AutopilotJsonPath = "$($osPartition.DriveLetter):\Windows\Provisioning\Autopilot"
New-Item -Path $AutopilotJsonPath -ItemType Directory -Force

@"
{
    "CloudAssignedTenantId": "YOUR-TENANT-GUID",
    "CloudAssignedDeviceName": "%SERIAL%",
    "CloudAssignedDomainJoinMethod": "AzureAD",
    "CloudAssignedAadServerData": "",
    "CloudAssignedProfile": "",
    "ZtdGroupTag": "$GroupTag",
    "CloudAssignedOobeConfig": 131
}
"@ | Out-File -Encoding UTF8 -FilePath "$AutopilotJsonPath\AutopilotConfigurationFile.json"

@"
{
    "version": "1.0",
    "modernDeploymentWithAutopilot": true,
    "oobe": {
        "hideEULA": true,
        "userType": "Standard",
        "language": "en-US",
        "privacySettings": "Full"
    },
    "update": {
        "installDrivers": true,
        "installUpdates": true
    },
    "removeAppx": true
}
"@ | Out-File -Encoding UTF8 -FilePath "$AutopilotJsonPath\OOBE.json"

# Step 6: SetupComplete to upload hardware hash
$SetupScript = @'
powershell -ExecutionPolicy Bypass -Command "Install-Script -Name Get-WindowsAutopilotInfo -Force -Scope LocalMachine; Get-WindowsAutopilotInfo -Online -GroupTag '$GroupTag'"
exit 0
'@
$SetupPath = "$($osPartition.DriveLetter):\Windows\Setup\Scripts"
New-Item -ItemType Directory -Path $SetupPath -Force
Set-Content -Path "$SetupPath\SetupComplete.cmd" -Value $SetupScript

# Step 7: Reboot
Stop-Transcript
wpeutil reboot
