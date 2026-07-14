#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

SCRIPT=./scripts/link-vercel.sh

# link-vercel.sh attaches a repo to a DEPLOY TARGET. Two things must hold, forever:
#
#   1. IT NEVER DEPLOYS. Not with a flag, not by accident, not as a "convenience".
#   2. IT NEVER LINKS A REPO WHOSE DEFAULT BRANCH IS NOT `main`.
#
#      Vercel takes its production branch from the repository default branch, and there is NO
#      documented API to set it otherwise. This template's default branch is `main` precisely so
#      that Vercel's default is correct. If someone flips it back to `dev`, then every merge to
#      `dev` deploys straight to PRODUCTION — bypassing staging, inverting the branch flow,
#      silently, with no error. This check is the only thing standing in front of that.
#
# Both are driven with stub `vercel` / `gh` on PATH, so no real API call is ever made.

assert_file "$SCRIPT exists" "$SCRIPT"
assert_ok   "$SCRIPT is executable" test -x "$SCRIPT"

STUB="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "${STUB}" "${WORK}"' EXIT

# Every stub call is logged, so we can prove what was and was not invoked.
export VERCEL_LOG="${STUB}/vercel-calls.log"

make_stubs() { # <default-branch> <production-branch-or-empty>
  local default_branch="$1" prod_branch="$2" inspect_json
  # Build the JSON in the PARENT and embed it whole. Interpolating a pre-quoted value inside the
  # heredoc produced `""dev""` -> `productionBranch:dev`, which is INVALID JSON: jq then returned
  # empty, the script read that as "no override" and exited 0, and the refusal test passed while
  # proving nothing. An invalid fixture is a silently vacuous test.
  # NOGIT models what the REAL API returns for a project with no Git connection: `"link": null`.
  # Verified against a live project — a git-connected project ALWAYS has a populated
  # productionBranch, so `link:null` (NOT a null productionBranch) is the only way the script can
  # see an empty value. The old fixture only ever produced `{"link":{"productionBranch":null}}`,
  # a shape the real API does not emit for a linked project, so the no-git case went untested and
  # the script green-ticked it as "no override — inherits the default branch. Verified."
  if [ "${prod_branch}" = "NOGIT" ]; then
    inspect_json='{"link":null}'
  elif [ -n "${prod_branch}" ]; then
    inspect_json="{\"link\":{\"productionBranch\":\"${prod_branch}\"}}"
  else
    inspect_json='{"link":{"productionBranch":null}}'
  fi
  cat > "${STUB}/vercel" <<STUBEOF
#!/usr/bin/env bash
echo "vercel \$*" >> "${VERCEL_LOG}"
case "\$*" in
  whoami*)  echo "paul@avenuez.com" ;;
  link*)    mkdir -p .vercel; echo '{"projectId":"prj_test123","orgId":"team_test"}' > .vercel/project.json ;;
  deploy*)  echo "FAKE VERCEL: deploy was invoked!" >&2; exit 0 ;;
  *)        echo "fake vercel: unexpected: \$*" >&2; exit 1 ;;
esac
STUBEOF
  # The production-branch check goes over the REST API (the CLI cannot answer — no --json), so the
  # thing to stub is curl, not `vercel project inspect`.
  cat > "${STUB}/curl" <<STUBEOF
#!/usr/bin/env bash
echo "curl \$*" >> "${VERCEL_LOG}"
echo '${inspect_json}'
STUBEOF
  chmod +x "${STUB}/curl"
  cat > "${STUB}/gh" <<STUBEOF
#!/usr/bin/env bash
case "\$*" in
  *defaultBranchRef*) echo "${default_branch}" ;;
  *) echo "fake gh: unexpected: \$*" >&2; exit 1 ;;
esac
STUBEOF
  chmod +x "${STUB}/vercel" "${STUB}/gh"
}

# A minimal repo that looks like an initialised `next` stack.
setup_repo() { # <vercel.json contents>
  rm -rf "${WORK}/repo"; mkdir -p "${WORK}/repo/scripts"
  cp "${REPO_ROOT}/scripts/link-vercel.sh" "${WORK}/repo/scripts/"
  printf '%s\n' "$1" > "${WORK}/repo/vercel.json"
  : > "${VERCEL_LOG}"
}

deployed()  { grep -q '^vercel deploy' "${VERCEL_LOG}" 2>/dev/null; }
linked()    { grep -q '^vercel link'   "${VERCEL_LOG}" 2>/dev/null; }

# link-vercel.sh REQUIRES A TTY (linking a deploy target is a human act, not a pipeline step).
# So a plain `./link-vercel.sh </dev/null` dies at the TTY guard and never reaches the checks
# below — every "it refuses to X" assertion would then pass for the WRONG REASON, proving only
# that the TTY guard works. Run it over a real pty so the refusals are proven by the actual
# default-branch / deploys-off / production-branch checks.
run_linked() { # -> sets $out, returns the script's exit code. No VERCEL_TOKEN: manual-confirm path.
  local typed="${1:-main}"     # what the human types when asked for the production branch
  out="$(pty_run "${typed}" "cd '${WORK}/repo' && PATH='${STUB}:'\"\$PATH\" VERCEL_LOG='${VERCEL_LOG}' ./scripts/link-vercel.sh")"
}

run_linked_token() { # -> sets $out. VERCEL_TOKEN set: the REST-API path, no human prompt.
  out="$(pty_run "" "cd '${WORK}/repo' && PATH='${STUB}:'\"\$PATH\" VERCEL_LOG='${VERCEL_LOG}' VERCEL_TOKEN=tok_test ./scripts/link-vercel.sh")"
}

DEPLOYS_OFF='{"git":{"deploymentEnabled":false}}'
DEPLOYS_ON='{"git":{"deploymentEnabled":true}}'

# ---------------------------------------------------------------------------------------
# THE INVARIANT: this script must not contain a deploy at all. A guard in front of a `vercel
# deploy` that is still present in the file is one edit away from firing.
echo "link-vercel: the script must not invoke 'vercel deploy' ANYWHERE"
src="$(cat "$SCRIPT")"
if grep -qE '^[^#]*vercel +deploy' <<<"$src"; then
  fail "the script invokes 'vercel deploy' — linking must never deploy"
else
  pass "no 'vercel deploy' invocation anywhere in the script"
fi
assert_nomatch "no 'vercel --prod' either" '^[^#]*vercel .*--prod' "$src"

# ---------------------------------------------------------------------------------------
echo "link-vercel: happy path — links, verifies, and deploys NOTHING"
make_stubs "main" ""            # default=main, no production override => inherits main
setup_repo "$DEPLOYS_OFF"
if run_linked; then
  pass "links successfully when default branch is main and deploys are off"
else
  fail "happy path should exit 0. Output: ${out}"
fi
if linked;   then pass "it did run 'vercel link'"; else fail "it never linked"; fi
if deployed; then fail "IT DEPLOYED — linking must never deploy"; else pass "it did NOT deploy"; fi
assert_match "confirms deploys are off" 'NOTHING IS DEPLOYING' "$out"
assert_match "tells you how to enable a deploy (a PR)" 'open a PR' "$out"
assert_match "warns unlisted branches default to TRUE" 'defaults to TRUE' "$out"

# ---------------------------------------------------------------------------------------
# THE BIG ONE. If the default branch is `dev`, Vercel would make `dev` production.
echo "link-vercel: REFUSES to link when the default branch is not 'main' (dev would become production)"
make_stubs "dev" ""
setup_repo "$DEPLOYS_OFF"
if run_linked; then
  fail "linked a repo whose default branch is 'dev' — every merge to dev would deploy to PRODUCTION. Output: ${out}"
else
  pass "refuses to link when the default branch is 'dev' (non-zero exit)"
fi
out_dev="$out"
assert_match "says dev would deploy to production" 'straight to PRODUCTION' "$out_dev"
assert_match "tells you how to fix it" 'gh repo edit --default-branch main' "$out_dev"
if linked;   then fail "it linked anyway"; else pass "nothing was linked"; fi
if deployed; then fail "IT DEPLOYED";      else pass "nothing was deployed"; fi

# ---------------------------------------------------------------------------------------
echo "link-vercel: REFUSES when vercel.json does not disable deploys (linking would start them)"
make_stubs "main" ""
setup_repo "$DEPLOYS_ON"
if run_linked; then
  fail "linked with deploys enabled — this starts deploying on the next push. Output: ${out}"
else
  pass "refuses to link when vercel.json does not disable deployments"
fi
out_on="$out"
assert_match "explains unspecified branches are deployable" 'UNSPECIFIED branch as deployable' "$out_on"
if linked; then fail "it linked anyway"; else pass "nothing was linked"; fi

# ---------------------------------------------------------------------------------------
# An explicit dashboard override WINS over the repo default, so verifying the default is not
# enough. The CLI CANNOT report it (no vercel command has --json — see the contract test at the
# bottom), so the only real check is the documented REST API, behind VERCEL_TOKEN.
#
# The previous version of this script called `vercel project inspect --json`, which the real CLI
# REJECTS as an unknown option. It silently returned nothing, fell through to a warning, and linked
# anyway — a check that could never catch anything. These tests passed because the stub implemented
# a flag that does not exist. That is why the contract test below exists.
echo "link-vercel: with VERCEL_TOKEN — REFUSES a production-branch override that is not 'main'"
make_stubs "main" "dev"         # repo default is fine, but Vercel is overridden to dev
setup_repo "$DEPLOYS_OFF"
if run_linked_token; then
  fail "accepted a Vercel production-branch override of 'dev'. Output: ${out}"
else
  pass "refuses when Vercel's productionBranch override is 'dev'"
fi
out_ovr="$out"
assert_match "names the wrong branch" "production branch is 'dev'" "$out_ovr"
assert_match "says there is no API to fix it, so do it by hand" 'NO supported API' "$out_ovr"
assert_match "actually asked the REST API" 'api\.vercel\.com/v9/projects' "$(cat "${VERCEL_LOG}")"
if deployed; then fail "IT DEPLOYED"; else pass "nothing was deployed"; fi

# ---------------------------------------------------------------------------------------
# A project with NO GIT CONNECTION has `"link": null`, so `.link.productionBranch // empty` is
# EMPTY — the same empty the script used to read as "no override, inherits the default branch:
# Verified." It is not. It is a project with no repo attached, deploying from CLI uploads rather
# than from branches, where the branch-flow guarantee does not exist at all. `vercel link` creates
# exactly this if you answer "no" to "Detected a repository. Connect it to this project?" —
# observed against a real project, where the script printed "Verified." and exited 0.
echo "link-vercel: with VERCEL_TOKEN — REFUSES a project with no Git connection (link:null)"
make_stubs "main" "NOGIT"
setup_repo "$DEPLOYS_OFF"
if run_linked_token; then
  fail "green-ticked a project with NO Git connection — 'I could not check' is not 'it is fine'. Output: ${out}"
else
  pass "refuses a Vercel project that is not connected to a Git repository"
fi
assert_match "says the project has no git repo" 'not connected to any Git repository' "$out"
assert_nomatch "never claims it verified anything" 'Verified' "$out"
if deployed; then fail "IT DEPLOYED"; else pass "nothing was deployed"; fi

echo "link-vercel: with VERCEL_TOKEN — an override of exactly 'main' is accepted"
make_stubs "main" "main"
setup_repo "$DEPLOYS_OFF"
if run_linked_token; then
  pass "accepts an explicit productionBranch of 'main'"
else
  fail "should accept productionBranch=main. Output: ${out}"
fi
assert_match "reports it VERIFIED (machine-checked, not asserted)" "explicitly 'main'. Verified" "$out"

# ---------------------------------------------------------------------------------------
# NO TOKEN: we genuinely cannot check. The old code WARNED and exited 0 — an inert control. Now a
# human must look at the dashboard and type what they see. "I could not check" is not "it is fine".
echo "link-vercel: without VERCEL_TOKEN — a human must confirm the production branch"
make_stubs "main" ""
setup_repo "$DEPLOYS_OFF"
if run_linked "main"; then
  pass "typing 'main' (what the dashboard shows) completes the link"
else
  fail "typing 'main' should succeed. Output: ${out}"
fi
assert_match "admits it could not machine-verify" 'CANNOT VERIFY' "$out"
assert_match "says the confirmation is human, not machine" 'not machine-verified' "$out"
assert_nomatch "never claims it verified anything itself" 'productionBranch is explicitly' "$out"

echo "link-vercel: without VERCEL_TOKEN — typing anything but 'main' ABORTS (it does not just warn)"
make_stubs "main" ""
setup_repo "$DEPLOYS_OFF"
if run_linked "dev"; then
  fail "the human said the dashboard shows 'dev' and the script exited 0 anyway — that is the inert warn-and-carry-on this fix removes. Output: ${out}"
else
  pass "a production branch of 'dev' reported by the human is fatal"
fi
assert_match "warns not to enable deploys" 'Do NOT enable any deploys' "$out"
assert_match "reassures nothing is deploying yet" 'deploymentEnabled: false' "$out"
if deployed; then fail "IT DEPLOYED"; else pass "nothing was deployed"; fi

# ---------------------------------------------------------------------------------------
echo "link-vercel: --dry-run checks everything and links NOTHING"
make_stubs "main" ""
setup_repo "$DEPLOYS_OFF"
if out_dry=$(cd "${WORK}/repo" && PATH="${STUB}:${PATH}" VERCEL_LOG="${VERCEL_LOG}" ./scripts/link-vercel.sh --dry-run </dev/null 2>&1); then
  pass "--dry-run exits 0"
else
  fail "--dry-run should exit 0. Output: ${out_dry}"
fi
if linked;   then fail "--dry-run LINKED";   else pass "--dry-run linked nothing"; fi
if deployed; then fail "--dry-run DEPLOYED"; else pass "--dry-run deployed nothing"; fi

# ---------------------------------------------------------------------------------------
# CONTRACT TEST — does the REAL Vercel CLI actually support what this script invokes?
#
# THIS IS THE TEST THAT WAS MISSING, AND IT IS THE POINT OF THIS FILE.
#
# Every test above drives a STUB. A stub proves the script behaves correctly GIVEN ASSUMED CLI
# BEHAVIOUR — it cannot prove the assumption. The previous version of this script called
# `vercel project inspect --json`, a flag that DOES NOT EXIST. The real CLI rejects it, so the
# production-branch check silently returned nothing, fell through to a warning, and linked anyway:
# a control that could never once have fired. Every stub test passed, because the stub implemented
# the fiction.
#
# So: assert the script's assumptions against the CLI that is actually installed. Skipped (not
# failed) when the CLI is absent, so the suite still runs on a machine without it — but on any
# machine that HAS vercel, a drifted or invented flag fails here instead of in production.
echo "link-vercel: CONTRACT — the real Vercel CLI supports what the script invokes"
if ! command -v vercel >/dev/null 2>&1; then
  echo "  SKIP  the Vercel CLI is not installed — cannot check the script's assumptions against reality"
else
  # 1. Every `vercel <subcommand>` the script calls must exist.
  #    Detect by OUTPUT, not exit code: `vercel link --help` prints perfectly good help and then
  #    exits 2. An exit-code check would have failed a subcommand that plainly works. The banner
  #    line ("▲ vercel <sub>") only appears for a real subcommand — verified that a bogus one does
  #    not produce it, so this check discriminates rather than passing on everything.
  #    Capture FIRST, then match. `set -o pipefail` is on, and `vercel link --help` exits 2 while
  #    printing perfectly good help — piping it straight into grep makes the pipeline inherit that
  #    2 and the check fails on a subcommand that plainly works.
  for sub in whoami link; do
    help_out="$(vercel "$sub" --help 2>&1 || true)"
    if grep -q "vercel ${sub}" <<<"$help_out"; then
      pass "the real CLI has 'vercel $sub'"
    else
      fail "the script calls 'vercel $sub', but the installed CLI does not support it"
    fi
  done

  # 2. The script must NOT depend on a --json flag from any vercel command, because none has one.
  #    This is the exact assumption that was false. If a future Vercel adds --json, this test fails
  #    loudly and someone can simplify the script — which is the right way to find out.
  if grep -qE '^[^#]*vercel [a-z ]+--json' "$SCRIPT"; then
    fail "the script expects a vercel --json flag. No vercel command emits JSON — this is how the production-branch check silently became a no-op before."
  else
    pass "the script does not rely on a vercel --json flag (no vercel command has one)"
  fi

  # 3. Belt and braces: confirm the CLI really has no --json on the command someone would reach for.
  inspect_help="$(vercel project inspect --help 2>&1 || true)"
  if grep -q -- '--json' <<<"$inspect_help"; then
    fail "'vercel project inspect' NOW supports --json — the REST-API workaround in this script can be simplified, and this test should be updated"
  else
    pass "confirmed: 'vercel project inspect' still has no --json (the REST-API path is still required)"
  fi
fi

finish
