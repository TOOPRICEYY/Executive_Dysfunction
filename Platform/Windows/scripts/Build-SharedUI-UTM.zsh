#!/bin/zsh
# Builds/packages the shared interface host; never installs or changes enforcement.
set -euo pipefail
if (( $# < 1 || $# > 2 )); then
  print -u2 'Usage: Build-SharedUI-UTM.zsh "Holdfast Windows ARM64 Test" [ARM64|x64]'; exit 2
fi
vm="$1"
architecture="${2:-ARM64}"
if [[ "$architecture" != ARM64 && "$architecture" != x64 ]]; then exit 2; fi
root="${0:A:h:h:h:h}"
source "$root/Platform/Windows/scripts/UTM-Guest.zsh"
utmctl=/Applications/UTM.app/Contents/MacOS/utmctl
staging=$(/usr/bin/mktemp -d /private/tmp/Holdfast-SharedUI-UTM.XXXXXX)
guest="C:\\HoldfastUIBuild\\$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$"
if [[ ! -f "$root/SharedUI/dist/app.js" ]]; then
  print -u2 'Build the single SharedUI bundle first (npm ci && npm run build).'; exit 1
fi
(cd "$root" && /usr/bin/zip -qr "$staging/source.zip" SharedUI/dist \
  Platform/Windows/CMakeLists.txt Platform/Windows/README.md Platform/Windows/core \
  Platform/Windows/include Platform/Windows/service Platform/Windows/tools \
  Platform/Windows/tests Platform/Windows/scripts Platform/Windows/assets Platform/Windows/ui)
utm_guest_ps "$vm" "New-Item -ItemType Directory -Path '$guest' -Force | Out-Null" 60
"$utmctl" file push "$vm" "$guest\\source.zip" < "$staging/source.zip"
function capture_log() {
  "$utmctl" file pull "$vm" "$guest\\build.log" > "$staging/build.log" 2>/dev/null || true
  print -r -- "Build log: $staging/build.log; guest: $guest"
}
trap capture_log EXIT
utm_guest_ps "$vm" "Expand-Archive -LiteralPath '$guest\\source.zip' -DestinationPath '$guest\\source'; Get-ChildItem '$guest\\source' -Recurse -File | ForEach-Object { \$_.LastWriteTimeUtc = [DateTime]::UtcNow }; & '$guest\\source\\Platform\\Windows\\scripts\\Build.ps1' -Architecture '$architecture' -SharedUI *> '$guest\\build.log'; if (!\$?) { throw 'Shared interface build failed' }" 600
print 'Connected UI/service package built; not installed. Install with scripts/Install.ps1, then open Holdfast from the Start menu.'
