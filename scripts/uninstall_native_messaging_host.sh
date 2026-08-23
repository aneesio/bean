#!/bin/bash
# Removes the Bean Native Messaging host manifest from Chrome/Brave/Edge.
set -euo pipefail

HOST_NAME="com.bean.nativehost"
PREFERENCE_DOMAIN="com.bean.app"
APPROVAL_KEY="browserBridgeApprovedManualExtensionIDs"
removed=0

# Never follow an intermediate symlink while locating a browser's host folder.
# The exact manifest removal is deliberately scoped below a real directory
# chain rooted at this user's HOME.
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

for root in \
    "$HOME/Library/Application Support/Google/Chrome" \
    "$HOME/Library/Application Support/BraveSoftware/Brave-Browser" \
    "$HOME/Library/Application Support/Microsoft Edge" \
    "$HOME/Library/Application Support/Chromium"; do
    dir="$root/NativeMessagingHosts"
    [[ -d "$root" ]] || continue
    if ! safe_directory_chain "$HOME" "$root"; then
        echo "Skipped unsafe browser directory chain: $root" >&2
        continue
    fi
    [[ -e "$dir" || -L "$dir" ]] || continue
    if ! safe_directory_chain "$HOME" "$dir"; then
        echo "Skipped unsafe NativeMessagingHosts directory chain: $dir" >&2
        continue
    fi
    if [[ -f "$dir/$HOST_NAME.json" ]]; then
        rm -f "$dir/$HOST_NAME.json"
        echo "Removed $dir/$HOST_NAME.json"
        removed=1
    fi
done
defaults delete "$PREFERENCE_DOMAIN" "$APPROVAL_KEY" >/dev/null 2>&1 || true
[[ "$removed" -eq 1 ]] || echo "No Bean native messaging manifest installed."
echo "Cleared Bean's manual extension approval. Browser profiles and extension data were not changed."
