#!/bin/bash
# Update the existing helper only; preserve certificates and hosts configuration.
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo /bin/bash." >&2
  exit 1
fi
app=/Applications/Holdfast.app
source_binary="$app/Contents/MacOS/BlockPageServer"
target_binary='/Library/Application Support/ExecutiveDysfunction/blockpage/BlockPageServer'
label=com.GabrielPrice.ExecutiveDysfunction.blockpage
test -f "$source_binary"
test -f "$target_binary"
test ! -L "$target_binary"
/usr/bin/codesign --verify --deep --strict "$app"
backup_dir=$(/usr/bin/mktemp -d /private/tmp/Holdfast-blockpage-backup.XXXXXX)
/bin/cp -p "$target_binary" "$backup_dir/BlockPageServer"
/usr/bin/install -S -o root -g wheel -m 755 "$source_binary" "$target_binary"
if ! /bin/launchctl kickstart -k "system/$label"; then
  /usr/bin/install -S -o root -g wheel -m 755 "$backup_dir/BlockPageServer" "$target_binary"
  /bin/launchctl kickstart -k "system/$label" || true
  echo "Restart failed; restored previous binary. Backup: $backup_dir" >&2
  exit 1
fi
echo "Helper updated. Backup: $backup_dir"
echo "Reload the original blocked page to load the new verification controls."
