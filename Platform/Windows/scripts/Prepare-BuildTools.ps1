[CmdletBinding()]
param([switch]$Install, [switch]$AcceptLicense)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$installer = Join-Path $env:TEMP 'Holdfast-vs-buildtools.exe'
Invoke-WebRequest -UseBasicParsing 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile $installer
$signature = Get-AuthenticodeSignature $installer
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw 'Build-tools installer does not have a valid Microsoft signature.'
}
Write-Output "Verified Microsoft installer: $installer"
Write-Output $signature.SignerCertificate.Subject
if (!$Install) { Write-Output 'Downloaded only. Installation requires approval of Microsoft build-tools license terms.'; return }
if (!$AcceptLicense) { throw 'Use -AcceptLicense only after the owner has approved the Microsoft build-tools license terms.' }
$arguments = @('--quiet', '--wait', '--norestart', '--nocache',
    '--add', 'Microsoft.VisualStudio.Workload.VCTools',
    '--add', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64',
    '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.26100',
    '--add', 'Microsoft.VisualStudio.Component.VC.CMake.Project')
$process = Start-Process $installer -ArgumentList $arguments -PassThru -Wait
if ($process.ExitCode -notin @(0, 3010)) { throw "Build-tools installer failed: $($process.ExitCode). Inspect dd_* logs in $env:TEMP." }
Write-Output "Build tools installed. Exit code: $($process.ExitCode) (3010 means restart required)."
