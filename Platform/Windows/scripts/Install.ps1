#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PackageDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Get-NativeArchitecture.ps1')
$source = (Resolve-Path $PackageDirectory).Path
$destination = Join-Path $env:ProgramFiles 'Holdfast'
$data = Join-Path $env:ProgramData 'Holdfast'
$binaries = @('HoldfastService.exe', 'HoldfastCtl.exe')
$hasUI = Test-Path (Join-Path $source 'HoldfastUI.exe') -PathType Leaf
if ($hasUI) {
    $binaries += 'HoldfastUI.exe'
    foreach ($asset in @('index.html', 'app.js', 'app.css')) {
        if (!(Test-Path (Join-Path $source "SharedUI\$asset") -PathType Leaf)) { throw "Missing shared interface asset: $asset" }
    }
}
foreach ($binary in $binaries) {
    if (!(Test-Path (Join-Path $source $binary) -PathType Leaf)) { throw "Missing $binary" }
    $bytes = [IO.File]::ReadAllBytes((Join-Path $source $binary))
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw "Invalid PE image: $binary" }
    $offset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($offset -lt 64 -or $offset + 6 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $offset) -ne 0x4550) { throw 'Invalid PE header' }
    $machine = [BitConverter]::ToUInt16($bytes, $offset + 4)
    $native = Get-HoldfastNativeArchitecture
    if (($native -ieq 'Arm64' -and $machine -ne 0xaa64) -or ($native -ieq 'X64' -and $machine -ne 0x8664) -or $native -notin @('Arm64','X64')) {
        throw "Package architecture does not match $native Windows; use its separate native package."
    }
}
if (Get-Service HoldfastGuard -ErrorAction SilentlyContinue) {
    throw 'Legacy kernel guard is installed. Remove it through its administrator recovery path before this user-mode test deployment.'
}
foreach ($directory in @($destination, $data)) {
    if ((Test-Path $directory) -and ((Get-Item $directory).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing reparse-point installation directory: $directory"
    }
    if (Test-Path $directory) {
        $owner = (Get-Acl $directory).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin @('S-1-5-18', 'S-1-5-32-544')) {
            throw "Refusing an existing directory not owned by SYSTEM or Administrators: $directory"
        }
    }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    & icacls.exe $directory /setowner '*S-1-5-18' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot set trusted directory ownership' }
    & icacls.exe $directory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot protect installation directory' }
}
$service = Get-Service HoldfastEnforcement -ErrorAction SilentlyContinue
if ($service -and $service.Status -ne 'Stopped') { $service.Stop(); $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20)) }
foreach ($binary in $binaries) {
    $target = Join-Path $destination $binary
    if ((Test-Path $target) -and ((Get-Item $target).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Refusing reparse-point binary' }
    Copy-Item (Join-Path $source $binary) $target -Force
}
if ($hasUI) {
    # Only package-owned assets are copied. Refuse redirected descendants too,
    # not just the top-level Program Files directory.
    foreach ($folder in @('SharedUI', 'licenses')) {
        $from = Join-Path $source $folder
        $to = Join-Path $destination $folder
        if (!(Test-Path $from)) { continue }
        if (Test-Path $to) {
            $items = @((Get-Item $to)) + @(Get-ChildItem $to -Recurse -Force)
            if ($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw "Refusing redirected asset directory: $to" }
        }
        Copy-Item $from $destination -Recurse -Force
    }
    $shortcutPath = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Holdfast.lnk'
    if ((Test-Path $shortcutPath) -and ((Get-Item $shortcutPath).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Refusing redirected Start menu shortcut' }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $destination 'HoldfastUI.exe'
    $shortcut.WorkingDirectory = $destination
    $shortcut.Save()
}
& (Join-Path $destination 'HoldfastService.exe') --recover
if ($LASTEXITCODE -ne 0) { throw 'Could not remove legacy Holdfast-owned WFP filters; installation not started' }
if (!$service) {
    New-Service -Name HoldfastEnforcement -BinaryPathName ('"' + (Join-Path $destination 'HoldfastService.exe') + '"') `
        -DisplayName 'Holdfast application network enforcement' -StartupType Automatic | Out-Null
}
Set-Service HoldfastEnforcement -StartupType Automatic
# Upgrades preserve saved intent. Only a first installation needs a disabled
# legacy policy; never clear an existing user's blocks merely by updating.
if (!(Test-Path (Join-Path $data 'policy.bin'))) {
    & (Join-Path $destination 'HoldfastCtl.exe') --clear
    if ($LASTEXITCODE -ne 0) { throw 'Cannot publish initial disabled policy' }
}
Start-Service HoldfastEnforcement
$acknowledged = $false
$deadline = [DateTime]::UtcNow.AddSeconds(10)
do {
    Start-Sleep -Milliseconds 250
    $snapshot = $null
    if (Test-Path (Join-Path $data 'status.json')) {
        try { $snapshot = & (Join-Path $destination 'HoldfastCtl.exe') --status | ConvertFrom-Json } catch { $snapshot = $null }
    }
    if ($snapshot -and $snapshot.phase -in @('idle', 'enforcing') -and
        $snapshot.updatedAtUnixSeconds -ge [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 3) {
        $acknowledged = $true
        break
    }
} while ([DateTime]::UtcNow -lt $deadline)
if (!$acknowledged) { throw 'Service did not acknowledge its policy; inspect status.json and enforcement.log.' }
Write-Host "Installed; service phase: $($snapshot.phase). Existing saved groups and enforcement intent were preserved."
if ($hasUI) { Write-Host 'Open Holdfast from the Start menu. The shared interface is connected to the local service.' }
Write-Host 'The service starts with Windows and honors saved intent. A new workspace starts disabled.'
Write-Host 'No kernel driver, website filtering, or iCloud sync was enabled.'
