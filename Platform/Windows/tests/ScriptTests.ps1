$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'
$files = @(Get-ChildItem $scriptDirectory -Filter '*.ps1')
foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "PowerShell syntax errors in $($file.Name): $parseErrors" }
}
. (Join-Path $scriptDirectory 'Get-NativeArchitecture.ps1')
if ((ConvertTo-HoldfastNativeArchitecture 'ARM64') -cne 'ARM64') { throw 'ARM64 detection failed' }
if ((ConvertTo-HoldfastNativeArchitecture 'arm64') -cne 'ARM64') { throw 'Case-insensitive ARM64 detection failed' }
if ((ConvertTo-HoldfastNativeArchitecture 'AMD64') -cne 'x64') { throw 'x64 detection failed' }
foreach ($invalid in @('', 'x86', 'unknown')) {
    $rejected = $false
    try { ConvertTo-HoldfastNativeArchitecture $invalid | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw "Unsupported architecture accepted: $invalid" }
}
$native = Get-HoldfastNativeArchitecture
Write-Output "PASS: $($files.Count) PowerShell scripts parsed; 6 architecture regression checks; native OS=$native."
