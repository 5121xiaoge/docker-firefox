#!/bin/sh

set -e
set -u

PREF_FILE="${1:-/config/profile/prefs.js}"

if [ -z "$PREF_FILE" ]; then
    echo "ERROR: Preference file not set."
    exit 1
fi

if [ -L "$PREF_FILE" ] || { [ -e "$PREF_FILE" ] && [ ! -f "$PREF_FILE" ]; }; then
    echo "ERROR: Preference file must be a regular file." >&2
    exit 1
fi

mkdir -p "$(dirname "$PREF_FILE")"
TEMP_FILE="$(mktemp "$PREF_FILE.tmp.XXXXXX")"
trap 'rm -f "$TEMP_FILE"' 0
trap 'exit 1' 1 2 15

INPUT_FILE=/dev/null
CREATED=1
if [ -f "$PREF_FILE" ]; then
    CREATED=0
    INPUT_FILE="$PREF_FILE"
    cp -p "$PREF_FILE" "$TEMP_FILE"
fi

# Keep the original file and its metadata intact until all values are valid.
awk -f /usr/share/firefox-tools/set-prefs.awk "$INPUT_FILE" > "$TEMP_FILE"
mv -f "$TEMP_FILE" "$PREF_FILE"

# A newly created file inherits mktemp's 0600 mode and root ownership, which
# would make it unreadable for Firefox running as USER_ID:GROUP_ID.
if [ "$CREATED" = 1 ]; then
    chmod 644 "$PREF_FILE"
    if [ "$(id -u)" = 0 ]; then
        chown "${USER_ID:-1000}:${GROUP_ID:-1000}" "$PREF_FILE"
    fi
fi

# vim:ft=sh:ts=4:sw=4:et:sts=4
