#!/usr/bin/env bash
# Build every app in ReleaseFast (native build) and report a summary.
# Binaries land in <app>/zig-out/bin/.
set -u

cd "$(dirname "$0")/.." || exit 1

failed=0
for app in apps/*/; do
  name="$(basename "$app")"
  printf '==> %s\n' "$name"
  if ! native build "$app" --yes; then
    printf '  build: FAILED\n'
    failed=$((failed + 1))
    continue
  fi
  printf '  release ok\n'
done

if [ "$failed" -ne 0 ]; then
  printf '%d app(s) failed\n' "$failed" >&2
  exit 1
fi
printf 'all apps built (ReleaseFast)\n'
