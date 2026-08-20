#!/bin/bash
# Removes the Bean Native Messaging host manifest from Chrome/Brave/Edge.
set -euo pipefail

HOST_NAME="com.bean.nativehost"
removed=0
for dir in \
    "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts" \
    "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts" \
    "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"; do
    if [[ -f "$dir/$HOST_NAME.json" ]]; then
        rm -f "$dir/$HOST_NAME.json"
        echo "Removed $dir/$HOST_NAME.json"
        removed=1
    fi
done
[[ "$removed" -eq 1 ]] || echo "No Bean native messaging manifest installed."
