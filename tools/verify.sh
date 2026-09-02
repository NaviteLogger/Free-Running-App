#!/bin/sh
#
# Runs every check in the repo and fails if any of them fail.
#
#   tools/verify.sh
#
# Each command runs unpiped so its exit status is the real one. Reading a
# result out of piped output reports whatever `tail` or `grep` returned, which
# is almost always success.
#
# POSIX sh, so it behaves the same under sh, zsh and bash.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
FAILED=''

run() {
  name=$1
  shift
  printf '\n=== %s ===\n' "$name"
  # Not named `status`: zsh reserves that as a read-only alias for $?, and
  # assigning to it aborts the function.
  if "$@"; then
    printf '    ok\n'
  else
    code=$?
    printf '    FAILED (exit %s)\n' "$code"
    FAILED="$FAILED\n  - $name"
  fi
}

cd "$ROOT/server"
run "server: formatting"  npm run --silent format:check
run "server: types"       npm run --silent typecheck
run "server: strict config still rejects" npm run --silent typecheck:config
run "server: tests"       npm test

cd "$ROOT/app"
run "app: formatting"     dart format --output=none --set-exit-if-changed .
run "app: analyzer"       flutter analyze --fatal-infos --fatal-warnings
run "app: tests"          flutter test

printf '\n'
if [ -n "$FAILED" ]; then
  printf 'FAILED:%b\n\n' "$FAILED"
  exit 1
fi
printf 'Everything passed.\n\n'
