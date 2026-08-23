#!/bin/bash
# Advanced fallback: installs Bean's Native Messaging host manifest and records
# one explicit extension approval for signed Chrome/Brave/Edge. The in-app
# Settings → Browser flow is the normal installation path.
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
PREFERENCE_DOMAIN="com.bean.app"
APPROVAL_KEY="browserBridgeApprovedManualExtensionIDs"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "error: $1" >&2; exit 1; }

# Refuse a path when any existing directory component below the chosen anchor is
# a symbolic link. Checking only the final Chrome/NativeMessagingHosts entries
# is insufficient: an intermediate component such as `Google` could otherwise
# redirect this advanced fallback into an unrelated tree.
safe_directory_chain() {
    local anchor="$1" target="$2" current relative component
    case "$target" in
        "$anchor"|"$anchor"/*) ;;
        *) return 1 ;;
    esac
    [[ -d "$anchor" && ! -L "$anchor" ]] || return 1
    [[ "$target" == "$anchor" ]] && return 0
    relative="${target#"$anchor"/}"
    current="$anchor"
    while [[ -n "$relative" ]]; do
        component="${relative%%/*}"
        if [[ "$relative" == */* ]]; then
            relative="${relative#*/}"
        else
            relative=""
        fi
        current="$current/$component"
        [[ -d "$current" && ! -L "$current" ]] || return 1
    done
}

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

installed=0
install_to() {
    local browser="$1" root="$2" dir="$2/NativeMessagingHosts"
    local manifest temp
    [[ -d "$root" ]] || return 0   # browser not installed; skip silently
    if ! safe_directory_chain "$HOME" "$root"; then
        echo "  ! $browser: unsafe browser directory chain — skipped" >&2
        return 0
    fi
    if [[ -e "$dir" || -L "$dir" ]]; then
        if ! safe_directory_chain "$HOME" "$dir"; then
            echo "  ! $browser: unsafe NativeMessagingHosts directory chain — skipped" >&2
            return 0
        fi
    else
        if ! mkdir "$dir" 2>/dev/null || ! safe_directory_chain "$HOME" "$dir"; then
            echo "  ! could not safely create $dir (permission?) — skipped $browser" >&2
            return 0
        fi
    fi
    manifest="$dir/$HOST_NAME.json"
    if [[ -L "$manifest" || ( -e "$manifest" && ! -f "$manifest" ) ]]; then
        echo "  ! $browser: unsafe existing manifest target — skipped" >&2
        return 0
    fi
    if ! temp=$(mktemp "$dir/.$HOST_NAME.json.XXXXXX"); then
        echo "  ! $browser: could not create a temporary manifest — skipped" >&2
        return 0
    fi
    chmod 600 "$temp"
    if ! /usr/bin/plutil -create xml1 "$temp" \
        || ! /usr/bin/plutil -insert name -string "$HOST_NAME" "$temp" \
        || ! /usr/bin/plutil -insert description -string "Bean native messaging host (browser extension <-> Bean Mac app)." "$temp" \
        || ! /usr/bin/plutil -insert path -string "$HOST_BIN" "$temp" \
        || ! /usr/bin/plutil -insert type -string "stdio" "$temp" \
        || ! /usr/bin/plutil -insert allowed_origins -array "$temp" \
        || ! /usr/bin/plutil -insert allowed_origins.0 -string "chrome-extension://$EXT_ID/" "$temp" \
        || ! /usr/bin/plutil -convert json "$temp"; then
        rm -f "$temp"
        echo "  ! $browser: failed to encode manifest JSON — skipped" >&2
        return 0
    fi
    chmod 600 "$temp"
    # Recheck after encoding. `mv` renames the complete 0600 file atomically;
    # it never streams JSON through the final path or a symbolic link.
    if [[ -L "$manifest" || ( -e "$manifest" && ! -f "$manifest" ) ]]; then
        rm -f "$temp"
        echo "  ! $browser: unsafe existing manifest target — skipped" >&2
        return 0
    fi
    if /bin/mv -f "$temp" "$manifest" 2>/dev/null \
        && [[ -f "$manifest" && ! -L "$manifest" ]]; then
        echo "  ✓ $browser: $manifest"
        installed=1
    else
        rm -f "$temp"
        echo "  ! $browser: failed to write manifest (permission?)" >&2
    fi
}

echo "==> Installing Bean native host manifest"
echo "    extension : $EXT_ID"
echo "    host bin  : $HOST_BIN"
install_to "Chrome" "$HOME/Library/Application Support/Google/Chrome"
install_to "Brave"  "$HOME/Library/Application Support/BraveSoftware/Brave-Browser"
install_to "Edge"   "$HOME/Library/Application Support/Microsoft Edge"

if [[ "$installed" -eq 0 ]]; then
    fail "no supported signed browser profile found (Chrome/Brave/Edge). Is the browser installed and launched once?"
fi

# The hardened Bean host accepts a manually supplied extension ID only when the
# same exact ID is present in Bean's approval store. A manifest alone is not an
# authorization source. Replace (do not accumulate) the prior manual approval.
if ! defaults write "$PREFERENCE_DOMAIN" "$APPROVAL_KEY" -array "$EXT_ID"; then
    fail "the manifest was written, but Bean's exact extension approval could not be saved. Open Bean → Settings → Browser and choose Repair Connection."
fi

cat <<EOF

Done. Next:
  • Restart the browser if it was open.
  • In the extension's Options, click "Check again" — App connection should say Connected.
  • Optional AI: turn on "Allow deeper AI checks from the browser" in Bean Settings → Browser.
EOF
