Write-Host -ForegroundColor DarkGray "========================================================================="
Write-Host -ForegroundColor Green "Start OOBE"
$ProgramDataOSDeploy = "$env:ProgramData\OSDeploy"
$JsonPath = "$ProgramDataOSDeploy\OOBE.json"
#=================================================
# Transcript
#=================================================
Write-Host -ForegroundColor DarkGray "========================================================================="
Write-Host -ForegroundColor Cyan "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) Start-Transcript"
$Transcript = "$((Get-Date).ToString('yyyy-MM-dd-HHmmss'))-OOBEDeploy.log"
Start-Transcript -Path (Join-Path "$env:SystemRoot\Temp" $Transcript) -ErrorAction Ignore
#=================================================
# Window Title
#=================================================
$Global:OOBEDeployWindowTitle = "Running Start-OOBEDeploy $env:SystemRoot\Temp\$Transcript"
$host.ui.RawUI.WindowTitle = $Global:OOBEDeployWindowTitle

#=================================================
# Import Json
#=================================================
if (Test-Path $JsonPath) {
    Write-Host -ForegroundColor DarkGray "Importing Configuration $JsonPath"
    $ImportOOBE = @()
    $ImportOOBE = Get-Content -Raw -Path $JsonPath | ConvertFrom-Json
    
    $ImportOOBE.PSObject.Properties | ForEach-Object {
        if ($_.Value -match 'IsPresent=True') {
            $_.Value = $true
        }
        if ($_.Value -match 'IsPresent=False') {
            $_.Value = $false
        }
        if ($null -eq $_.Value) {
            Continue
        }
        Set-Variable -Name $_.Name -Value $_.Value -Force
    }
}

#=================================================
# Installing Windows Updates
#=================================================
if ($UpdateDrivers -or $UpdateWindows){
    Write-Host -ForegroundColor Green "Installing PSWindowsUpdate"
    Install-Module PSWindowsUpdate -Force -Verbose
}

#=================================================
# Update Drivers
#=================================================
if ($UpdateDrivers){
    Write-Host -ForegroundColor Green "Driver Updates Enabled"
    Install-WindowsUpdate -Install -AcceptAll -UpdateType Driver -MicrosoftUpdate -ForceDownload -ForceInstall -IgnoreReboot -ErrorAction SilentlyContinue -Verbose | Out-File $env:SystemRoot\Temp\Drivers_Install_1_$(get-date -f dd-MM-yyyy).log -Force
}

#=================================================
# Update Windows
#=================================================
if ($UpdateWindows){
    Write-Host -ForegroundColor Green "Windows Updates Enabled"
    foreach ($item in $Updates){
        
        Install-WindowsUpdate -KBArticleID $item -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue -Verbose 
        
    }
}

#=================================================
# Remove AppX
#=================================================
if ($RemoveAppx){
    Write-Host -ForegroundColor Green "Remove AppX Enabled"
    foreach ($item in $RemoveAppx){
        Write-Host -ForegroundColor DarkGray "Removing $item"
        Remove-AppxOnline $item
    }
}

#=================================================
# Start AutoPilot
#=================================================
if ($AutopilotOOBE){
    Write-Host -ForegroundColor Green "AutoPilot Enabled"
    Write-Host "Running Autopilot Registration" -ForegroundColor Cyan
 
    # Downloading and installing get-windowsautopilotinfo script
    Write-Host "Downloading and installing get-windowsautopilotinfo script"
    Install-Script -Name Get-WindowsAutoPilotInfo -Force -Verbose
 
    # Autopilot registration
    Write-Host "Add Computer to Autopilot"
    Try {
        Get-WindowsAutoPilotInfo.ps1 -GroupTag $GroupTagID -Online
        Write-Host "Successfully ran autopilot script"}
 
    Catch {
        Write-Host "Error: Something went wrong. Unable to run autopilot script"
    Break }
}
