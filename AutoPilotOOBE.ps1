Set-ExecutionPolicy -ExecutionPolicy 'ByPass' -Scope 'Process' -Force -ErrorAction 'Stop'
$ProgramDataOSDeploy = "$env:ProgramData\OSDeploy"
#=================================================
# Transcript
#=================================================
Write-Host -ForegroundColor DarkGray "========================================================================="
Write-Host -ForegroundColor Cyan "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) Start-Transcript"
$Transcript = "$((Get-Date).ToString('yyyy-MM-dd-HHmmss'))-AutoPilotOOBE.log"
Start-Transcript -Path (Join-Path "$env:SystemRoot\Temp" $Transcript) -ErrorAction Ignore

Set-ExecutionPolicy -ExecutionPolicy 'ByPass' -Scope 'Process' -Force -ErrorAction 'Stop'
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
