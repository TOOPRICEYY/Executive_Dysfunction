#Requires -RunAsAdministrator
[CmdletBinding()]
param([string]$Url = 'https://www.microsoft.com/', [switch]$CrashTest, [switch]$MalformedPolicyTest)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($CrashTest -and $MalformedPolicyTest) { throw 'Choose either crash recovery or malformed-policy expiry, not both.' }
$root = Join-Path $env:ProgramFiles 'Holdfast'
$data = Join-Path $env:ProgramData 'Holdfast'
$ctl = Join-Path $root 'HoldfastCtl.exe'
$serviceExe = Join-Path $root 'HoldfastService.exe'
$control = Join-Path $env:SystemRoot 'System32\curl.exe'
$probe = Join-Path $root 'NetworkProbe.exe'
$reportPath = Join-Path $data ('test-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
$report = [ordered]@{ startedAt = [DateTime]::UtcNow.ToString('o'); url = $Url; crashTest = [bool]$CrashTest; malformedPolicyTest = [bool]$MalformedPolicyTest; checks = @(); success = $false }
function Probe([string]$Executable, [string]$Family) {
    & $Executable $Family --noproxy '*' --connect-timeout 2 --max-time 3 --silent --output NUL $Url
    return $LASTEXITCODE
}
function Record([string]$Name, [bool]$Pass, $Detail) {
    $script:report.checks += [ordered]@{ name = $Name; passed = $Pass; detail = $Detail; at = [DateTime]::UtcNow.ToString('o') }
    if (!$Pass) { throw "Failed: $Name ($Detail)" }
}
function Stop-TestService([string]$ExpectedExecutable) {
    $service = Get-Service HoldfastEnforcement -ErrorAction SilentlyContinue
    if (!$service -or $service.Status -eq 'Stopped') { return }
    # Stop-Service can wait indefinitely, defeating the independent watchdog.
    # Request a graceful stop, then bound the wait and terminate only our test
    # service image if it is still alive.
    try {
        $service.Stop()
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(3))
        return
    } catch {
        $instance = Get-CimInstance Win32_Service -Filter "Name='HoldfastEnforcement'"
        if ($instance -and $instance.ProcessId -gt 0) {
            $process = Get-Process -Id $instance.ProcessId -ErrorAction SilentlyContinue
            if ($process) {
                if ($process.Path -ine $ExpectedExecutable) { throw 'Refusing to terminate an unexpected service executable.' }
                $process.Kill()
                if (!$process.WaitForExit(3000)) { throw 'Test service did not exit within the recovery deadline.' }
            }
        }
    }
}
if (!(Test-Path $ctl) -or !(Test-Path $control)) { throw 'Install Holdfast and ensure Windows curl is available first.' }
$existing = & $ctl --status | ConvertFrom-Json
if ($existing.phase -ne 'idle') { throw 'Test refuses to replace an active/error policy. Explicitly clear it first.' }
Copy-Item $control $probe -Force
$watchdog = $null
try {
    Record 'baseline-probe-ipv4' ((Probe $probe '-4') -eq 0) 'Copied curl can reach the test URL'
    Record 'baseline-control-ipv4' ((Probe $control '-4') -eq 0) 'System curl is unaffected'
    $ipv6Available = (Probe $control '-6') -eq 0
    $report['ipv6Available'] = $ipv6Available
    # A distinct elevated process survives this script or its terminal dying.
    # It stops the service and removes ONLY Holdfast-owned filters at 25 seconds.
    # Normal policy expiry should occur at 15 seconds, before this fallback.
    $escapedRoot = $root.Replace("'", "''")
    $stopFunction = ${function:Stop-TestService}.ToString()
    $watchdogCode = "function Stop-TestService { $stopFunction }; Start-Sleep -Seconds 25; & '$escapedRoot\HoldfastCtl.exe' --clear; Stop-TestService '$escapedRoot\HoldfastService.exe'; & '$escapedRoot\HoldfastService.exe' --recover"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($watchdogCode))
    $watchdog = Start-Process powershell.exe -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru
    $timer = [Diagnostics.Stopwatch]::StartNew()
    & $ctl --apply --seconds 15 --app $probe
    Record 'policy-publication' ($LASTEXITCODE -eq 0) '15-second lease; one disposable executable only'
    $status = $null
    do {
        Start-Sleep -Milliseconds 250
        $status = & $ctl --status | ConvertFrom-Json
    } while ($status.phase -ne 'enforcing' -and $timer.Elapsed.TotalSeconds -lt 4)
    Record 'service-acknowledgement' ($status.phase -eq 'enforcing' -and $status.applications -eq 1 -and $status.filters -eq 2) $status
    Record 'selected-app-blocked-ipv4' ((Probe $probe '-4') -ne 0) 'IPv4 ALE block observed'
    Record 'ordinary-connectivity-preserved' ((Probe $control '-4') -eq 0) 'System curl remains connected while probe is blocked'
    if ($ipv6Available) {
        Record 'selected-app-blocked-ipv6' ((Probe $probe '-6') -ne 0) 'IPv6 ALE block observed'
    }
    if ($MalformedPolicyTest) {
        # Only our disposable test policy is active. Invalid input must not
        # extend its deadline or prematurely clear its still-valid lease.
        $policyPath = Join-Path $data 'policy.bin'
        $bytes = [IO.File]::ReadAllBytes($policyPath)
        $bytes[0] = 255 # Unsupported protocol version.
        [IO.File]::WriteAllBytes($policyPath, $bytes)
        Start-Sleep -Milliseconds 1300
        $status = & $ctl --status | ConvertFrom-Json
        Record 'malformed-update-retains-valid-lease' ($status.phase -eq 'enforcing' -and $status.filters -eq 2) $status
        Record 'malformed-update-still-blocks-selected-app' ((Probe $probe '-4') -ne 0) 'Previous accepted snapshot remains active until its original deadline'
    }
    if ($CrashTest) {
        $pidValue = (Get-CimInstance Win32_Service -Filter "Name='HoldfastEnforcement'").ProcessId
        Record 'crash-test-process-present' ($pidValue -gt 0) $pidValue
        Stop-Process -Id $pidValue -Force
        Start-Sleep -Milliseconds 700
        Record 'crash-releases-dynamic-filters' ((Probe $probe '-4') -eq 0) 'No persistent network lock after service death'
    } else {
        while ($timer.Elapsed.TotalSeconds -lt 17) { Start-Sleep -Milliseconds 200 }
        $status = & $ctl --status | ConvertFrom-Json
        Record 'natural-lease-expiry' ($status.phase -eq 'idle' -and $status.filters -eq 0) $status
        Record 'connectivity-restored' ((Probe $probe '-4') -eq 0) 'Before the independent watchdog deadline'
    }
    $report.success = $true
} catch {
    $report['error'] = $_.Exception.Message
} finally {
    $cleanupSucceeded = $false
    # Publishing an empty policy and releasing live filters are independent
    # recovery paths. A file/ACL failure must not skip stop/recover.
    try {
        & $ctl --clear | Out-Null
        $report['clearExitCode'] = $LASTEXITCODE
    } catch {
        $report['clearError'] = $_.Exception.Message
        $report['clearExitCode'] = -1
    }
    try {
        Stop-TestService $serviceExe
        & $serviceExe --recover
        $report['cleanupExitCode'] = $LASTEXITCODE
        $cleanupSucceeded = $LASTEXITCODE -eq 0 -and $report.clearExitCode -eq 0
    } catch {
        $report['cleanupError'] = $_.Exception.Message
    }
    if (!$cleanupSucceeded) { $report.success = $false }
    # Do not terminate the watchdog on failed cleanup; it is still a recovery path.
    if ($cleanupSucceeded -and $watchdog -and !$watchdog.HasExited) { Stop-Process -Id $watchdog.Id -ErrorAction SilentlyContinue }
    $report['finishedAt'] = [DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $reportPath
    Write-Host "Detailed report: $reportPath"
    Write-Host 'Test leaves enforcement stopped. No global firewall, DNS, proxy, or certificate settings changed.'
}
if (!$report.success) { throw "Connectivity test failed; inspect $reportPath" }
