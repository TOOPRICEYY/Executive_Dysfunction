#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PackageDirectory, [switch]$RequireWorkspace)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path $PackageDirectory).Path
$exe = Join-Path $root 'HoldfastUI.exe'
if (!(Test-Path $exe -PathType Leaf)) { throw 'Build the shared UI host first.' }
$user = (Get-CimInstance Win32_ComputerSystem).UserName
if (!$user) { throw 'Sign into the VM desktop first. A SYSTEM/session-0 process is not a valid GUI test.' }
$before = (Get-Service HoldfastEnforcement -ErrorAction SilentlyContinue).Status
$report = Join-Path $root 'ui-smoke.json'
# Only the disposable test report is writable by the interactive test account;
# this does not grant it write access to executable/UI assets or policy storage.
[IO.File]::WriteAllText($report, '{}')
& icacls.exe $report /grant ($user + ':M') | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not prepare test report permissions.' }
$name = 'HoldfastSharedUI-Smoke-' + [Guid]::NewGuid().ToString('N')
$action = New-ScheduledTaskAction -Execute $exe -Argument '--smoke-test'
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
try {
    Register-ScheduledTask -TaskName $name -Action $action -Principal $principal | Out-Null
    Start-ScheduledTask -TaskName $name
    $result = $null
    for ($attempt = 0; $attempt -lt 35; $attempt++) {
        Start-Sleep -Seconds 1
        try { $result = Get-Content $report -Raw | ConvertFrom-Json } catch { $result = $null }
        if ($result -and $null -ne $result.ok) { break }
    }
    if (!$result -or !$result.ok -or !$result.sharedUIRendered -or !$result.nativeSnapshotAcknowledged) {
        throw ('Interactive shared UI check failed: ' + (Get-Content $report -Raw))
    }
    if ($RequireWorkspace -and !$result.workspaceConnected) { throw 'The screen rendered but did not connect to the trusted workspace service.' }
    if ((Get-Service HoldfastEnforcement -ErrorAction SilentlyContinue).Status -ne $before) {
        throw 'The enforcement service state changed during this read-only test; inspect before continuing.'
    }
    Get-Content $report
    Write-Host "Read-only UI check passed. Enforcement service remains $before."
} finally {
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}
