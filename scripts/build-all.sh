#!/usr/bin/env bash
# Build every app in ReleaseFast (native build) and report a summary.
# Binaries land in <app>/zig-out/bin/.
# Set NATIVE_BUILD_ARGS to forward extra build flags (word-split), e.g.
# NATIVE_BUILD_ARGS="-Dcpu=baseline" for release binaries that run on any
# CPU of the target architecture (CI runners vary in CPU features).
set -u

cd "$(dirname "$0")/.." || exit 1

failed=0
for app in apps/*/; do
  name="$(basename "$app")"
  printf '==> %s\n' "$name"
  # shellcheck disable=SC2086  # NATIVE_BUILD_ARGS is intentionally word-split
  if ! native build "$app" --yes ${NATIVE_BUILD_ARGS:-}; then
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
