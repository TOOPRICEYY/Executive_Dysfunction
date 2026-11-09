#!/bin/zsh
# Run from macOS after Windows, UTM guest tools, VS C++ and CMake are installed.
# Uses guest-agent transport, not the guest network under test. Never toggles
# host networking, disables Secure Boot, or installs the prototype driver.
set -euo pipefail
if (( $# < 1 || $# > 2 )); then
  print -u2 'Usage: /bin/zsh Deploy-UTM.zsh "Holdfast Windows ARM64 Test" [ARM64|x64]'
  exit 2
fi
vm="$1"
architecture="${2:-ARM64}"
if [[ "$architecture" != ARM64 && "$architecture" != x64 ]]; then
  print -u2 'Architecture must be ARM64 or x64'; exit 2
fi
utmctl=/Applications/UTM.app/Contents/MacOS/utmctl
root="${0:A:h:h}"
source "$root/scripts/UTM-Guest.zsh"
staging=$(/usr/bin/mktemp -d /private/tmp/Holdfast-Windows-UTM.XXXXXX)
guest='C:\HoldfastBuild'
"$utmctl" status "$vm"
# Each revision gets a fresh destination, so an interrupted build cannot be
# mistaken for a successfully tested package from an earlier run.
stamp="$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$"
guest="$guest\\$stamp"
function guest_ps() {
  utm_guest_ps "$vm" "$1"
}
guest_ps "\$ErrorActionPreference='Stop'; New-Item -ItemType Directory -Path '$guest' -Force | Out-Null"
function capture_failure() {
  "$utmctl" file pull "$vm" "$guest\\build.log" > "$staging/build.log" 2>/dev/null || true
  "$utmctl" file pull "$vm" "$guest\\install.log" > "$staging/install.log" 2>/dev/null || true
  print -u2 "Deployment incomplete; available logs are in $staging"
}
trap capture_failure ZERR
# Explicit source directories exclude previous build outputs and local policy.
(cd "$root" && /usr/bin/zip -qr "$staging/source.zip" CMakeLists.txt core include service tools tests scripts assets)
"$utmctl" file push "$vm" "$guest\\source.zip" < "$staging/source.zip"
guest_ps "\$ErrorActionPreference='Stop'; Expand-Archive -LiteralPath '$guest\\source.zip' -DestinationPath '$guest\\source'; Get-ChildItem '$guest\\source' -Recurse -File | ForEach-Object { \$_.LastWriteTimeUtc = [DateTime]::UtcNow }; & '$guest\\source\\scripts\\Build.ps1' -Architecture '$architecture' *> '$guest\\build.log'; if (!\$?) { throw 'Build failed' }"
"$utmctl" file pull "$vm" "$guest\\build.log" > "$staging/build.log"
guest_ps "\$ErrorActionPreference='Stop'; & '$guest\\source\\scripts\\Install.ps1' -PackageDirectory '$guest\\source\\package-$architecture' *> '$guest\\install.log'; if (!\$?) { throw 'Installation failed' }"
"$utmctl" file pull "$vm" "$guest\\install.log" > "$staging/install.log"
print -r -- "Deployed disabled development build. VM: $vm; guest sources: $guest"
print -r -- "Host logs: $staging"
print 'Run Test-Connectivity.ps1 in the guest to opt into the bounded application-network test.'
