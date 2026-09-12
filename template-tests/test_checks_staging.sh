#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

WORKFLOW=.github/workflows/checks.yml

# WHERE THE GATE SCRIPTS COME FROM IS THE WHOLE TRUST ROOT, AND IT SHIPPED BROKEN.
#
# The first cut of this step read `github.job_workflow_ref` out of the `github` expression context.
# That context field DOES NOT EXIST — it is empty on a called run and on a direct one alike — so the
# step's "impossible" refusal fired in every consumer and no gate ever ran anywhere. Measured on a
# real adoption (avenue-z-ci-lab/adopter-private run 34705802136) and reproduced with no Avenue-Z
# involvement at all (ci-probe run 34705912086). Nothing in this repo noticed, because no suite
# drove the step.
#
# The value is real; it is an OIDC CLAIM, not a context field (run 34708273212). So this suite
# EXECUTES the resolver against a stubbed token endpoint. Every assertion below is about behaviour
# the step actually has, not about strings sitting in it.
#
# Steps are located by `id:`, never by index — test_advance_v1.sh already learned that one.

echo "checks staging: the resolver step exists and can be extracted from the workflow"
assert_file "$WORKFLOW exists" "$WORKFLOW"

RESOLVER="$(mktemp)"
RT="$(mktemp -d)"
trap 'rm -f "${RESOLVER}"; rm -rf "${RT}"' EXIT

python3 - "$WORKFLOW" > "$RESOLVER" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = d['jobs']['checks']['steps']
s = next((s for s in steps if s.get('id') == 'scripts_src'), None)
if s is None:
    sys.exit("no step with id 'scripts_src' in checks.yml")
sys.stdout.write(s['run'])
PY
if [ -s "$RESOLVER" ]; then
  pass "the 'scripts_src' step's script was extracted"
else
  fail "checks.yml must contain a step with id: scripts_src"
fi

wf="$(cat "$WORKFLOW")"

# THE REGRESSION ASSERTION. This is the one that would have stopped the fleet-wide outage, and it
# is a string match on purpose: the defect is that a particular context read returns nothing at
# runtime, which no amount of local execution can discover.
# STRUCTURAL, not a grep of the file. The file DOCUMENTS the dead field at length, deliberately --
# "do not reach for this" is the single most useful sentence in this workflow -- and a text grep
# cannot tell that prose from a live `${{ }}` read. Serialise the parsed YAML instead: comments are
# gone, every run body, env value and `if:` expression survives, and only an executable read matches.
echo "checks staging: the dead context field is gone from every executable position"
assert_nomatch "no step reads github.job_workflow_ref (that context is ALWAYS empty)" \
  'github\.job_workflow_ref' "$(python3 -c 'import yaml,sys; print(yaml.safe_dump(yaml.safe_load(open(sys.argv[1])))) ' "$WORKFLOW")"

# Minting an OIDC token needs the permission. Reusable-workflow permissions can be maintained or
# reduced along the call chain, never elevated — so a called workflow that declares only
# `contents: read` REDUCES id-token to none and the claim can never be read, no matter what the
# caller granted.
echo "checks staging: the workflow declares the permission the token fetch requires"
assert_match "checks.yml declares id-token: write" 'id-token:[[:space:]]*write' "$wf"
assert_match "checks.yml still declares contents: read" 'contents:[[:space:]]*read' "$wf"

# <msg> <expected-exit> ; env comes from the caller
resolve() {
  local msg="$1" want="$2" rc=0
  : > "${RT}/out"
  GITHUB_OUTPUT="${RT}/out" bash "${RESOLVER}" > "${RT}/log" 2>&1 || rc=$?
  assert_eq "$want" "$rc" "$msg"
}
out_val() { sed -n "s/^$1=//p" "${RT}/out"; }

# Build a JWT whose payload is real base64url: it carries `-` and `_` and needs `=` padding, which
# is exactly what a naive `base64 -d` gets wrong.
mkjwt() { # <payload-json>
  python3 - "$1" <<'PY'
import base64, sys
def b64(b): return base64.urlsafe_b64encode(b).decode().rstrip("=")
print(".".join([b64(b'{"alg":"RS256"}'), b64(sys.argv[1].encode()), b64(b"not-a-real-signature")]))
PY
}
stub_token() { # <payload-json> -> sets ACTIONS_ID_TOKEN_REQUEST_URL to a file:// stub
  jq -n --arg v "$(mkjwt "$1")" '{value: $v}' > "${RT}/token.json"
  export ACTIONS_ID_TOKEN_REQUEST_URL="file://${RT}/token.json"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="s3cr3t-request-token"
}

echo "checks staging: repo-template itself uses the workspace copy and never asks for a token"
unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN || true
GITHUB_REPOSITORY=Avenue-Z/repo-template resolve "repo-template resolves without an OIDC endpoint" 0
assert_eq "true" "$(out_val local)" "repo-template sets local=true (the workspace copy)"

# A consumer with no token endpoint is a caller that forgot `id-token: write`. It must REFUSE, not
# guess a ref: guessing means staging SOMETHING and reporting a verdict from it.
echo "checks staging: a consumer with no OIDC endpoint refuses"
GITHUB_REPOSITORY=avenue-z-ci-lab/adopter-private resolve "no token endpoint -> REFUSED" 1
assert_match "the refusal names id-token: write so the caller can be fixed" \
  'id-token' "$(cat "${RT}/log")"

echo "checks staging: a consumer reads the ref from the job_workflow_ref CLAIM"
stub_token '{"job_workflow_ref":"Avenue-Z/repo-template/.github/workflows/checks.yml@refs/tags/v1.2.0","workflow_ref":"acme/app/.github/workflows/checks.yml@refs/heads/main"}'
GITHUB_REPOSITORY=acme/app resolve "a valid claim resolves" 0
assert_eq "false" "$(out_val local)" "a consumer sets local=false (stage from the template)"
# The POINT of deriving the ref rather than hardcoding `ref: v1`: pinned at a point tag you get
# that point tag's scripts, so §1's immutable tags are a real rollback for the whole gate.
assert_eq "refs/tags/v1.2.0" "$(out_val ref)" "the ref is the part after '@' of the job_workflow_ref claim"
# workflow_ref is the CALLER's workflow. Reading it would stage the consumer's own tree straight
# back into the job — the attack the staging exists to prevent, wearing the right variable name.
assert_nomatch "the caller's own ref was not used" 'acme/app' "$(out_val ref)"

echo "checks staging: the request token is never printed"
assert_nomatch "no OIDC request token in the step's output" 's3cr3t-request-token' "$(cat "${RT}/log")"
assert_nomatch "no raw JWT in the step's output" 'eyJhbGciOiJSUzI1NiJ9' "$(cat "${RT}/log")"

echo "checks staging: an absent or empty claim refuses"
stub_token '{"workflow_ref":"acme/app/.github/workflows/checks.yml@refs/heads/main"}'
GITHUB_REPOSITORY=acme/app resolve "claim absent -> REFUSED" 1
stub_token '{"job_workflow_ref":""}'
GITHUB_REPOSITORY=acme/app resolve "claim empty -> REFUSED" 1

echo "checks staging: an unusable token response refuses"
jq -n '{message: "not authorized"}' > "${RT}/token.json"
GITHUB_REPOSITORY=acme/app resolve "the endpoint returned no token -> REFUSED" 1
export ACTIONS_ID_TOKEN_REQUEST_URL="file://${RT}/does-not-exist.json"
GITHUB_REPOSITORY=acme/app resolve "the endpoint was unreachable -> REFUSED" 1

# The resolved ref has to be the one the checkout actually uses, and the checkout has to be the one
# that clones the TEMPLATE. Located by `uses:`/`with:`, not by index.
echo "checks staging: the template checkout consumes the resolved ref"
staging_checkout="$(python3 - "$WORKFLOW" <<'PY'
import json, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = d['jobs']['checks']['steps']
s = next((s for s in steps
          if str(s.get('uses', '')).startswith('actions/checkout@')
          and (s.get('with') or {}).get('repository') == 'Avenue-Z/repo-template'), None)
print(json.dumps({} if s is None else {"ref": (s.get('with') or {}).get('ref'), "if": s.get('if')}))
PY
)"
# The single quotes are the point: this is the literal GitHub expression the workflow must carry.
# shellcheck disable=SC2016
assert_eq '${{ steps.scripts_src.outputs.ref }}' "$(jq -r '.ref' <<<"$staging_checkout")" \
  "the template checkout takes its ref from the resolver step's output"
assert_match "the template checkout is skipped on repo-template's own runs" \
  "steps\.scripts_src\.outputs\.local == 'false'" "$(jq -r '.if' <<<"$staging_checkout")"

finish
