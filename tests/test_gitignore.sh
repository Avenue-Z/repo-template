#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
source tests/lib.sh

echo "gitignore: env block ordering"
touch .env .env.local .env.production .env.example

assert_ignored   .env
assert_ignored   .env.local
assert_ignored   .env.production
assert_trackable .env.example          # THE trap: a negation before .env.* silently ignores this

echo "gitignore: credential block"
touch sa-key.json client_secrets.json token.json google-credentials.json my-service-account.json
for f in sa-key.json client_secrets.json token.json google-credentials.json my-service-account.json; do
  assert_ignored "$f"
done

rm -f .env .env.local .env.production .env.example sa-key.json client_secrets.json \
      token.json google-credentials.json my-service-account.json
finish
