#Requires -RunAsAdministrator
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$destination = Join-Path $env:ProgramFiles 'Holdfast'
$service = Get-Service HoldfastEnforcement -ErrorAction SilentlyContinue
if ($service -and $service.Status -ne 'Stopped') {
    $service.Stop()
    $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
}
$helper = Join-Path $destination 'HoldfastService.exe'
if (Test-Path $helper) {
    & $helper --recover
    if ($LASTEXITCODE -ne 0) { throw 'Owned filter cleanup failed; files retained for recovery.' }
}
if ($service) {
    $service.Dispose() # Do not hold the registration open after sc.exe delete.
    & sc.exe delete HoldfastEnforcement
    if ($LASTEXITCODE -ne 0) { throw 'Service registration removal failed' }
}
Write-Host 'Service removed and owned network filters cleared. Binaries, policy and diagnostics retained for recovery.'
