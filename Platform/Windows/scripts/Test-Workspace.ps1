#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Client, [string]$Url = 'https://example.com/')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Join-Path $env:ProgramFiles 'Holdfast'
$data = Join-Path $env:ProgramData 'Holdfast'
$control = Join-Path $env:SystemRoot 'System32\curl.exe'
$probe = Join-Path $root 'WorkspaceNetworkProbe.exe'
$report = [ordered]@{ startedAt = [DateTime]::UtcNow.ToString('o'); checks = @(); connections = @(); success = $false }
$reportPath = Join-Path $data ('workspace-test-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
function Call($Command, [switch]$Reject) {
    $request = @{ version = 1; id = [Guid]::NewGuid().ToString(); command = $Command } | ConvertTo-Json -Depth 25 -Compress
    $reply = $request | & $Client | ConvertFrom-Json
    if (!$reply) { throw 'No service reply' }
    if ($Reject) { if ($reply.ok) { throw 'Service accepted a forbidden mutation' }; return $reply }
    if (!$reply.ok) { throw $reply.error }
    return $reply.result
}
function Snapshot { return (Call @{ type = 'snapshot' }).snapshot }
function Record([string]$Name, [bool]$Passed, $Detail) {
    $script:report.checks += @{ name = $Name; passed = $Passed; detail = $Detail }
    if (!$Passed) { throw "Failed: $Name" }
}
function Connectivity([string]$Exe) {
    # Capture diagnostics without PowerShell's native stderr becoming a
    # terminating exception before we can record the actual curl exit code.
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $detail = & $Exe -4 --head --noproxy '*' --connect-timeout 2 --max-time 3 --silent --show-error --output NUL --write-out '%{remote_ip} %{http_code}' $Url 2>&1
    $code = $LASTEXITCODE; $ErrorActionPreference = $previous
    $script:report.connections += @{ executable = $Exe; exitCode = $code; detail = "$detail"; at = [DateTime]::UtcNow.ToString('o') }
    return $code -eq 0
}
function AwaitState([string]$State) {
    for ($i = 0; $i -lt 20; $i++) {
        $s = Snapshot
        if ($s.enforcement.state -eq $State) { return $s }
        Start-Sleep -Milliseconds 150
    }
    throw "Filters did not acknowledge $State"
}
if ((Get-Service HoldfastEnforcement).Status -ne 'Running') { throw 'Install/start the service first.' }
$initial = Snapshot
if ($initial.enforcementEnabled -or $initial.groups.Count -ne 0 -or $initial.bypasses.Count -ne 0) {
    throw 'This isolated integration test refuses to alter an existing workspace. Use a clean test VM.'
}
$legacy = & (Join-Path $root 'HoldfastCtl.exe') --status | ConvertFrom-Json
if ($legacy.phase -ne 'idle' -or $legacy.filters -ne 0) { throw 'Legacy enforcement must be idle.' }
$workspacePath = Join-Path $data 'workspace.json'
$backup = if (Test-Path $workspacePath) { [IO.File]::ReadAllBytes($workspacePath) } else { $null }
Copy-Item $control $probe -Force
$watchdog = $null
try {
    Record 'initial-connectivity' ((Connectivity $control) -and (Connectivity $probe)) 'Control and disposable probe connect'
    # This independent process releases only Holdfast's dynamic filters even if
    # this client crashes. The selected app is a disposable copy, never a browser.
    $code = @'
Start-Sleep -Seconds 25
sc.exe stop HoldfastEnforcement
Start-Sleep -Seconds 3
$s = Get-CimInstance Win32_Service -Filter "Name='HoldfastEnforcement'"
if ($s.ProcessId -gt 0) {
    $p = Get-Process -Id $s.ProcessId
    if ($p.Path -ieq '__ROOT__\HoldfastService.exe') { $p.Kill() }
}
& '__ROOT__\HoldfastService.exe' --recover
'@
    $code = $code.Replace('__ROOT__', $root.Replace("'", "''"))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $watchdog = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -WindowStyle Hidden -PassThru
    $id = [Guid]::NewGuid().ToString()
    $group = @{ id = $id; name = 'Disposable workspace integration probe'; enabled = $true; domains = @(); applications = @($probe)
        schedule = @{ mode = 'allow'; slots = @() }; changePolicy = @{ kind = 'passage'; words = 20; delayDays = 0 }
        temporaryPolicy = @{ allowed = $true; words = 20; maximumMinutes = 60; resetDays = 1 } }
    $saved = Call @{ type = 'saveGroup'; revision = $initial.revision; group = $group }
    Record 'durable-group-save' ($saved.snapshot.groups.Count -eq 1) 'Saved through authenticated service pipe'
    $stale = Call @{ type = 'deleteGroup'; revision = $initial.revision; groupID = $id } -Reject
    Record 'stale-write-rejected' (!$stale.ok) $stale.error
    Call @{ type = 'setEnforcement'; revision = $saved.snapshot.revision; enabled = $true } | Out-Null
    $active = AwaitState 'active'
    Record 'native-filter-acknowledgement' ($active.groups[0].status -eq 'blocking') $active.enforcement
    Record 'selected-app-blocked' (!(Connectivity $probe)) 'Disposable curl is denied'
    Record 'other-traffic-preserved' (Connectivity $control) 'Ordinary system curl still connects'
    $challenge = (Call @{ type = 'requestTemporaryAccess'; revision = $active.revision; groupID = $id; minutes = 10; reason = 'conscious'; reflection = 'Read one intentional article' }).challenge
    Call @{ type = 'submitChallenge'; challengeID = $challenge.id; typed = 'incorrect passage' } -Reject | Out-Null
    $grant = Call @{ type = 'submitChallenge'; challengeID = $challenge.id; typed = $challenge.passage }
    $paused = AwaitState 'disabled'
    Record 'temporary-access-connected' ($paused.groups[0].status -eq 'suspended' -and (Connectivity $probe)) 'Native exception removes selected app filters'
    Record 'bypass-history-connected' ($grant.snapshot.bypasses.Count -eq 1 -and $grant.snapshot.bypasses[0].reason -eq 'conscious') $grant.snapshot.bypasses
    Call @{ type = 'submitChallenge'; challengeID = $challenge.id; typed = $challenge.passage } -Reject | Out-Null
    Record 'consumed-passage-rejected' $true 'A passage cannot grant twice'
    $disable = (Call @{ type = 'setEnforcement'; revision = $paused.revision; enabled = $false }).challenge
    Call @{ type = 'submitChallenge'; challengeID = $disable.id; typed = $disable.passage } | Out-Null
    $disabled = AwaitState 'disabled'
    Record 'global-disable-connected' (!$disabled.enforcementEnabled) '80-word native challenge accepted'
    $unlock = (Call @{ type = 'requestGroupUnlock'; revision = $disabled.revision; groupID = $id }).challenge
    $unlocked = Call @{ type = 'submitChallenge'; challengeID = $unlock.id; typed = $unlock.passage }
    Record 'group-unlock-connected' $unlocked.snapshot.groups[0].canEdit 'Specific group unlocked'
    $deleted = Call @{ type = 'deleteGroup'; revision = $unlocked.snapshot.revision; groupID = $id }
    Record 'group-delete-connected' ($deleted.snapshot.groups.Count -eq 0) 'Saved group removed only after its unlock'
    $report.success = $true
} catch { $report['error'] = $_.Exception.Message }
finally {
    try {
        $svc = Get-Service HoldfastEnforcement
        if ($svc.Status -ne 'Stopped') { $svc.Stop(); $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(3)) }
        & (Join-Path $root 'HoldfastService.exe') --recover
        if ($LASTEXITCODE -ne 0) { throw 'Filter recovery failed' }
        # Only a verified empty test workspace is restored. Keep generated test
        # evidence separately rather than leaving enabled test groups behind.
        if (Test-Path $workspacePath) { Copy-Item $workspacePath ($reportPath + '.workspace.json') }
        if ($null -ne $backup) { [IO.File]::WriteAllBytes($workspacePath, $backup) }
        elseif (Test-Path $workspacePath) { Move-Item $workspacePath ($reportPath + '.restored-empty.json') }
        Record 'final-connectivity' ((Connectivity $control) -and (Connectivity $probe)) 'Service stopped; dynamic filters released'
        if ($watchdog -and !$watchdog.HasExited) { Stop-Process -Id $watchdog.Id }
    } catch { $report.success = $false; $report['cleanupError'] = $_.Exception.Message }
    $report['finishedAt'] = [DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 15 | Set-Content -Encoding UTF8 $reportPath
    Write-Host "Detailed workspace report: $reportPath"
}
if (!$report.success) { throw ($report | ConvertTo-Json -Depth 15) }
Write-Host 'Connected workspace integration passed. Test workspace restored; service stopped.'
