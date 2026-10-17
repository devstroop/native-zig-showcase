#!/usr/bin/env bash
# Run every app's headless tests and markup/manifest check, then report a
# summary. Run from anywhere; the repo root is resolved from this script.
set -u

cd "$(dirname "$0")/.." || exit 1

failed=0
for app in apps/*/; do
  name="$(basename "$app")"
  printf '==> %s\n' "$name"
  if ! native test "$app" --yes; then
    printf '  test: FAILED\n'
    failed=$((failed + 1))
    continue
  fi
  if ! native check "$app"; then
    printf '  check: FAILED\n'
    failed=$((failed + 1))
    continue
  fi
  printf '  test+check ok\n'
done

if [ "$failed" -ne 0 ]; then
  printf '%d app(s) failed\n' "$failed" >&2
  exit 1
fi
printf 'all apps verified\n'
