#!/bin/zsh
# Source this file, or run: zsh UTM-Guest.zsh VM script.ps1 [timeout-seconds]
# Some UTM versions return zero/empty output before a guest process finishes.
# Require a unique completion marker, independent of that transport exit code.
function utm_guest_ps() {
  local vm_name="$1" ps_code="$2" max_seconds="${3:-1800}"
  local ctl=/Applications/UTM.app/Contents/MacOS/utmctl
  local token=$(/usr/bin/uuidgen) stage wrapper encoded marker elapsed=0
  stage=$(/usr/bin/mktemp -d /private/tmp/Holdfast-Guest.XXXXXX) || return 1
  local guest_base="C:\\Windows\\Temp\\Holdfast-$token"
  wrapper="\$ErrorActionPreference='Stop'; try { & { $ps_code } *>&1 | Out-File -Encoding utf8 '$guest_base.log'; [IO.File]::WriteAllText('$guest_base.done', '$token:OK') } catch { \$_ | Out-File -Append -Encoding utf8 '$guest_base.log'; [IO.File]::WriteAllText('$guest_base.done', '$token:FAIL') }"
  encoded=$(print -rn -- "$wrapper" | /usr/bin/iconv -f UTF-8 -t UTF-16LE | /usr/bin/base64 | /usr/bin/tr -d '\n')
  "$ctl" exec "$vm_name" --cmd 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$encoded" || return 1
  while (( elapsed < max_seconds )); do
    marker=$("$ctl" file pull "$vm_name" "$guest_base.done" 2>/dev/null) || marker=''
    if [[ "$marker" == "$token:OK" || "$marker" == "$token:FAIL" ]]; then
      "$ctl" file pull "$vm_name" "$guest_base.log" > "$stage/guest.log"
      /bin/cat "$stage/guest.log"
      print -u2 "Guest log: $stage/guest.log"
      [[ "$marker" == "$token:OK" ]]
      return $?
    fi
    /bin/sleep 2
    (( elapsed += 2 ))
  done
  print -ru2 -- "No verified completion after $max_seconds seconds. Guest may still be running; do not retry mutations blindly. Log: $guest_base.log"
  return 1
}
if [[ "$ZSH_EVAL_CONTEXT" == toplevel ]]; then
  set -euo pipefail
  if (( $# < 2 || $# > 3 )); then
    print -u2 'Usage: UTM-Guest.zsh VM script.ps1 [timeout-seconds]'; exit 2
  fi
  utm_guest_ps "$1" "$(<"$2")" "${3:-1800}"
fi
