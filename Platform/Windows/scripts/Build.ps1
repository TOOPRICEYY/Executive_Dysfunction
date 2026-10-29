[CmdletBinding()]
param([ValidateSet('ARM64','x64')][string]$Architecture = 'ARM64', [string]$Configuration = 'Release', [switch]$SharedUI)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Get-NativeArchitecture.ps1')
$root = Split-Path $PSScriptRoot -Parent
& (Join-Path $root 'tests\ScriptTests.ps1')
$build = Join-Path $root "build-$Architecture"
$cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
if ($cmakeCommand) { $cmake = $cmakeCommand.Source } else {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (!(Test-Path $vswhere)) { throw 'Install Visual Studio C++ build tools and its CMake component first.' }
    $cmake = & $vswhere -latest -products '*' -find 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe' | Select-Object -First 1
    if (!$cmake) { throw 'Visual Studio CMake component was not found.' }
}
$ctest = Join-Path (Split-Path $cmake -Parent) 'ctest.exe'
$sharedUIOption = if ($SharedUI) { 'ON' } else { 'OFF' }
& $cmake -S $root -B $build -A $Architecture -DBUILD_TESTING=ON "-DHOLDFAST_BUILD_SHARED_UI=$sharedUIOption"
if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed; install Visual Studio C++ and the Windows SDK' }
& $cmake --build $build --config $Configuration
if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
$native = Get-HoldfastNativeArchitecture
if ($native -ieq $Architecture) {
    & $ctest --test-dir $build -C $Configuration --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }
} else { Write-Warning 'Cross-build only: runtime tests must also run on the target architecture.' }
& $cmake --install $build --config $Configuration --prefix (Join-Path $root "package-$Architecture")
if ($LASTEXITCODE -ne 0) { throw 'Packaging failed' }
