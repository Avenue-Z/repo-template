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
  if [ -n "${prod_branch}" ]; then
    inspect_json="{\"link\":{\"productionBranch\":\"${prod_branch}\"}}"
  else
    inspect_json='{"link":{"productionBranch":null}}'
  fi
  cat > "${STUB}/vercel" <<STUBEOF
#!/usr/bin/env bash
echo "vercel \$*" >> "${VERCEL_LOG}"
case "\$*" in
  whoami*)          echo "paul@avenuez.com" ;;
  link*)            mkdir -p .vercel; echo '{"projectId":"prj_test123","orgId":"team_test"}' > .vercel/project.json ;;
  "project inspect"*) echo '${inspect_json}' ;;
  deploy*)          echo "FAKE VERCEL: deploy was invoked!" >&2; exit 0 ;;
  *)                echo "fake vercel: unexpected: \$*" >&2; exit 1 ;;
esac
STUBEOF
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
run_linked() { # -> sets $out, returns the script's exit code
  out="$(pty_run "" "cd '${WORK}/repo' && PATH='${STUB}:'\"\$PATH\" VERCEL_LOG='${VERCEL_LOG}' ./scripts/link-vercel.sh")"
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
# enough — we must ask Vercel what it actually thinks, and refuse a wrong answer.
echo "link-vercel: REFUSES when Vercel has an explicit production-branch override that is not 'main'"
make_stubs "main" "dev"         # repo default is fine, but Vercel is overridden to dev
setup_repo "$DEPLOYS_OFF"
if run_linked; then
  fail "accepted a Vercel production-branch override of 'dev'. Output: ${out}"
else
  pass "refuses when Vercel's productionBranch override is 'dev'"
fi
out_ovr="$out"
assert_match "names the wrong branch" "production branch is 'dev'" "$out_ovr"
assert_match "says there is no API to fix it, so do it by hand" 'NO supported API' "$out_ovr"
if deployed; then fail "IT DEPLOYED"; else pass "nothing was deployed"; fi

# ---------------------------------------------------------------------------------------
echo "link-vercel: an explicit production override of exactly 'main' is accepted"
make_stubs "main" "main"
setup_repo "$DEPLOYS_OFF"
if run_linked; then
  pass "accepts an explicit productionBranch of 'main'"
else
  fail "should accept productionBranch=main. Output: ${out}"
fi
out_ok="$out"
assert_match "reports it verified the explicit override" "explicitly 'main'" "$out_ok"

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

finish
