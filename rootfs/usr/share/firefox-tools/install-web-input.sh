#!/bin/sh
set -eu

WEB_ROOT="${1:-/opt/noVNC}"
INDEX="$WEB_ROOT/index.html"
TOOLS="${FIREFOX_TOOLS_DIR:-/usr/share/firefox-tools}"

test -f "$WEB_ROOT/app/firefox-input.js"
test -f "$WEB_ROOT/app/styles/firefox-input.css"

# firefox-input.js relies on these noVNC internals; refuse to build an image
# whose noVNC no longer provides them.
require() {
    grep -qF -- "$2" "$WEB_ROOT/$1" || {
        echo "ERROR: $1 lacks '$2'; update firefox-input.js for this noVNC." >&2
        exit 1
    }
}
while IFS='|' read -r FILE TEXT; do
    [ -n "$FILE" ] && require "$FILE" "$TEXT"
done <<'EOF'
core/rfb.js|this._canvas
core/rfb.js|this._screen
core/rfb.js|this._display
core/rfb.js|this._gestures
core/rfb.js|this._mouseButtonMask
core/rfb.js|this._mousePos
core/rfb.js|this._viewportDragging
core/rfb.js|_updateScale() {
core/rfb.js|_fixScrollbars() {
core/rfb.js|_saveExpectedClientSize() {
core/rfb.js|_handleMouseButton(x, y, bmask) {
core/display.js|get scale() {
core/display.js|set scale(scale) {
core/input/gesturehandler.js|this._ignored
core/input/gesturehandler.js|this._tracked
core/input/gesturehandler.js|this._state
core/input/gesturehandler.js|attach(target) {
core/input/gesturehandler.js|detach() {
app/ui.js|forceSetting(name, val) {
app/ui.js|enableSetting(name) {
app/ui.js|applyResizeMode() {
app/ui.js|updateViewClip() {
app/ui.js|connect(event, password) {
index.html|id="noVNC_action_icons_section"
EOF

if grep -q 'installFirefoxInput(UI)' "$INDEX"; then
    exit 0
fi

TEMP="$(mktemp "$WEB_ROOT/.index.XXXXXX")"
trap 'rm -f "$TEMP"' EXIT HUP INT TERM
awk -f "$TOOLS/install-web-input.awk" "$INDEX" > "$TEMP"
cat "$TEMP" > "$INDEX"
