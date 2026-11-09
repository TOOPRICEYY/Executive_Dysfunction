#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ctl = Join-Path $env:ProgramFiles 'Holdfast\HoldfastCtl.exe'
$policy = Join-Path $env:ProgramData 'Holdfast\policy.bin'
$status = & $ctl --status | ConvertFrom-Json
if ($status.phase -ne 'idle') { throw 'Publication test requires the service to be running and idle.' }
$previous = [BitConverter]::ToUInt64([IO.File]::ReadAllBytes($policy), 8)
for ($i = 0; $i -lt 32; $i++) {
    # Replaces an existing file while the service concurrently reads it.
    # This reproduced the MSVC reader-handle sharing failure in the VM.
    & $ctl --clear | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Atomic publication failed at iteration $i" }
    $bytes = [IO.File]::ReadAllBytes($policy)
    $revision = [BitConverter]::ToUInt64($bytes, 8)
    if ($bytes.Length -ne 266272 -or [BitConverter]::ToUInt32($bytes, 4) -ne 0 -or $revision -ne $previous + 1) {
        throw "Invalid published snapshot at iteration $i"
    }
    $previous = $revision
}
$timer = [Diagnostics.Stopwatch]::StartNew()
do {
    Start-Sleep -Milliseconds 200
    $status = & $ctl --status | ConvertFrom-Json
} while ($status.revision -ne $previous -and $timer.Elapsed.TotalSeconds -lt 4)
if ($status.phase -ne 'idle' -or $status.filters -ne 0 -or $status.revision -ne $previous) {
    throw 'Service did not acknowledge the final empty snapshot.'
}
Write-Output 'PASS: 32 consecutive atomic policy replacements, monotonic revisions, service acknowledgement, zero filters.'
