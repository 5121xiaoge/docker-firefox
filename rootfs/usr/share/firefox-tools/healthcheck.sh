#!/bin/sh

set -eu

if [ -z "${DISPLAY:-}" ]; then
    ENV_FILE="${1:-/tmp/.cont-env-internal}"
    [ -r "$ENV_FILE" ] || exit 1
    # Read the selected local display without evaluating the environment snapshot.
    DISPLAY="$(awk '
        /^export DISPLAY=":[0-9]+(\.[0-9]+)?"$/ {
            sub(/^export DISPLAY="/, "")
            sub(/"$/, "")
            print
            exit
        }
    ' "$ENV_FILE")"
fi

[ -n "${DISPLAY:-}" ] || exit 1
export DISPLAY
xdotool search --onlyvisible --class firefox

# Optionally verify that the web interface is still listening.  Reads the
# kernel socket table, so it works with TLS and web authentication enabled.
if [ "${FIREFOX_HEALTHCHECK_WEB:-0}" = 1 ]; then
    PORT="${WEB_LISTENING_PORT:-5800}"
    case "$PORT" in
        -1) exit 0 ;;
        ''|*[!0-9]*) exit 1 ;;
    esac
    HEX="$(printf '%04X' "$PORT")"
    FILES=
    for FILE in /proc/net/tcp /proc/net/tcp6; do
        if [ -r "$FILE" ]; then
            FILES="$FILES $FILE"
        fi
    done
    [ -n "$FILES" ] || exit 1
    # shellcheck disable=SC2086
    awk -v port="$HEX" '
        $2 ~ (":" port "$") && $4 == "0A" { found = 1 }
        END { exit !found }
    ' $FILES
fi
