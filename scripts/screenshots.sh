#!/usr/bin/env bash
# Regenerate the README screenshots (docs/screenshots/<app>.png): build
# every app with automation, launch it, capture its main canvas through
# the deterministic reference renderer (`native automate screenshot`),
# and stop it again. Needs a display (a GUI session or Xvfb) and the
# `native` CLI. Run from anywhere; the repo root is resolved from this
# script.
set -u

cd "$(dirname "$0")/.." || exit 1

failed=0
mkdir -p docs/screenshots
for app in apps/*/; do
  name="$(basename "$app")"
  printf '==> %s\n' "$name"
  if ! native build "$app" --release=fast -Dautomation=true --yes; then
    printf '  build: FAILED\n'
    failed=$((failed + 1))
    continue
  fi
  (
    cd "$app" || exit 1
    rm -rf .zig-cache/native-sdk-automation
    setsid "./zig-out/bin/$name" >"/tmp/$name-screenshot.log" 2>&1 < /dev/null &
    pid=$!
    native automate wait || { kill "$pid" >/dev/null 2>&1; exit 1; }
    native automate screenshot main-canvas || { kill "$pid" >/dev/null 2>&1; exit 1; }
    kill "$pid" >/dev/null 2>&1
  ) || {
    printf '  capture: FAILED\n'
    failed=$((failed + 1))
    continue
  }
  cp "$app/.zig-cache/native-sdk-automation/screenshot-main-canvas.png" "docs/screenshots/$name.png"
  if command -v magick >/dev/null 2>&1; then
    magick "docs/screenshots/$name.png" -resize '1000x>' -strip -colors 256 -define png:compression-level=9 "docs/screenshots/$name.png"
  elif command -v convert >/dev/null 2>&1; then
    convert "docs/screenshots/$name.png" -resize '1000x>' -strip -colors 256 -define png:compression-level=9 "docs/screenshots/$name.png"
  fi
  printf '  saved docs/screenshots/%s.png\n' "$name"
done

if [ "$failed" -ne 0 ]; then
  printf '%d app(s) failed\n' "$failed" >&2
  exit 1
fi
printf 'all screenshots refreshed\n'
