#!/bin/bash
# Installs the Bean Native Messaging host manifest for Chrome/Brave/Edge.
#
#   ./scripts/install_native_messaging_host.sh <extension-id> [path-to-Bean.app]
#
# The "host" is the Bean app binary itself, run in native-messaging mode. The
# manifest points the browser at Bean.app/Contents/MacOS/Bean and restricts
# access to the single extension ID you pass.
#
# Re-run this script when:
#   • the unpacked extension's ID changes (reloading often changes it),
#   • you move Bean.app, or
#   • you rebuild/repackage Bean to a different path.
set -euo pipefail

HOST_NAME="com.bean.nativehost"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "error: $1" >&2; exit 1; }

EXT_ID="${1:-}"
if [[ -z "$EXT_ID" ]]; then
    cat >&2 <<EOF
Missing <extension-id>.

  1. Load the unpacked extension: chrome://extensions ▸ Developer mode ▸
     Load unpacked ▸ select $ROOT/BrowserExtension
  2. Copy the extension's ID (32 lowercase letters a–p).
  3. Re-run:  $0 <that-id>
EOF
    exit 1
fi

# Chrome extension IDs are exactly 32 chars in [a-p].
if [[ ! "$EXT_ID" =~ ^[a-p]{32}$ ]]; then
    fail "'$EXT_ID' doesn't look like a Chrome extension ID (expected 32 letters a–p). Copy it from chrome://extensions."
fi

# Locate Bean.app: explicit arg → /Applications → repo build/release output.
APP="${2:-}"
if [[ -z "$APP" ]]; then
    for candidate in "/Applications/Bean.app" "$ROOT/build/Bean.app" "$ROOT"/release/Bean-*/Bean.app; do
        [[ -d "$candidate" ]] && APP="$candidate" && break
    done
fi
[[ -n "${APP:-}" && -d "$APP" ]] || fail "couldn't find Bean.app. Build it (./scripts/build_app.sh release) or pass its path as the 2nd argument."
HOST_BIN="$APP/Contents/MacOS/Bean"
[[ -x "$HOST_BIN" ]] || fail "Bean host binary not found/executable at: $HOST_BIN"

read -r -d '' MANIFEST_JSON <<EOF || true
{
  "name": "$HOST_NAME",
  "description": "Bean native messaging host (browser extension <-> Bean Mac app).",
  "path": "$HOST_BIN",
  "type": "stdio",
  "allowed_origins": [ "chrome-extension://$EXT_ID/" ]
}
EOF

installed=0
install_to() {
    local browser="$1" dir="$2"
    [[ -d "$(dirname "$dir")" ]] || return 0   # browser not installed; skip silently
    if ! mkdir -p "$dir" 2>/dev/null; then
        echo "  ! could not create $dir (permission?) — skipped $browser" >&2
        return 0
    fi
    if printf '%s\n' "$MANIFEST_JSON" > "$dir/$HOST_NAME.json" 2>/dev/null; then
        echo "  ✓ $browser: $dir/$HOST_NAME.json"
        installed=1
    else
        echo "  ! $browser: failed to write manifest (permission?)" >&2
    fi
}

echo "==> Installing Bean native host manifest"
echo "    extension : $EXT_ID"
echo "    host bin  : $HOST_BIN"
install_to "Chrome" "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
install_to "Brave"  "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
install_to "Edge"   "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"

if [[ "$installed" -eq 0 ]]; then
    fail "no supported browser profile found (Chrome/Brave/Edge). Is the browser installed and launched once?"
fi

cat <<EOF

Done. Next:
  • Restart the browser if it was open.
  • In the extension's Options, click "Test Connection" — it should say Connected.
  • Enable "Web Inline Support" in Bean Settings so detection is allowed.
EOF
