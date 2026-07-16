#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

# ---------------------------------------------------------------------------------------
# TEST-RUNNER INTEGRITY (design Item 2). Both runners already fail on zero tests by DEFAULT
# (pytest exits 5 on no collection; vitest's passWithNoTests defaults false). Item 2 does not
# add that guarantee — it makes it EXPLICIT AND TAMPER-EVIDENT so a future config edit cannot
# silently flip it open. These assertions ARE that tamper-evidence: drop the pytest strict flags
# or flip passWithNoTests to true and the grep fails, turning `ci` red. Coverage % is out of scope.

echo "python: pytest runs strict — an unknown config key or marker must fail, not pass silently"
PY=templates/python/pyproject.toml
assert_file "python pyproject.toml exists" "$PY"
py="$(cat "$PY")"
assert_match "pyproject declares pytest addopts"                 'addopts'          "$py"
assert_match "pytest addopts carries --strict-config (unknown config key -> error)"  '\-\-strict-config'  "$py"
assert_match "pytest addopts carries --strict-markers (unknown marker -> error)"     '\-\-strict-markers' "$py"

echo "next: vitest must fail on zero tests, set explicitly so a config edit cannot open it"
NV=templates/next/vitest.config.ts
assert_file "next vitest.config.ts exists" "$NV"
assert_match "next vitest sets passWithNoTests: false" 'passWithNoTests:[[:space:]]*false' "$(cat "$NV")"

echo "node: vitest must fail on zero tests, set explicitly in a committed config (node had none)"
OV=templates/node/vitest.config.ts
assert_file "node vitest.config.ts exists (created so the guarantee is committed, not a default)" "$OV"
assert_match "node vitest sets passWithNoTests: false" 'passWithNoTests:[[:space:]]*false' "$(cat "$OV")"

finish
