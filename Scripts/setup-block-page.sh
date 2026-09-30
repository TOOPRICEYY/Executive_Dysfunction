#!/bin/bash
#
# Installs the block page: a locally trusted CA, a leaf certificate covering the
# currently blocked domains, the loopback redirect, and the server daemon.
#
# Run with sudo. Re-run any time the block list changes.
#
#   sudo Scripts/setup-block-page.sh            # install / refresh
#   sudo Scripts/setup-block-page.sh --uninstall
#
# WHAT THIS TRUSTS
#
# It creates a root CA and marks it trusted for SSL on this machine, so the
# block page can answer as x.com and be believed. That CA can impersonate ANY
# site to this Mac. Its private key stays at
# /Library/Application Support/ExecutiveDysfunction/blockpage/ca.key, root-owned
# and 0600. Anyone who reads that key can intercept your TLS. Uninstall removes
# both the key and the trust setting.

set -euo pipefail

SUPPORT="/Library/Application Support/ExecutiveDysfunction"
DIR="$SUPPORT/blockpage"
STATUS="${BLOCKPAGE_STATUS:-$SUPPORT/filter-status.json}"
DAEMON_PLIST="/Library/LaunchDaemons/com.GabrielPrice.ExecutiveDysfunction.blockpage.plist"
DAEMON_LABEL="com.GabrielPrice.ExecutiveDysfunction.blockpage"
SERVER_BIN="$DIR/BlockPageServer"
HOSTS="/etc/hosts"
MARK_BEGIN="# BEGIN Holdfast block page"
MARK_END="# END Holdfast block page"
LEGACY_MARK_BEGIN="# BEGIN ExecutiveDysfunction block page"
LEGACY_MARK_END="# END ExecutiveDysfunction block page"

if [ "$(id -u)" -ne 0 ]; then
  echo "This must run as root:  sudo $0" >&2
  exit 1
fi

remove_hosts_block() {
  for marker_pair in "$MARK_BEGIN|$MARK_END" "$LEGACY_MARK_BEGIN|$LEGACY_MARK_END"; do
    pair_begin=${marker_pair%%|*}
    pair_end=${marker_pair#*|}
    if grep -qF "$pair_begin" "$HOSTS" 2>/dev/null; then
      # Keep a copy the first time Holdfast ever touches it.
      [ -f "$HOSTS.Holdfast.bak" ] || cp "$HOSTS" "$HOSTS.Holdfast.bak"
      /usr/bin/sed -i '' "/^${pair_begin}$/,/^${pair_end}$/d" "$HOSTS"
    fi
  done
}

if [ "${1:-}" = "--uninstall" ]; then
  echo "Removing block page…"
  launchctl bootout system/"$DAEMON_LABEL" 2>/dev/null || true
  rm -f "$DAEMON_PLIST"
  remove_hosts_block
  if [ -f "$DIR/ca.pem" ]; then
    FP=$(openssl x509 -in "$DIR/ca.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
    security delete-certificate -Z "$FP" /Library/Keychains/System.keychain 2>/dev/null || true
  fi
  rm -rf "$DIR"
  dscacheutil -flushcache 2>/dev/null || true
  killall -HUP mDNSResponder 2>/dev/null || true
  echo "Removed. The filter still blocks these domains; they now fail to connect again."
  exit 0
fi

# Validate every input before creating or trusting certificate material. A
# failed preflight must leave the System keychain and /etc/hosts untouched.
DOMAINS=$(/usr/bin/python3 - "$STATUS" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as handle:
        data = json.load(handle)
except Exception:
    sys.exit(0)
names = data.get("blockedDomains") or []
out = []
for name in names:
    name = name.strip().lower().lstrip(".")
    if not name:
        continue
    if name.startswith("www."):
        name = name[4:]
    for candidate in (name, "www." + name):
        if candidate not in out:
            out.append(candidate)
print("\n".join(out))
PY
)

if [ -z "$DOMAINS" ]; then
  echo
  echo "No blocked domains found in $STATUS."
  echo "Run a guarded blocking test so the provider publishes the policy, then re-run this."
  exit 1
fi

BUNDLED="${BLOCKPAGE_BINARY:-/Applications/Holdfast.app/Contents/MacOS/BlockPageServer}"
if [ ! -f "$BUNDLED" ]; then
  echo "Block page server not found at $BUNDLED" >&2
  echo "Install the app first, or set BLOCKPAGE_BINARY to the built binary." >&2
  exit 1
fi

mkdir -p "$DIR"
chmod 755 "$SUPPORT"
chmod 700 "$DIR"

CREATED_CA=0
rollback_new_ca() {
  CODE=$?
  if [ "$CODE" -ne 0 ] && [ "$CREATED_CA" -eq 1 ]; then
    echo "Installation failed; removing the newly trusted block-page CA." >&2
    if [ -f "$DIR/ca.pem" ]; then
      FP=$(openssl x509 -in "$DIR/ca.pem" -noout -fingerprint -sha1 2>/dev/null | cut -d= -f2 | tr -d ':')
      [ -z "$FP" ] || security delete-certificate -Z "$FP" /Library/Keychains/System.keychain >/dev/null 2>&1 || true
    fi
    rm -rf "$DIR"
  fi
  exit "$CODE"
}
trap rollback_new_ca ERR

# ---------------------------------------------------------------- CA
if [ ! -f "$DIR/ca.pem" ]; then
  CREATED_CA=1
  echo "Generating root CA…"
  openssl ecparam -name prime256v1 -genkey -noout -out "$DIR/ca.key" 2>/dev/null
  openssl req -x509 -new -key "$DIR/ca.key" -sha256 -days 3650 \
    -subj "/CN=Holdfast Block Page CA/O=Holdfast" \
    -out "$DIR/ca.pem" 2>/dev/null
  chmod 600 "$DIR/ca.key"
  echo "Trusting the CA (this is the part that lets the page answer as a blocked site)…"
  security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain "$DIR/ca.pem"
else
  echo "Reusing existing CA."
fi

COUNT=$(printf '%s\n' "$DOMAINS" | wc -l | tr -d ' ')
echo "Minting a leaf certificate for $COUNT name(s)…"

SAN=$(printf '%s\n' "$DOMAINS" | awk '{printf "DNS:%s,", $0}' | sed 's/,$//')
cat > "$DIR/leaf.cnf" <<EOF
[req]
distinguished_name=dn
[dn]
[ext]
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$SAN
EOF

openssl ecparam -name prime256v1 -genkey -noout -out "$DIR/leaf.key" 2>/dev/null
openssl req -new -key "$DIR/leaf.key" -subj "/CN=Blocked by Holdfast" \
  -out "$DIR/leaf.csr" 2>/dev/null
# Apple requires <=825 days for server certificates to be trusted.
openssl x509 -req -in "$DIR/leaf.csr" -CA "$DIR/ca.pem" -CAkey "$DIR/ca.key" \
  -CAcreateserial -days 800 -sha256 \
  -extfile "$DIR/leaf.cnf" -extensions ext -out "$DIR/leaf.pem" 2>/dev/null

PASS=$(openssl rand -hex 16)
printf '%s' "$PASS" > "$DIR/identity.pass"
chmod 600 "$DIR/identity.pass"
openssl pkcs12 -export -inkey "$DIR/leaf.key" -in "$DIR/leaf.pem" -certfile "$DIR/ca.pem" \
  -passout "pass:$PASS" -out "$DIR/identity.p12" 2>/dev/null
chmod 600 "$DIR/identity.p12" "$DIR/leaf.key" "$DIR/ca.key"

# ------------------------------------------------------------- server
# Shipped inside the app bundle, so a refresh always installs the server that
# matches the installed app rather than whatever was copied here once.
cp -f "$BUNDLED" "$SERVER_BIN"
chown root:wheel "$SERVER_BIN"
chmod 755 "$SERVER_BIN"
printf '%s\n' "$DOMAINS" > "$DIR/configured-domains.txt"
chown root:wheel "$DIR/configured-domains.txt"
chmod 644 "$DIR/configured-domains.txt"

cat > "$DAEMON_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$DAEMON_LABEL</string>
  <key>ProgramArguments</key><array><string>$SERVER_BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$DIR/server.log</string>
</dict></plist>
EOF
chown root:wheel "$DAEMON_PLIST"
chmod 644 "$DAEMON_PLIST"

launchctl bootout system/"$DAEMON_LABEL" 2>/dev/null || true
# Keep a pristine recovery copy before the daemon ever gains authority to edit
# the hosts file. This is intentionally not overwritten by later refreshes.
[ -f "$HOSTS.Holdfast.bak" ] || cp "$HOSTS" "$HOSTS.Holdfast.bak"
remove_hosts_block
launchctl bootstrap system "$DAEMON_PLIST"

dscacheutil -flushcache 2>/dev/null || true
killall -HUP mDNSResponder 2>/dev/null || true
trap - ERR

echo
echo "Done. $COUNT name(s) are ready to show the block page while blocking is active."
echo "Mappings are removed automatically when the provider heartbeat stops or says blocking is inactive."
echo "Verify:  curl -sS https://$(printf '%s\n' "$DOMAINS" | head -1) | head -5"
echo "Undo:    sudo $0 --uninstall"
