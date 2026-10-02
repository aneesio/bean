#!/usr/bin/env bash
# Installs a verified local candidate while retaining an exact rollback bundle.
# Quit Bean and its browser connection first. No preferences or grants change.
# Use the printed backup as the source argument to perform a verified rollback.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANDIDATE="${1:-$ROOT/build/Bean.app}"
DESTINATION="${BEAN_INSTALL_DESTINATION:-/Applications/Bean.app}"
BACKUP_ROOT="${BEAN_INSTALL_BACKUP_ROOT:-$ROOT/build/installed-backups}"

[[ "$CANDIDATE" = /* && "$DESTINATION" = /* && "$DESTINATION" == */Bean.app ]] || {
    echo "error: use absolute candidate/destination paths ending in Bean.app." >&2; exit 2;
}
[[ -d "$CANDIDATE" && ! -L "$CANDIDATE" && ! -L "$DESTINATION" ]] || {
    echo "error: candidate must be a real app directory; symlink destinations are refused." >&2; exit 2;
}
[[ "$CANDIDATE" != "$DESTINATION" ]] || {
    echo "error: candidate and installed destination must differ." >&2; exit 2;
}
CANDIDATE="$(cd "$CANDIDATE" && pwd -P)"
codesign --verify --deep --strict --verbose=2 "$CANDIDATE"
IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$CANDIDATE/Contents/Info.plist")"
[[ "$IDENTIFIER" == "com.bean.app" && -x "$CANDIDATE/Contents/MacOS/Bean" ]] || {
    echo "error: candidate is not the Bean application." >&2; exit 2;
}
PARENT="$(dirname "$DESTINATION")"
[[ -d "$PARENT" && -w "$PARENT" && ! -L "$PARENT" ]] || {
    echo "error: installed-app parent is unavailable, unwritable or redirected." >&2; exit 2;
}
DESTINATION="$(cd "$PARENT" && pwd -P)/Bean.app"
[[ "$CANDIDATE" != "$DESTINATION" ]] || { echo "error: candidate resolves to the installed app." >&2; exit 2; }
INSTALL_LOCK="$PARENT/.Bean-install.lock"
INSTALL_LOCK_OWNED=false
STAGING_ROOT=""
INSTALL_COMMITTED=false
cleanup_install() {
    local status=$?
    # An interrupted publish must not let temporary-directory cleanup erase
    # the only installed copy. Retire a new uncommitted candidate and restore
    # the prior destination before removing staging.
    if [[ -n "$STAGING_ROOT" && "$INSTALL_COMMITTED" != true && -d "$STAGING_ROOT/previous.app" ]]; then
        if [[ -e "$DESTINATION" ]]; then
            mv "$DESTINATION" "$STAGING_ROOT/interrupted.app" || return 1
        fi
        mv "$STAGING_ROOT/previous.app" "$DESTINATION" || return 1
    fi
    [[ -z "$STAGING_ROOT" ]] || rm -rf "$STAGING_ROOT"
    if [[ "$INSTALL_LOCK_OWNED" == true ]]; then rmdir "$INSTALL_LOCK"; fi
    return "$status"
}
trap cleanup_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if ! mkdir "$INSTALL_LOCK" 2>/dev/null; then
    echo "error: another install is active, or an interrupted install lock remains at $INSTALL_LOCK. The installed app was left unchanged." >&2
    exit 3
fi
INSTALL_LOCK_OWNED=true
# Refuse a live binary rather than interrupt a user's writing or provider call.
if ps -axww -o comm= | awk -v executable="$DESTINATION/Contents/MacOS/Bean" '$0 == executable { found=1 } END { exit !found }'; then
    echo "error: quit Bean and disconnect its browser native host before installing." >&2
    exit 3
fi
mkdir -p "$BACKUP_ROOT"
[[ ! -L "$BACKUP_ROOT" ]] || { echo "error: backup directory must not be redirected." >&2; exit 2; }
STAGING_ROOT="$(mktemp -d "$PARENT/.Bean-install.XXXXXX")"
ditto "$CANDIDATE" "$STAGING_ROOT/Bean.app"
codesign --verify --deep --strict --verbose=2 "$STAGING_ROOT/Bean.app"
BACKUP=""
if [[ -e "$DESTINATION" ]]; then
    BACKUP_DIRECTORY="$(mktemp -d "$BACKUP_ROOT/installed.XXXXXX")"
    BACKUP="$BACKUP_DIRECTORY/Bean.app"
    ditto "$DESTINATION" "$BACKUP"
    codesign --verify --deep --strict --verbose=2 "$BACKUP"
    mv "$DESTINATION" "$STAGING_ROOT/previous.app"
fi
if ! mv "$STAGING_ROOT/Bean.app" "$DESTINATION"; then
    [[ ! -d "$STAGING_ROOT/previous.app" ]] || mv "$STAGING_ROOT/previous.app" "$DESTINATION"
    echo "error: install failed; the previous app was restored." >&2; exit 1
fi
if ! codesign --verify --deep --strict --verbose=2 "$DESTINATION"; then
    mv "$DESTINATION" "$STAGING_ROOT/rejected.app"
    [[ ! -d "$STAGING_ROOT/previous.app" ]] || mv "$STAGING_ROOT/previous.app" "$DESTINATION"
    echo "error: installed verification failed; the previous app was restored." >&2; exit 1
fi
INSTALL_COMMITTED=true
echo "Installed verified app: $DESTINATION"
[[ -z "$BACKUP" ]] || echo "Verified rollback source: $BACKUP"
echo "Local ad-hoc builds may require Accessibility to be restored after installation."
