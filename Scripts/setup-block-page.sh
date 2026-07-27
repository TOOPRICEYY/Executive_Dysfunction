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
STATUS="$SUPPORT/filter-status.json"
DAEMON_PLIST="/Library/LaunchDaemons/com.GabrielPrice.ExecutiveDysfunction.blockpage.plist"
DAEMON_LABEL="com.GabrielPrice.ExecutiveDysfunction.blockpage"
SERVER_BIN="$DIR/BlockPageServer"
HOSTS="/etc/hosts"
MARK_BEGIN="# BEGIN ExecutiveDysfunction block page"
MARK_END="# END ExecutiveDysfunction block page"

if [ "$(id -u)" -ne 0 ]; then
  echo "This must run as root:  sudo $0" >&2
  exit 1
fi

remove_hosts_block() {
  if grep -qF "$MARK_BEGIN" "$HOSTS" 2>/dev/null; then
    # Keep a copy the first time we ever touch it.
    [ -f "$HOSTS.ExecutiveDysfunction.bak" ] || cp "$HOSTS" "$HOSTS.ExecutiveDysfunction.bak"
    /usr/bin/sed -i '' "/^${MARK_BEGIN}$/,/^${MARK_END}$/d" "$HOSTS"
  fi
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

mkdir -p "$DIR"
chmod 755 "$SUPPORT"
chmod 700 "$DIR"

# ---------------------------------------------------------------- CA
if [ ! -f "$DIR/ca.pem" ]; then
  echo "Generating root CA…"
  openssl ecparam -name prime256v1 -genkey -noout -out "$DIR/ca.key" 2>/dev/null
  openssl req -x509 -new -key "$DIR/ca.key" -sha256 -days 3650 \
    -subj "/CN=Executive Dysfunction Block Page CA/O=Executive Dysfunction" \
    -out "$DIR/ca.pem" 2>/dev/null
  chmod 600 "$DIR/ca.key"
  echo "Trusting the CA (this is the part that lets the page answer as a blocked site)…"
  security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain "$DIR/ca.pem"
else
  echo "Reusing existing CA."
fi

# ------------------------------------------------- domains to answer for
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
    if name not in out:
        out.append(name)
    www = "www." + name
    if www not in out:
        out.append(www)
print("\n".join(out))
PY
)

if [ -z "$DOMAINS" ]; then
  echo
  echo "No blocked domains found in $STATUS."
  echo "Start the app and make sure a block-list rule is active, then re-run this."
  exit 1
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
openssl req -new -key "$DIR/leaf.key" -subj "/CN=Blocked by Executive Dysfunction" \
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
BUNDLED="${BLOCKPAGE_BINARY:-/Applications/ExecutiveDysfunctionMac.app/Contents/MacOS/BlockPageServer}"
if [ -f "$BUNDLED" ]; then
  cp -f "$BUNDLED" "$SERVER_BIN"
elif [ ! -f "$SERVER_BIN" ]; then
  echo "Block page server not found at $BUNDLED" >&2
  echo "Install the app first, or set BLOCKPAGE_BINARY to the built binary." >&2
  exit 1
fi
chown root:wheel "$SERVER_BIN"
chmod 755 "$SERVER_BIN"

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
launchctl bootstrap system "$DAEMON_PLIST"

# -------------------------------------------------------- loopback redirect
echo "Pointing blocked domains at loopback…"
remove_hosts_block
{
  echo "$MARK_BEGIN"
  printf '%s\n' "$DOMAINS" | while IFS= read -r name; do
    [ -n "$name" ] && echo "127.0.0.1 $name"
  done
  echo "$MARK_END"
} >> "$HOSTS"

dscacheutil -flushcache 2>/dev/null || true
killall -HUP mDNSResponder 2>/dev/null || true

echo
echo "Done. $COUNT name(s) now show the block page."
echo "Verify:  curl -sS https://$(printf '%s\n' "$DOMAINS" | head -1) | head -5"
echo "Undo:    sudo $0 --uninstall"
