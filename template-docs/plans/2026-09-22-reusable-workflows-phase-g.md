# Reusable Workflows — Phase G Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the Python stack's CI as a reusable workflow, `python-ci.yml`, behind its own
moving tag `python-ci-v1`. Test one Python version by default. Make the Python template's own
`ci.yml` a caller of it, so a CI fix made in `repo-template` reaches every Python repo without a PR
in each one.

**Architecture:** `python-ci.yml` is a template-only `workflow_call` workflow with one job, `test`.
Its matrix is whatever the caller lists: an app lists the single version its Dockerfile deploys on,
and a library lists every version it supports. It stages `bandit-gate.sh` and
`ci-aggregate-gate.sh` from the template at the ref it was called at, reusing `checks.yml`'s OIDC
resolver verbatim. The caller keeps a small `ci` aggregate job, so the required context stays
literally `ci`. The contract golden, the self-call and the tag advance are each extended to cover the
second workflow rather than duplicated.

**Tech Stack:** GitHub Actions (`workflow_call`, `workflow_run`, OIDC `job_workflow_ref` claim),
bash 3.2+, `jq`, `python3` + PyYAML (test-side parsing), GitHub rulesets via `gh api`.

**Spec:** `template-docs/specs/2026-09-09-reusable-workflows-design.md` — §4 (gating an advance),
§5 (job count), §6 (`python-ci.yml`, including "Decisions before G starts"). Read §2 too: this plan
reuses its staging mechanism unchanged.

**Scope:** Phase G only. Everything happens inside `repo-template` plus a proof run in the lab org
`avenue-z-ci-lab`. **No existing Avenue-Z repo is migrated.** That is B–E, which stay blocked on
billing. Node and next stacks are untouched.

---

## Decisions this plan makes

The spec leaves these open or says something different. Each one is stated here so a reviewer can
reject it on its own.

- **D1 — one Python version by default, from the Dockerfile.** This replaces spec decision 2 ("one
  version on PRs, full matrix somewhere else"). An app ships one image and runs one Python, so it
  tests that version only. A library that other repos install lists every version it supports. The
  `python-versions` input is **required and has no default**, so the version sits in the caller
  next to the Dockerfile that sets it, and a test asserts they match (Task 8). A shared default
  would put every repo's Python version in `repo-template`, and bumping it would be a clause-3 break
  (§1). Task 1 writes this into the spec.
- **D2 — tag names.** `python-ci-v1` moves; the immutable point tags are `python-ci-v1.N.0`. This is
  spec decision 1 (its own tag), with the name chosen.
- **D3 — a `working-directory` input (default `.`).** It exists so the layer-2 self-call can run
  against `templates/python`: `repo-template`'s root has no Python project. Callers never set it.
- **D4 — Bandit runs in the first matrix leg only.** For an app that is its only leg. For a library,
  running SAST three times over the same source adds nothing.
- **D5 — the caller's `ci` aggregate is a `jq` one-liner over `toJSON(needs)`,** with no script and
  no action. The caller then has nothing to pin and nothing for Dependabot to bump. Per-repo extras
  (e.g. `dbt-parse`) are added to `needs:` and are gated automatically.
- **D6 — `python-ci.yml` is template-only.** `on:` is `workflow_call` alone, and `init-repo.sh`
  deletes it from generated repos, the same way it deletes `advance-v1.yml`.
- **D7 — one advance workflow over both tags.** `advance-v1.yml` gets a two-row matrix instead of a
  copy (spec decision 1: "parameterised rather than duplicated"). The file keeps its name, because
  notes, PRs and the tag app already refer to it.
- **D8 — the OIDC resolver is copied, and a test enforces the copy.** A composite action cannot share
  it: loading the action needs the very ref the resolver computes. The resolver's `run:` is kept
  byte-identical to `checks.yml`'s, and `test_python_ci.sh` fails on any difference, so
  `test_checks_staging.sh`'s behavioural coverage applies to both.

**Out of scope:** the §5 `concurrency` block, pip caching, an `install-command` input (add one in a
migration phase if a repo needs it), and Open item 15 (SCA on lockfile-less Python repos).

**What this does to job count, stated honestly:** a Python PR goes from 4 billed jobs (3 matrix legs +
`ci`) to 2 (`python-ci / test (3.11)` + `ci`). The `ci` job now does no work of its own; it exists
to own the stable context. That is the cost of keeping the required context `ci` (§6), and 2 jobs
is §5's target.

---

## Global Constraints

- Pinned actions, copied exactly:
  `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`,
  `actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065 # v5.6.0`.
  `test_action_pins.sh` rejects anything else.
- Bandit pin: `bandit==1.9.4` (same as today's `templates/python/.github/workflows/ci.yml`).
- Every Python version is a **quoted string** in JSON (`"3.10"`, not `3.10`, which parses as 3.1).
- Every `${{ }}` value used in a shell body goes through `env:`, never inline into `run:`, following
  the rule `checks.yml` states.
- Bash 3.2-compatible scripts; new and changed `.sh` files must pass `template-tests/test_shellcheck.sh`.
- New suites source `template-tests/lib.sh`, `cd "$(dirname "$0")/.."`, and end with `finish`.
- Comment style follows the repo: say *why*, put CAPS on the load-bearing word, and cite run ids for
  anything measured.
- Branches: `feat/python-ci-reusable` (PR 1) and `feat/python-ci-caller` (PR 2), both off `dev`,
  both PRs to `dev`. Never push to `main`. **Merging and each promotion (`dev → staging → main`) need
  the user's explicit go-ahead.**
- The full suite, used as "run everything" below:

  ```bash
  failed=0; for t in template-tests/test_*.sh; do bash "$t" >/dev/null 2>&1 || { echo "FAILED: $t"; failed=1; }; done; [ "$failed" -eq 0 ] && echo "all suites passed"
  ```

---

## File map

| File | PR | Change |
|---|---|---|
| `template-docs/specs/2026-09-09-reusable-workflows-design.md` | 1 | Record D1 (replaces decision 2) and the tag name |
| `.github/workflows/python-ci.yml` | 1 | **New.** The reusable workflow |
| `.github/workflows/checks.yml` | 1 | One refusal message made caller-neutral (D8); no contract change |
| `.github/reusable-contract-python-ci.json` | 1 | **New.** Golden surface for `python-ci.yml` |
| `.github/workflows/template-tests.yml` | 1 | New layer-2 job `self-call-python-ci` |
| `.github/workflows/advance-v1.yml` | 1 | Matrix over `v1` and `python-ci-v1` |
| `scripts/init-repo.sh` | 1 | Delete `python-ci.yml` and its golden from generated repos |
| `template-tests/test_python_ci.sh` | 1, 2 | **New.** Structure, resolver identity, verdict behaviour; caller (PR 2) |
| `template-tests/test_reusable_contract.sh` | 1 | Checks both workflows against their goldens |
| `template-tests/test_advance_v1.sh` | 1 | Drives the decide and move steps per tag |
| `template-tests/test_init_repo.sh` | 1 | Asserts the two new template-only files do not ship |
| `templates/python/.github/workflows/ci.yml` | 2 | Becomes a caller of `python-ci.yml@python-ci-v1` |
| `template-tests/test_bandit.sh` | 2 | Wiring assertions move to `python-ci.yml` |
| `scripts/apply-rulesets.sh` | 2 | Refuses a python-ci caller job without `id-token: write` |
| `template-tests/test_apply_rulesets.sh` | 2 | Covers that refusal |
| `docs/notes/2026-09-XX-phase-g-lab-proof.md` | 2 | **New.** Lab run ids and results |

---

### Task 0: Baseline

- [ ] **Step 1:** `git switch dev && git pull --ff-only && git switch -c feat/python-ci-reusable`
- [ ] **Step 2:** Run everything (Global Constraints). Expected: `all suites passed`. If any suite
  fails on `dev` before you touch anything, stop and report it. Do not build on a red baseline.
- [ ] **Step 3:** Prove the Python template passes its own gate locally. Layer 2 (Task 4) runs this
  in CI, and it has never run anywhere before:

  ```bash
  V="$(mktemp -d)/venv"; python3.11 -m venv "$V" && (cd templates/python && "$V/bin/pip" install -q -e ".[dev]" && PATH="$V/bin:$PATH" make check)
  ```

  Expected: ruff, mypy and pytest all pass. If `python3.11` is missing, use any 3.11+. If it fails,
  fix the template first, in a separate commit on this branch, with a message saying why.

---

### Task 1: Record the single-version decision in the spec

**Files:**
- Modify: `template-docs/specs/2026-09-09-reusable-workflows-design.md` (§5 table note, §6 input
  example, "Decisions before G starts" item 2)

- [ ] **Step 1:** In §6, replace the `with:` example block and the sentence introducing it with:

  ````markdown
  The input surface is small, because variation is only the three axes of established fact 10:

  ```yaml
  with:
    python-versions: '["3.11"]'  # REQUIRED. An app: the one version its Dockerfile deploys on.
                                 # A library: every version it supports.
    check-command: make check    # lets the 3 laggards migrate on their own clock
    run-bandit: true             # covers az-* and noble-clone until they catch up
  ```

  `python-versions` has no default on purpose (decision 2 below): the version belongs next to the
  Dockerfile that fixes it, not in `repo-template`, where bumping a shared default would be a clause-3
  break for every caller at once.
  ````

- [ ] **Step 2:** Replace decision 2 under "Decisions before G starts" with:

  ```markdown
  2. **The matrix — revised 2026-09-22: one version, the deployed one; no matrix for apps.** An
     earlier version of this item accepted one version on PRs and left open where the full matrix
     would run. The question dissolved on inspection: an app ships one image and runs exactly one
     Python (the template's is `python:3.11-slim`), so the other matrix legs tested versions that
     never run in production. The caller now lists the version its Dockerfile deploys on, and
     `test_python_ci.sh` asserts the two agree. A library installed by other repos (e.g.
     `glean-chat-api-client`) lists every version it supports and gets the matrix. The cost: a repo
     that bumps its Dockerfile's Python finds breakage on that PR rather than earlier — which, for an
     app, is when it matters. Tag name, per decision 1: `python-ci-v1`, point tags `python-ci-v1.N.0`.
  ```

- [ ] **Step 3:** Under §5's table, add one sentence after "Combined (5 jobs → 2)":

  ```markdown
  (Superseded in part by §6 decision 2: apps run no matrix at all, on PRs or anywhere else, so the
  "full matrix on push to `dev`" half of the first row no longer exists.)
  ```

- [ ] **Step 4:** Run `bash template-tests/test_contracts_docs.sh`. Expected: PASS.
- [ ] **Step 5:** Commit.

  ```bash
  git add template-docs/specs/2026-09-09-reusable-workflows-design.md
  git commit -m "docs: Phase G tests one Python version, the deployed one"
  ```

---

### Task 2: `python-ci.yml`, its suite, and keeping it out of generated repos

**Files:**
- Create: `.github/workflows/python-ci.yml`
- Create: `template-tests/test_python_ci.sh`
- Modify: `.github/workflows/checks.yml` (one `echo` line in the `scripts_src` step)
- Modify: `scripts/init-repo.sh:432`
- Modify: `template-tests/test_init_repo.sh:103-104`

**Interfaces:**
- Produces: workflow `python-ci.yml` with `on.workflow_call.inputs` = `python-versions` (string,
  required), `check-command` (string, default `make check`), `run-bandit` (boolean, default `true`),
  `working-directory` (string, default `.`); one job `test`; step ids `scripts_src`, `check`,
  `bandit`; a step named `verdict`. Tasks 3, 4, 5 and 8 rely on these exact names.

- [ ] **Step 1: Write the failing suite.** Create `template-tests/test_python_ci.sh`:

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  cd "$(dirname "$0")/.."
  # shellcheck source=template-tests/lib.sh disable=SC1091
  source template-tests/lib.sh

  WORKFLOW=.github/workflows/python-ci.yml
  CHECKS=.github/workflows/checks.yml

  # python-ci.yml IS EVERY PYTHON REPO'S CI, ONCE THE FLEET MIGRATES. A bad advance of python-ci-v1
  # reddens `ci` in every Python repo at once, which is a larger blast radius than checks.yml's (spec
  # §6). So this suite asserts STRUCTURE from the parsed YAML, never by grepping the file, and DRIVES
  # the verdict step for real, the way test_checks_verdict.sh drives checks.yml's.
  #
  # Steps are located by `id:` or `name:`, never by index.

  echo "python-ci: the workflow exists"
  assert_file "$WORKFLOW exists" "$WORKFLOW"

  facts="$(python3 - "$WORKFLOW" "$CHECKS" <<'PY'
  import json, sys, yaml
  wf = yaml.safe_load(open(sys.argv[1]))
  checks = yaml.safe_load(open(sys.argv[2]))
  on = wf.get('on', wf.get(True)) or {}
  call = (on.get('workflow_call') or {}) if isinstance(on, dict) else {}
  job = (wf.get('jobs') or {}).get('test') or {}
  steps = job.get('steps') or []
  by_id = {s['id']: s for s in steps if 'id' in s}
  by_name = {s['name']: s for s in steps if 'name' in s}
  cres = next((s for s in checks['jobs']['checks']['steps'] if s.get('id') == 'scripts_src'), {})
  tco = next((s for s in steps if str(s.get('uses', '')).startswith('actions/checkout@')
              and (s.get('with') or {}).get('repository')), {})
  strip = lambda e: str(e).strip().removeprefix('${{').removesuffix('}}').strip()
  print(json.dumps({
      "on": sorted(on) if isinstance(on, dict) else [],
      "inputs": call.get('inputs') or {},
      "perms": wf.get('permissions'),
      "jobs": sorted(wf.get('jobs') or {}),
      "job_has_perms": 'permissions' in job,
      "fail_fast": (job.get('strategy') or {}).get('fail-fast'),
      "matrix": ((job.get('strategy') or {}).get('matrix') or {}).get('python-version'),
      "resolver_identical": bool(cres.get('run')) and by_id.get('scripts_src', {}).get('run') == cres.get('run'),
      "tco": {"if": tco.get('if'), **(tco.get('with') or {})},
      "stage": by_name.get('Stage the trusted scripts outside the workspace', {}),
      "check": by_id.get('check', {}),
      "bandit": by_id.get('bandit', {}),
      "install_bandit_if": strip(by_name.get('install bandit', {}).get('if', '')),
      "bandit_if": strip(by_id.get('bandit', {}).get('if', '')),
      "verdict": by_name.get('verdict', {}),
      "verdict_bandit_expected": strip((by_name.get('verdict', {}).get('env') or {}).get('BANDIT_EXPECTED', '')),
  }))
  PY
  )"
  f() { jq -c "$1" <<<"$facts"; }
  fr() { jq -r "$1" <<<"$facts"; }

  echo "python-ci: it is a template-only reusable workflow"
  # workflow_call ALONE. This file never runs in repo-template except through the self-call, and
  # init-repo.sh deletes it from every generated repo — a generated repo gets a caller (spec §6, D6).
  assert_eq '["workflow_call"]' "$(f .on)" "on: is exactly workflow_call"

  echo "python-ci: the input surface"
  # python-versions is REQUIRED WITH NO DEFAULT (D1): the version lives in the caller, beside the
  # Dockerfile that fixes it. A default here would put every repo's Python version in repo-template.
  assert_eq '{"required":true,"type":"string"}' "$(f '.inputs["python-versions"]|{required,type,default}|with_entries(select(.value!=null))')" \
    "python-versions is a required string with no default"
  assert_eq '{"default":"make check","required":false,"type":"string"}' "$(f '.inputs["check-command"]|{default,required,type}')" \
    "check-command defaults to 'make check'"
  assert_eq '{"default":true,"required":false,"type":"boolean"}' "$(f '.inputs["run-bandit"]|{default,required,type}')" \
    "run-bandit is a boolean defaulting to true"
  assert_eq '{"default":".","required":false,"type":"string"}' "$(f '.inputs["working-directory"]|{default,required,type}')" \
    "working-directory defaults to '.' (only the self-call sets it)"
  assert_eq '["check-command","python-versions","run-bandit","working-directory"]' "$(f '.inputs|keys')" \
    "no input beyond those four (a new one moves the contract; see test_reusable_contract.sh)"

  echo "python-ci: permissions"
  # id-token: write for the same reason checks.yml has it: the resolver reads the OIDC claim. It must
  # be declared HERE — a called workflow that declares less REDUCES the caller's grant to none.
  assert_eq '{"contents":"read","id-token":"write"}' "$(f '.perms')" "workflow grants contents: read + id-token: write"
  assert_eq "false" "$(f .job_has_perms)" "the test job has NO permissions block (it would REPLACE the workflow's)"

  echo "python-ci: one job, and the matrix is the caller's list"
  assert_eq '["test"]' "$(f .jobs)" "exactly one job, 'test'"
  assert_eq '${{ fromJSON(inputs.python-versions) }}' "$(fr .matrix)" "the matrix is fromJSON(inputs.python-versions)"
  assert_eq "false" "$(f .fail_fast)" "fail-fast: false (a library sees every broken version, not the first)"

  echo "python-ci: the gate scripts come from the template, exactly as checks.yml gets them"
  # D8. The resolver cannot be shared through a composite action (loading one needs the ref this step
  # computes), so it is COPIED. Identity is asserted, which makes test_checks_staging.sh's behavioural
  # coverage — the stubbed OIDC endpoint, the base64url decode, every refusal — cover this copy too.
  assert_eq "true" "$(f .resolver_identical)" "the scripts_src resolver is byte-identical to checks.yml's"
  assert_eq "steps.scripts_src.outputs.local == 'false'" "$(fr '.tco.if')" "the template checkout is skipped on repo-template's own runs"
  assert_eq "Avenue-Z/repo-template" "$(fr '.tco.repository')" "the template checkout reads Avenue-Z/repo-template"
  assert_eq '${{ steps.scripts_src.outputs.ref }}' "$(fr '.tco.ref')" "the template checkout uses the resolved ref"
  assert_eq "false" "$(f '.tco["persist-credentials"]')" "the template checkout does not persist credentials"
  stage_run="$(fr '.stage.run // ""')"
  assert_match "staging stages bandit-gate.sh and ci-aggregate-gate.sh" 'for s in bandit-gate\.sh ci-aggregate-gate\.sh; do' "$stage_run"
  assert_match "staging deletes the checked-out template before anything scans the tree" 'rm -rf \.trusted-template' "$stage_run"
  # The job's default working-directory is inputs.working-directory. Staging must run at the workspace
  # ROOT anyway, because `scripts/` and `.trusted-template` are there.
  assert_eq '${{ github.workspace }}' "$(fr '.stage["working-directory"] // ""')" "staging runs at the workspace root"

  echo "python-ci: the gates"
  assert_eq "true" "$(f '.check["continue-on-error"]')" "the check step is continue-on-error (the verdict decides)"
  assert_eq '${{ inputs.check-command }}' "$(fr '.check.env.CHECK_COMMAND // ""')" "the check command arrives through env, not inline"
  assert_eq "true" "$(f '.bandit["continue-on-error"]')" "the bandit step is continue-on-error (the verdict decides)"
  # D4, and the anti-drift half of it: the three places that decide "does bandit run in this leg" are
  # one expression, compared as strings. If they drift, a leg can skip bandit while the verdict still
  # expects it (red for no reason) or run it while the verdict ignores it (a finding goes GREEN).
  want_if='inputs.run-bandit && matrix.python-version == fromJSON(inputs.python-versions)[0]'
  assert_eq "$want_if" "$(fr .bandit_if)" "bandit runs only when enabled and only in the first listed version"
  assert_eq "$want_if" "$(fr .install_bandit_if)" "the bandit install uses the same condition"
  assert_eq "$want_if" "$(fr .verdict_bandit_expected)" "the verdict expects bandit under exactly that condition"
  bandit_run="$(fr '.bandit.run // ""')"
  assert_match "bandit is judged by the STAGED gate script" '"\$\{RUNNER_TEMP\}/trusted-scripts/bandit-gate\.sh"' "$bandit_run"
  assert_nomatch "bandit never runs the workspace copy of the gate" '(^|[^-])scripts/bandit-gate\.sh' "$bandit_run"
  assert_match "the tier comes from the repo ROOT's policy file, whatever the working directory" \
    '\$\{GITHUB_WORKSPACE\}/\.github/sca-policy\.json' "$bandit_run"

  echo "python-ci: the dead context field is not read anywhere"
  assert_nomatch "no step reads github.job_workflow_ref (that context is ALWAYS empty)" \
    'github\.job_workflow_ref' "$(python3 -c 'import yaml,sys; print(yaml.safe_dump(yaml.safe_load(open(sys.argv[1]))))' "$WORKFLOW")"

  # ---------------------------------------------------------------------------------------
  # THE VERDICT IS THE ONLY THING THAT FAILS THE JOB. Every gate runs under continue-on-error, so a
  # broken verdict turns every failure GREEN. Drive the real step against the outcomes a leg produces.
  echo "python-ci verdict: driven against every outcome a leg can produce"
  VERDICT="$(mktemp)"; RT="$(mktemp -d)"; trap 'rm -f "${VERDICT}"; rm -rf "${RT}"' EXIT
  fr '.verdict.run // ""' > "$VERDICT"
  assert_eq "always()" "$(fr '.verdict.if // ""')" "the verdict runs even after a step errored outright"
  mkdir -p "${RT}/trusted-scripts"
  install -m 0755 scripts/ci-aggregate-gate.sh "${RT}/trusted-scripts/"

  verdict_rc() { # <check> <bandit-outcome> <bandit-expected> [<runner-temp>]
    local rc=0
    CHECK_RESULT="$1" BANDIT_RESULT="$2" BANDIT_EXPECTED="$3" RUNNER_TEMP="${4:-$RT}" \
      bash "$VERDICT" >/dev/null 2>&1 || rc=$?
    echo "$rc"
  }
  assert_eq 0 "$(verdict_rc success success true)"   "check ok, bandit ok -> green"
  assert_eq 1 "$(verdict_rc failure success true)"   "check failed -> red"
  assert_eq 1 "$(verdict_rc success failure true)"   "bandit failed -> red"
  assert_eq 1 "$(verdict_rc success skipped true)"   "bandit expected but skipped -> red (a gate that did not run has not passed)"
  assert_eq 0 "$(verdict_rc success skipped false)"  "bandit not expected in this leg, skipped -> green"
  assert_eq 1 "$(verdict_rc skipped skipped false)"  "check skipped (the install died) -> red"
  assert_eq 1 "$(verdict_rc success success true "$(mktemp -d)")" "no staged verdict script -> red, never a fallback"

  finish
  ```

- [ ] **Step 2: Run it and watch it fail.** `bash template-tests/test_python_ci.sh`
  Expected: `FAIL python-ci.yml exists` and a non-zero exit (jq/python errors after that are
  expected while the file is missing).

- [ ] **Step 3: Make the resolver's refusal caller-neutral.** In `.github/workflows/checks.yml`,
  inside the `scripts_src` step, change the single line

  ```
              echo "::error::no OIDC token endpoint in this job — the calling repository must grant 'permissions: id-token: write' on its 'checks' job. Refusing to stage gate scripts from an unknown ref"
  ```

  to

  ```
              echo "::error::no OIDC token endpoint in this job — the calling repository must grant 'permissions: id-token: write' on the job that calls this workflow. Refusing to stage gate scripts from an unknown ref"
  ```

  This is message text only, so the contract doesn't move. `test_checks_staging.sh` matches
  `id-token` and still passes.

- [ ] **Step 4: Write the workflow.** Create `.github/workflows/python-ci.yml`. The `run:` body of
  `scripts_src` is marked below. **Paste it from `checks.yml` after Step 3; do not retype it.** The
  suite compares the two byte for byte.

  ```yaml
  name: python-ci

  # THE PYTHON STACK'S CI, AS A REUSABLE WORKFLOW. Every Python repo's ci.yml is a caller of this file
  # at the moving tag python-ci-v1, so a fix here reaches all of them with no PR anywhere — including
  # the pinned action SHAs below, which Dependabot now bumps ONCE instead of once per repo (spec §6).
  #
  # THIS FILE IS TEMPLATE-ONLY. scripts/init-repo.sh deletes it; a generated repo gets the caller in
  # templates/python/.github/workflows/ci.yml instead. test_init_repo.sh asserts the removal.
  #
  # ONE VERSION BY DEFAULT (spec §6, decision 2). An app ships one image and runs one Python, so its
  # caller lists that version and nothing else. A library installed by other repos lists every version
  # it supports and gets a real matrix. There is no default list, on purpose: the version belongs in
  # the caller, beside the Dockerfile that fixes it.

  on:
    # workflow_call ALONE. No pull_request, no push: triggers cannot propagate through a call (a called
    # workflow does not define `on:` for its consumers), so they live in each caller. The consumer-
    # visible surface below is recorded in .github/reusable-contract-python-ci.json and asserted by
    # template-tests/test_reusable_contract.sh; changing it refuses the next python-ci-v1 advance.
    workflow_call:
      inputs:
        python-versions:
          description: 'JSON list of QUOTED version strings. An app: the one version its Dockerfile deploys on, e.g. ["3.11"]. A library: every version it supports.'
          type: string
          required: true
        check-command:
          description: 'The correctness gate. `make check` runs ruff + mypy + pytest in the template.'
          type: string
          required: false
          default: make check
        run-bandit:
          description: 'Run Bandit SAST, gated by the tier in .github/sca-policy.json.'
          type: boolean
          required: false
          default: true
        working-directory:
          description: 'Where the Python project lives. Only the self-call sets this; repo-template keeps its Python template in templates/python.'
          type: string
          required: false
          default: '.'

  # contents: read — this job builds and tests; it never writes to the repo.
  # id-token: write — NOT a widening for the sake of it. The resolver below reads the ref this
  # workflow was called at from the OIDC token's job_workflow_ref claim, exactly as checks.yml does,
  # and minting that token needs this. It must be declared HERE as well as in the caller: permissions
  # along a call chain are maintained or reduced, never elevated.
  permissions:
    contents: read
    id-token: write

  jobs:
    test:
      runs-on: ubuntu-latest
      strategy:
        # A library wants to see EVERY broken version, not only the first one to fail.
        fail-fast: false
        matrix:
          python-version: ${{ fromJSON(inputs.python-versions) }}
      defaults:
        run:
          working-directory: ${{ inputs.working-directory }}
      steps:
        - name: Checkout the tree under review
          uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

        # COPIED FROM checks.yml, BYTE FOR BYTE, AND A TEST HOLDS IT THERE (test_python_ci.sh). It cannot
        # be shared through a composite action: loading one needs the very ref this step computes. Read
        # checks.yml's comment on this step for why it is an OIDC claim and not a ${{ }} context read.
        - name: Resolve where the gate scripts come from
          id: scripts_src
          run: |
            # >>> PASTE the scripts_src `run:` body from .github/workflows/checks.yml here, unchanged. <<<

        - name: Check out the template at the ref this workflow was called at
          if: steps.scripts_src.outputs.local == 'false'
          uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
          with:
            repository: Avenue-Z/repo-template
            ref: ${{ steps.scripts_src.outputs.ref }}
            persist-credentials: false
            path: .trusted-template

        # At the workspace ROOT, not the job's working-directory: `scripts/` (repo-template's own runs)
        # and `.trusted-template` (everyone else's) both live there.
        - name: Stage the trusted scripts outside the workspace
          working-directory: ${{ github.workspace }}
          env:
            LOCAL_SRC: ${{ steps.scripts_src.outputs.local }}
          run: |
            set -euo pipefail
            src=scripts
            [ "${LOCAL_SRC}" = "true" ] || src=.trusted-template/scripts
            mkdir -p "${RUNNER_TEMP}/trusted-scripts"
            for s in bandit-gate.sh ci-aggregate-gate.sh; do
              [ -f "${src}/${s}" ] || { echo "::error::${src}/${s} is missing — refusing to run a gate with no script"; exit 1; }
              install -m 0755 "${src}/${s}" "${RUNNER_TEMP}/trusted-scripts/"
            done
            # Delete the checked-out template before anything else reads the tree, for the reason
            # checks.yml gives: a second tree inside the workspace gets scanned as if it were the repo's.
            rm -rf .trusted-template

        - uses: actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065 # v5.6.0
          with:
            python-version: ${{ matrix.python-version }}

        # NOT a gate and not continue-on-error: if the install dies, the check below is SKIPPED, and the
        # verdict reads `skipped` as a failure. One red, for the real reason, in the log.
        - run: pip install -e ".[dev]"

        # The caller supplies this command in its own workflow file, which is the caller's own code;
        # it goes through env so the value is never spliced into the script text.
        - name: 'gate: the check command'
          id: check
          continue-on-error: true
          env:
            CHECK_COMMAND: ${{ inputs.check-command }}
          run: |
            set -euo pipefail
            eval "${CHECK_COMMAND}"

        # FIRST LEG ONLY (D4). An app has one leg; a library gains nothing by running pattern SAST over the
        # same source once per interpreter. The SAME expression appears on the next step and on the
        # verdict's BANDIT_EXPECTED, and test_python_ci.sh asserts all three are identical.
        - name: install bandit
          if: inputs.run-bandit && matrix.python-version == fromJSON(inputs.python-versions)[0]
          run: pip install "bandit==1.9.4"

        - name: 'gate: run Bandit and apply the policy'
          id: bandit
          if: inputs.run-bandit && matrix.python-version == fromJSON(inputs.python-versions)[0]
          continue-on-error: true
          run: |
            set -euo pipefail
            # Bandit exits 1 on ANY finding and 0 when clean; neither is the verdict (bandit-gate.sh
            # applies the tier). Anything else is a real Bandit error — refuse to call that clean.
            rc=0
            bandit -c pyproject.toml -r src -f json -o bandit.json || rc=$?
            case "${rc}" in
              0|1) ;;
              *) echo "::error::bandit exited ${rc} (not a clean/found-issues code) — failed scan, refusing to report a clean check"; exit "${rc}" ;;
            esac
            # The tier file is at the REPO ROOT whatever the working directory is.
            "${RUNNER_TEMP}/trusted-scripts/bandit-gate.sh" bandit.json "${GITHUB_WORKSPACE}/.github/sca-policy.json"

        # THE ONLY THING THAT FAILS THIS JOB. Every gate above recorded an outcome instead of ending the
        # run; this step reads them through the staged ci-aggregate-gate.sh, the same "anything that is
        # not exactly 'success' fails" rule every other verdict in this template uses. A skipped bandit
        # counts only in the leg where it was supposed to run.
        - name: verdict
          if: always()
          env:
            CHECK_RESULT: ${{ steps.check.outcome }}
            BANDIT_RESULT: ${{ steps.bandit.outcome }}
            BANDIT_EXPECTED: ${{ inputs.run-bandit && matrix.python-version == fromJSON(inputs.python-versions)[0] }}
          run: |
            set -euo pipefail
            GATE="${RUNNER_TEMP}/trusted-scripts/ci-aggregate-gate.sh"
            [ -x "${GATE}" ] || { echo "::error::the trusted verdict script is missing — refusing to report a verdict"; exit 1; }
            args=( "check:${CHECK_RESULT}" )
            [ "${BANDIT_EXPECTED}" != "true" ] || args+=( "bandit:${BANDIT_RESULT}" )
            "${GATE}" "${args[@]}"
  ```

- [ ] **Step 5: Run the suite.** `bash template-tests/test_python_ci.sh`
  Expected: `ALL PASS`. If `the scripts_src resolver is byte-identical` fails, compare the two
  bodies. The usual cause is a retyped line or a changed indent:
  `diff <(python3 -c 'import yaml;print(next(s for s in yaml.safe_load(open(".github/workflows/checks.yml"))["jobs"]["checks"]["steps"] if s.get("id")=="scripts_src")["run"])') <(python3 -c 'import yaml;print(next(s for s in yaml.safe_load(open(".github/workflows/python-ci.yml"))["jobs"]["test"]["steps"] if s.get("id")=="scripts_src")["run"])')`

- [ ] **Step 6: Prove the verdict assertions can fail.** Temporarily delete the line
  `[ "${BANDIT_EXPECTED}" != "true" ] || args+=( "bandit:${BANDIT_RESULT}" )` from `python-ci.yml`
  and re-run the suite. Expected: `bandit failed -> red` and `bandit expected but skipped -> red`
  both FAIL. Restore the line and confirm `ALL PASS` again.

- [ ] **Step 7: Keep it out of generated repos. First the failing test.** In
  `template-tests/test_init_repo.sh`, after the line
  `assert_no_file "the v1 advance workflow did not ship" .github/workflows/advance-v1.yml`, add:

  ```bash
  assert_no_file "the reusable python-ci.yml did not ship (a generated repo gets a caller)" .github/workflows/python-ci.yml
  ```

  Run `bash template-tests/test_init_repo.sh`. Expected: that one assertion FAILS.

- [ ] **Step 8: Make it pass.** In `scripts/init-repo.sh`, change

  ```bash
  rm -f .github/reusable-contract.json .github/workflows/advance-v1.yml
  ```

  to

  ```bash
  rm -f .github/reusable-contract.json .github/workflows/advance-v1.yml .github/workflows/python-ci.yml
  ```

  and extend the comment above it to name the third file: *"python-ci.yml is the reusable Python CI;
  a generated repo carries the caller copied from templates/python instead."* Run
  `bash template-tests/test_init_repo.sh`. Expected: `ALL PASS`.

- [ ] **Step 9:** Run everything. Expected: `all suites passed` (`test_action_pins.sh` now covers
  `python-ci.yml` through its `.github/workflows/*.yml` glob; `test_shellcheck.sh` covers the new
  suite).
- [ ] **Step 10: Commit.**

  ```bash
  git add .github/workflows/python-ci.yml .github/workflows/checks.yml template-tests/test_python_ci.sh scripts/init-repo.sh template-tests/test_init_repo.sh
  git commit -m "feat: python-ci.yml, the Python stack's CI as a reusable workflow"
  ```

---

### Task 3: The contract golden for `python-ci.yml`

**Files:**
- Create: `.github/reusable-contract-python-ci.json`
- Modify: `template-tests/test_reusable_contract.sh`
- Modify: `scripts/init-repo.sh` (the same `rm -f` line as Task 2), `template-tests/test_init_repo.sh`

**Interfaces:**
- Consumes: Task 2's input names and job key.
- Produces: `.github/reusable-contract-python-ci.json`, the path Task 5's advance matrix names.

- [ ] **Step 1: Generalise the extractor, with a failing test.** In
  `template-tests/test_reusable_contract.sh`, replace the `actual="$(python3 - "$WORKFLOW" <<'PY' … PY )"`
  block and the `expected=` line with a function over (workflow, job, golden), applied to both
  workflows. Inputs are now recorded **with** type, required and default: for `python-ci.yml`,
  changing a default changes every caller's behaviour. For `checks.yml`, which has no inputs, the
  value is still `[]`, so its golden does not move.

  ```bash
  surface() { # <workflow> <job> -- the consumer-visible surface as canonical JSON
    python3 - "$1" "$2" <<'PY'
  import json, sys, yaml
  d = yaml.safe_load(open(sys.argv[1]))
  # PyYAML resolves an unquoted `on:` key to the BOOLEAN True (the YAML 1.1 y/n/on/off rule). Reading
  # d['on'] therefore returns None on a perfectly valid workflow, and every trigger assertion below
  # would pass vacuously against an empty list. Accept either key.
  on = d.get('on', d.get(True)) or {}
  jobs = list(d.get('jobs', {}))
  call = (on.get('workflow_call') or {}) if isinstance(on, dict) else {}
  job = d.get('jobs', {}).get(sys.argv[2]) or {}
  perms = job['permissions'] if 'permissions' in job else d.get('permissions')
  inputs = sorted(
      ({"name": k, **{f: v[f] for f in ("type", "required", "default") if f in (v or {})}}
       for k, v in (call.get('inputs') or {}).items()),
      key=lambda i: i["name"])
  print(json.dumps({
      "job": jobs[0] if len(jobs) == 1 else "|".join(jobs),
      "permissions": perms,
      "on": sorted(on) if isinstance(on, dict) else sorted(on if isinstance(on, list) else [on]),
      "inputs": inputs,
      "secrets": sorted((call.get('secrets') or {})),
  }, sort_keys=True, separators=(',', ':')))
  PY
  }

  actual="$(surface "$WORKFLOW" checks)"
  expected="$(jq -Sc 'del(._comment)' "$GOLDEN")"
  ```

  Keep every existing `checks.yml` assertion below it unchanged. Then append a python-ci section
  before `finish`:

  ```bash
  # ---------------------------------------------------------------------------------------
  # THE SECOND REUSABLE WORKFLOW GETS THE SAME TRIPWIRE (spec §6: "§4's layers have to be rebuilt for
  # this workflow, not assumed to transfer"). advance-v1.yml's python-ci-v1 row compares THIS golden.
  PYWF=.github/workflows/python-ci.yml
  PYGOLDEN=.github/reusable-contract-python-ci.json
  echo "reusable contract: python-ci.yml matches its golden EXACTLY"
  assert_file "the python-ci golden exists" "$PYGOLDEN"
  py_actual="$(surface "$PYWF" test)"
  py_expected="$(jq -Sc 'del(._comment)' "$PYGOLDEN" 2>/dev/null || echo missing)"
  assert_eq "$py_expected" "$py_actual" "the consumer-visible surface of python-ci.yml == $PYGOLDEN"
  assert_eq '["workflow_call"]' "$(jq -c '.on' <<<"$py_actual")" "python-ci.yml is called, never triggered"
  assert_eq "write" "$(jq -r '.permissions."id-token" // "ABSENT"' <<<"$py_actual")" \
    "python-ci.yml requests id-token: write (callers must grant it)"
  assert_eq "true" "$(jq -r '.inputs[]|select(.name=="python-versions")|.required' <<<"$py_actual")" \
    "python-versions stays required (a default would move every repo's Python version into repo-template)"
  ```

- [ ] **Step 2:** `bash template-tests/test_reusable_contract.sh`. Expected: every existing checks
  assertion still passes (its golden is unchanged, proving the refactor is behaviour-preserving). The
  python-ci section FAILS on the missing golden.

- [ ] **Step 3: Write the golden.** Create `.github/reusable-contract-python-ci.json`:

  ```json
  {
    "_comment": "THE CONSUMER-VISIBLE SURFACE OF python-ci.yml: the job key, the triggers, every declared input WITH its type, required flag and default (a changed default changes every caller), the secrets, and the permissions the test job requests (a caller granting less is a startup_failure with no context reported, not a red check). Editing this file is the deliberate decision that the surface moved. template-tests/test_reusable_contract.sh asserts python-ci.yml matches it exactly, and .github/workflows/advance-v1.yml REFUSES to advance python-ci-v1 while this file differs from what python-ci-v1 points at. See template-docs/specs/2026-09-09-reusable-workflows-design.md sections 1, 4 and 6.",
    "job": "test",
    "on": ["workflow_call"],
    "permissions": {
      "contents": "read",
      "id-token": "write"
    },
    "inputs": [
      {"name": "check-command", "type": "string", "required": false, "default": "make check"},
      {"name": "python-versions", "type": "string", "required": true},
      {"name": "run-bandit", "type": "boolean", "required": false, "default": true},
      {"name": "working-directory", "type": "string", "required": false, "default": "."}
    ],
    "secrets": []
  }
  ```

- [ ] **Step 4:** `bash template-tests/test_reusable_contract.sh`. Expected: `ALL PASS`.
- [ ] **Step 5: Prove the tripwire bites.** Temporarily change `run-bandit`'s default to `false` in
  `python-ci.yml`. Expected: the golden-equality assertion FAILS. Restore it.
- [ ] **Step 6: Keep the golden out of generated repos.** Add to `template-tests/test_init_repo.sh`,
  next to Task 2's assertion:

  ```bash
  assert_no_file "the python-ci golden did not ship" .github/reusable-contract-python-ci.json
  ```

  Watch it fail, then add `.github/reusable-contract-python-ci.json` to the same `rm -f` line in
  `scripts/init-repo.sh`, and watch it pass.
- [ ] **Step 7:** Run everything. Expected: `all suites passed`.
- [ ] **Step 8: Commit.**

  ```bash
  git add .github/reusable-contract-python-ci.json template-tests/test_reusable_contract.sh scripts/init-repo.sh template-tests/test_init_repo.sh
  git commit -m "feat: a contract golden for python-ci.yml, recording inputs with their defaults"
  ```

---

### Task 4: Layer 2 — the self-call

**Files:**
- Modify: `.github/workflows/template-tests.yml` (new job after `self-call`)
- Modify: `template-tests/test_python_ci.sh` (new section before the verdict section)

**Interfaces:**
- Consumes: Task 2's inputs (`python-versions`, `working-directory`).

- [ ] **Step 1: Failing test.** Add to `template-tests/test_python_ci.sh`, before the
  `# THE VERDICT IS THE ONLY THING` block:

  ```bash
  # LAYER 2 (spec §4). It must be a job INSIDE template-tests.yml, because advance-v1.yml chains off
  # that workflow run's conclusion: a self-call anywhere else gates nothing, and python-ci-v1 could
  # advance carrying a workflow nobody can call.
  echo "python-ci: the self-call gates the tag"
  sc="$(python3 - .github/workflows/template-tests.yml <<'PY'
  import json, sys, yaml
  j = (yaml.safe_load(open(sys.argv[1])).get('jobs') or {}).get('self-call-python-ci') or {}
  print(json.dumps({"uses": j.get('uses'), "if": j.get('if'), "perms": j.get('permissions'), "with": j.get('with') or {}}))
  PY
  )"
  assert_eq "./.github/workflows/python-ci.yml" "$(jq -r .uses <<<"$sc")" "a template-tests job calls python-ci.yml"
  assert_eq "github.event_name == 'push'" "$(jq -r .if <<<"$sc")" "push only (one billed job per push, not per PR)"
  assert_eq '{"contents":"read","id-token":"write"}' "$(jq -c .perms <<<"$sc")" \
    "the self-call grants id-token: write (granting less is a startup_failure of ALL of template-tests)"
  assert_eq "templates/python" "$(jq -r '.with["working-directory"]' <<<"$sc")" "it runs against the Python template"
  dockerfile_ver="$(sed -nE 's/^FROM python:([0-9]+\.[0-9]+).*/\1/p' templates/python/Dockerfile | head -1)"
  assert_eq "[\"${dockerfile_ver}\"]" "$(jq -c '.with["python-versions"]|fromjson' <<<"$sc")" \
    "it tests the version the template's Dockerfile deploys on"
  ```

  Run it. Expected: those five assertions FAIL.

- [ ] **Step 2: Add the job.** Append to `.github/workflows/template-tests.yml`, after the `self-call`
  job:

  ```yaml
    # LAYER 2 FOR python-ci.yml — the same reasoning as `self-call` above, for the second reusable
    # workflow: proves python-ci.yml RESOLVES, EXPANDS and RUNS GREEN, and puts that result inside the
    # run whose conclusion gates the python-ci-v1 advance. It runs the workflow for real against
    # templates/python (repo-template's root has no Python project, which is the only reason the
    # working-directory input exists) at the version the template's Dockerfile deploys on.
    #
    # Same permissions rule as `self-call`: python-ci.yml requests id-token: write, and granting less
    # fails the WHOLE workflow at startup, including on pull_request where this job never runs.
    self-call-python-ci:
      if: github.event_name == 'push'
      permissions:
        contents: read
        id-token: write
      uses: ./.github/workflows/python-ci.yml
      with:
        python-versions: '["3.11"]'
        working-directory: templates/python
  ```

- [ ] **Step 3:** `bash template-tests/test_python_ci.sh`. Expected: `ALL PASS`.
- [ ] **Step 4:** Run everything. Expected: `all suites passed`.
- [ ] **Step 5: Commit.**

  ```bash
  git add .github/workflows/template-tests.yml template-tests/test_python_ci.sh
  git commit -m "feat: template-tests self-calls python-ci.yml (layer 2)"
  ```

The self-call first runs for real on the push to `dev` after PR 1 merges. Task 6 proves the same
workflow in the lab before then, and Task 0 Step 3 already proved the template passes `make check`.

---

### Task 5: One advance workflow, two tags

**Files:**
- Modify: `.github/workflows/advance-v1.yml`
- Modify: `template-tests/test_advance_v1.sh`

**Interfaces:**
- Consumes: `.github/reusable-contract-python-ci.json` (Task 3).
- Produces: the `decide` step reads env `TAG`, `CONTRACT`, `ACKNOWLEDGED`, `DISPATCHED_TAG` and
  `TARGET_SHA`. The move step reads `TAG` and `TARGET_SHA`.

- [ ] **Step 1: Failing tests.** In `template-tests/test_advance_v1.sh`:

  1. Make the fixtures tag-aware. At the top of `scenario()` and `scenario_ancestry()`, the contract
     file and the tag come from two globals, set before each group of calls:

     ```bash
     S_TAG=v1; S_CONTRACT=.github/reusable-contract.json
     ```

     In both fixture bodies, replace `.github/reusable-contract.json` with `"$S_CONTRACT"` and
     `git tag v1` with `git tag "$S_TAG"`. In both driver lines, add the new env:

     ```bash
     ( cd "$d" && TAG="$S_TAG" CONTRACT="$S_CONTRACT" DISPATCHED_TAG="$S_TAG" ACKNOWLEDGED="$ack" TARGET_SHA="$target" GITHUB_OUTPUT="$d/out" \
         bash "$DECIDE" >/dev/null 2>&1 ) || rc=$?
     ```

     (`scenario_ancestry` passes `ACKNOWLEDGED=true` as it does today.)

  2. After the existing scenario groups, before `finish`, add:

     ```bash
     echo "advance: the python-ci-v1 row runs the same tripwire against its OWN golden"
     S_TAG=python-ci-v1; S_CONTRACT=.github/reusable-contract-python-ci.json
     scenario "python-ci: contract unchanged since python-ci-v1 -> advance"       0 false no  yes
     scenario "python-ci: contract changed since python-ci-v1 -> REFUSE"          1 false yes yes
     scenario "python-ci: unrelated push after a refused one -> STILL REFUSE"     1 false yes yes yes
     scenario "python-ci: python-ci-v1 does not resolve -> REFUSE, do not guess"  1 false no  no
     scenario_ancestry "python-ci: acknowledged, SHA NOT on main -> REFUSE"       1 no
     S_TAG=v1; S_CONTRACT=.github/reusable-contract.json

     # A DISPATCH ACKNOWLEDGES ONE TAG. The matrix runs both rows on every dispatch; the row the
     # acknowledgement is NOT for must do nothing — not advance on an acknowledgement meant for the
     # other workflow, and not fail either.
     echo "advance: a dispatch for one tag leaves the other alone"
     d="$(mktemp -d)"
     ( cd "$d" && git init -q . && git symbolic-ref HEAD refs/heads/main && git config user.email t@t && git config user.name t \
       && git remote add origin "$d" && echo x > f && git add -A && git commit -qm x && git tag v1 )
     rc=0
     ( cd "$d" && TAG=v1 CONTRACT=.github/reusable-contract.json DISPATCHED_TAG=python-ci-v1 ACKNOWLEDGED=true \
         TARGET_SHA="$(git rev-parse HEAD)" GITHUB_OUTPUT="$d/out" bash "$DECIDE" >/dev/null 2>&1 ) || rc=$?
     assert_eq 0 "$rc" "the v1 row exits 0 on a python-ci-v1 dispatch"
     assert_eq "advance=false" "$(cat "$d/out" 2>/dev/null)" "and decides NOT to advance"
     rm -rf "$d"

     # THE POINT-TAG NUMBERING IS THE PART THE PARAMETERISATION CAN BREAK. `v1.*.0` must not count
     # python-ci-v1.N.0, and python-ci-v1's sequence must not continue from v1's. Drive the real move
     # step against a repo whose origin is itself, so its pushes land locally.
     echo "advance: each tag numbers its own point tags"
     MOVE="$(mktemp)"
     python3 - "$WORKFLOW" > "$MOVE" <<'PY'
     import sys, yaml
     for s in yaml.safe_load(open(sys.argv[1]))['jobs']['advance']['steps']:
         if s.get('name') == 'move the tag and cut the next point tag':
             sys.stdout.write(s['run']); break
     else:
         sys.exit("no step named 'move the tag and cut the next point tag'")
     PY
     d="$(mktemp -d)"
     ( cd "$d" && git init -q . && git symbolic-ref HEAD refs/heads/main && git config user.email t@t && git config user.name t \
       && git remote add origin "$d" && echo x > f && git add -A && git commit -qm x \
       && git tag v1.3.0 && git tag python-ci-v1.1.0 && git tag python-ci-v1.7.0 )
     sha="$(git -C "$d" rev-parse HEAD)"
     ( cd "$d" && TAG=v1 TARGET_SHA="$sha" bash "$MOVE" >/dev/null 2>&1 ) || true
     ( cd "$d" && TAG=python-ci-v1 TARGET_SHA="$sha" bash "$MOVE" >/dev/null 2>&1 ) || true
     assert_ok "v1 cut v1.4.0 (python-ci-v1.7.0 did not count)" git -C "$d" rev-parse -q --verify refs/tags/v1.4.0
     assert_ok "python-ci-v1 cut python-ci-v1.8.0 (v1.3.0 did not count)" git -C "$d" rev-parse -q --verify refs/tags/python-ci-v1.8.0
     assert_ok "the moving python-ci-v1 tag exists" git -C "$d" rev-parse -q --verify refs/tags/python-ci-v1
     rm -rf "$d" "$MOVE"
     ```

  Run `bash template-tests/test_advance_v1.sh`. Expected: failures (the decide step does not read
  `TAG`/`CONTRACT`, and no step has the new name).

- [ ] **Step 2: Parameterise the workflow.** In `.github/workflows/advance-v1.yml`:

  1. Add a `tag` input to `workflow_dispatch.inputs`, **above** `acknowledge-contract-change`:

     ```yaml
          tag:
            description: 'Which moving tag this acknowledgement is for'
            type: choice
            options: [v1, python-ci-v1]
            required: true
     ```

  2. Add a matrix to the `advance` job, directly under its `if:`:

     ```yaml
        # ONE ROW PER MOVING TAG (Phase G, D7). Each row runs the same decision against its own golden
        # and its own tag, so a refusal for one never holds up the other. fail-fast: false for the same
        # reason: a red python-ci-v1 row must not cancel a v1 advance carrying a security fix.
        strategy:
          fail-fast: false
          matrix:
            include:
              - tag: v1
                contract: .github/reusable-contract.json
              - tag: python-ci-v1
                contract: .github/reusable-contract-python-ci.json
     ```

  3. In the `decide` step's `env:`, add

     ```yaml
            TAG: ${{ matrix.tag }}
            CONTRACT: ${{ matrix.contract }}
            DISPATCHED_TAG: ${{ inputs.tag }}
     ```

     and make these edits to its `run:`:
     - As the first command after `set -euo pipefail`:

       ```bash
       # A dispatch acknowledges ONE tag. The other row must neither advance nor fail.
       if [ "${ACKNOWLEDGED}" = "true" ] && [ "${DISPATCHED_TAG}" != "${TAG}" ]; then
         echo "::notice::this dispatch acknowledges ${DISPATCHED_TAG}, not ${TAG} — leaving ${TAG} where it is"
         echo "advance=false" >> "${GITHUB_OUTPUT}"
         exit 0
       fi
       ```

     - `refs/tags/v1^{commit}` → `refs/tags/${TAG}^{commit}`
     - `-- .github/reusable-contract.json` → `-- "${CONTRACT}"`
     - In every `echo` in that step, replace the literal `v1` with `${TAG}` and the literal
       `.github/reusable-contract.json` with `${CONTRACT}`. Keep the wording otherwise.

  4. Rename the step `move v1 and cut the next point tag` to
     `move the tag and cut the next point tag`, add `TAG: ${{ matrix.tag }}` to its `env:`, and
     replace its tag lines with:

     ```bash
     last="$(git tag -l "${TAG}.*.0" | sed -E "s/^${TAG}\.([0-9]+)\.0\$/\1/" | grep -E '^[0-9]+$' | sort -n | tail -1 || true)"
     next="${TAG}.$(( ${last:-0} + 1 )).0"
     git tag -a "${next}" "${TARGET_SHA}" -m "${TAG} reusable workflow ${next}"
     git push origin "refs/tags/${next}"

     git tag -f "${TAG}" "${TARGET_SHA}"
     git push --force origin "refs/tags/${TAG}"
     echo "::notice::${TAG} -> ${TARGET_SHA} (also cut ${next})"
     ```

  5. Add one paragraph to the header comment: *"It moves TWO tags: v1 (checks.yml) and python-ci-v1
     (python-ci.yml). The file keeps its name because notes, PRs and the tag app refer to it."*

- [ ] **Step 3:** `bash template-tests/test_advance_v1.sh`. Expected: `ALL PASS`, including every
  pre-existing v1 scenario (the refactor must not change v1's behaviour).
- [ ] **Step 4:** Run everything. Expected: `all suites passed`.
- [ ] **Step 5: Commit.**

  ```bash
  git add .github/workflows/advance-v1.yml template-tests/test_advance_v1.sh
  git commit -m "feat: advance-v1 moves python-ci-v1 as well, each against its own golden"
  ```

---

### Task 6: Lab proof (manual, before PR 1 merges)

This is spec §6's "a good and a deliberately bad PR observed on a Python adoption in the lab". Run
it in `avenue-z-ci-lab/adopter-python`, whose billing is separate from Avenue-Z's. It calls the
**branch** (`@feat/python-ci-reusable`), which is public because `repo-template` is.

- [ ] **Step 1:** `git push -u origin feat/python-ci-reusable`
- [ ] **Step 2:** In a clone of `avenue-z-ci-lab/adopter-python`, on a branch `feat/python-ci-probe`
  off its `dev`, replace `.github/workflows/ci.yml` with Task 8's caller, changing only the `uses:`
  ref to `@feat/python-ci-reusable`. Open a PR to `dev`. **Expected:** `ci` green; the
  `python-ci / test (3.11)` log shows
  `gate scripts: staging from Avenue-Z/repo-template@refs/heads/feat/python-ci-reusable`; 2 jobs total.
- [ ] **Step 3: Bad PR, tests.** On top of the probe branch, add `tests/test_fail.py` containing
  `def test_fail() -> None:\n    assert False`. **Expected:** `ci` red; the verdict names
  `check: failure`.
- [ ] **Step 4: Bad PR, SAST.** Instead, add to `src/app/main.py`:
  `import subprocess` and `def run(c: str) -> None:\n    subprocess.Popen(c, shell=True)`. First
  confirm the lab repo's `.github/sca-policy.json` tier is `client-facing`. **Expected:** `ci` red;
  the Bandit step reports B602 HIGH/HIGH; the verdict names `bandit: failure`.
- [ ] **Step 5: The silent case.** Instead, remove `id-token: write` from the caller's `python-ci`
  job. **Expected:** `startup_failure`, zero jobs, no `ci` context. This is the failure Task 9 guards
  against. Record it; do not "fix" it here.
- [ ] **Step 6: Library shape.** Instead, set `python-versions: '["3.11","3.12","3.13"]'`.
  **Expected:** three `test` legs, Bandit runs only in `(3.11)`, `ci` green.
- [ ] **Step 7:** Record every run id and the observed durations (they feed §5's still-open
  60-second question) in `docs/notes/2026-09-XX-phase-g-lab-proof.md`, using today's date. Commit it
  to `feat/python-ci-caller` later (Task 10). Close the lab PRs.

If any step does not behave as expected, **stop**, write down what was observed, and fix it on
`feat/python-ci-reusable` before going on.

---

### Task 7: PR 1, promotion, and the hand-cut tag

- [ ] **Step 1:** Open PR 1 `feat/python-ci-reusable → dev`. Its body links this plan and the lab
  note's run ids, and states that `python-ci-v1` does not exist yet, so the advance's `python-ci-v1`
  row will be red until Step 4.
- [ ] **Step 2:** After merge (**user's go-ahead**), confirm `template-tests` on the `dev` push is
  green, including `self-call-python-ci / test (3.11)`.
- [ ] **Step 3:** Promote `dev → staging → main`, **each step with the user's go-ahead**. PR #82 is
  already on `dev`. Once it reaches `main`, the **v1** row refuses until acknowledged, as intended.
  Acknowledge it with the new input: Actions → advance-v1 → Run workflow, `tag: v1`,
  `acknowledge-contract-change: <main SHA>`.
- [ ] **Step 4: Cut `python-ci-v1` by hand, once.** From an up-to-date `main`:

  ```bash
  git fetch origin && sha="$(git rev-parse origin/main)"
  git tag -a python-ci-v1.0.0 "$sha" -m "python-ci.yml reusable workflow python-ci-v1.0.0"
  git tag python-ci-v1 "$sha"
  git push origin refs/tags/python-ci-v1.0.0 refs/tags/python-ci-v1
  ```

  Pushing tags is outward-facing; **confirm with the user before running.**
- [ ] **Step 5: Protect it, and the point tags.** An org admin adds `refs/tags/python-ci-v1` to the
  existing tag ruleset (id `22951344`, `v1-tag-protection`: rules `deletion` + `non_fast_forward`;
  bypass: the `avenue-z-v1-tag-advance` app). **In the same edit, also add `refs/tags/v1.*` and
  `refs/tags/python-ci-v1.*`.** Today the ruleset includes exactly `refs/tags/v1`, so `v1.0.0` through
  `v1.4.0` can be deleted or force-moved by anyone with write access, and those point tags are the
  rollback path consumers pin to (PR 84 review, finding 3). Adding them does not interfere with
  `advance-v1.yml`, which only creates point tags and never moves them, **because the ruleset has no
  `creation` rule**. Confirm that before editing. First read the current conditions and rules:

  ```bash
  gh api repos/Avenue-Z/repo-template/rulesets/22951344 --jq '{include: .conditions.ref_name.include, rules: [.rules[].type]}'
  ```

  Expected: `include` is `["refs/tags/v1"]` and `rules` is `["deletion","non_fast_forward"]`. If a
  `creation` rule is present, stop, because the advance would be refused when it cuts the next point tag.
  Then set `include` to `["refs/tags/v1", "refs/tags/v1.*", "refs/tags/python-ci-v1",
  "refs/tags/python-ci-v1.*"]` using the same `gh api -X PUT` form as the Phase A note. **This
  changes repository settings, so the user runs it or explicitly approves it.** Re-run the read
  above and confirm all four patterns are listed. Then verify that a non-bypass force-push is refused
  on a moving tag and on a point tag:
  `git tag -f python-ci-v1 HEAD~1 && git push --force origin refs/tags/python-ci-v1` and
  `git tag -f python-ci-v1.0.0 HEAD~1 && git push --force origin refs/tags/python-ci-v1.0.0` should
  each fail with `GH013`. Afterwards, reset the local tags with `git fetch --tags --force`. If either
  push *succeeds*, the pattern did not take. Push the original SHA back at once, then fix the ruleset.
  The ruleset lives only in the GitHub API (Open item 18), so this step is the only place the
  change gets reviewed.
- [ ] **Step 6:** Push any commit to `main` through the normal flow, or re-run the latest advance.
  Expected: both rows advance, or refuse only for a stated reason.

---

### Task 8: The Python template becomes a caller (PR 2)

**Files:**
- Modify: `templates/python/.github/workflows/ci.yml` (full rewrite)
- Modify: `template-tests/test_python_ci.sh` (new section)
- Modify: `template-tests/test_bandit.sh:85-103`

**Interfaces:**
- Consumes: `python-ci.yml@python-ci-v1` (exists after Task 7 Step 4), inputs from Task 2.

- [ ] **Step 1:** `git switch dev && git pull --ff-only && git switch -c feat/python-ci-caller`.
  Confirm the tag exists: `git ls-remote --tags origin python-ci-v1` prints one line.

- [ ] **Step 2: Failing tests.** Add to `template-tests/test_python_ci.sh`, before `finish`:

  ```bash
  # ---------------------------------------------------------------------------------------
  # THE PYTHON TEMPLATE'S ci.yml IS A CALLER. init-repo.sh copies it verbatim into every new Python
  # repo, so what it says here is what those repos run until someone edits them by hand.
  PYCALLER=templates/python/.github/workflows/ci.yml
  echo "python caller: shape"
  caller="$(python3 - "$PYCALLER" <<'PY'
  import json, sys, yaml
  d = yaml.safe_load(open(sys.argv[1]))
  jobs = d.get('jobs') or {}
  pc, ci = jobs.get('python-ci') or {}, jobs.get('ci') or {}
  print(json.dumps({
      "jobs": sorted(jobs),
      "uses": pc.get('uses'),
      "perms": pc.get('permissions'),
      "versions": (pc.get('with') or {}).get('python-versions'),
      "ci_needs": ci.get('needs'),
      "ci_if": ci.get('if'),
      "ci_uses_actions": any('uses' in s for s in (ci.get('steps') or [])),
      "ci_run": next((s.get('run') for s in (ci.get('steps') or []) if s.get('name') == 'verdict'), ""),
  }))
  PY
  )"
  assert_eq '["ci","python-ci"]' "$(jq -c .jobs <<<"$caller")" "the caller has exactly two jobs: python-ci and ci"
  assert_eq "Avenue-Z/repo-template/.github/workflows/python-ci.yml@python-ci-v1" "$(jq -r .uses <<<"$caller")" \
    "python-ci calls the reusable workflow at the moving python-ci-v1 tag"
  # Same silent failure as checks.yml's caller: without the grant the run is a startup_failure, the
  # `ci` context never reports, and a PR where it is required hangs PENDING FOREVER.
  assert_eq '{"contents":"read","id-token":"write"}' "$(jq -c .perms <<<"$caller")" \
    "the python-ci job grants contents: read + id-token: write"
  # D1: the version lives here, and it must be the one the Dockerfile deploys on.
  dockerfile_ver="$(sed -nE 's/^FROM python:([0-9]+\.[0-9]+).*/\1/p' templates/python/Dockerfile | head -1)"
  assert_eq "[\"${dockerfile_ver}\"]" "$(jq -c '.versions|fromjson' <<<"$caller")" \
    "python-versions is exactly the Dockerfile's version (${dockerfile_ver}), as a quoted string"
  assert_eq '["python-ci"]' "$(jq -c .ci_needs <<<"$caller")" "ci needs python-ci"
  assert_eq "always()" "$(jq -r .ci_if <<<"$caller")" "ci runs always() (a skipped required check never reports)"
  assert_eq "false" "$(jq -r .ci_uses_actions <<<"$caller")" "ci uses no action (nothing to pin, nothing to bump)"

  echo "python caller: the ci aggregate, driven"
  CIRUN="$(mktemp)"; jq -r .ci_run <<<"$caller" > "$CIRUN"
  agg_rc() { local rc=0; NEEDS="$1" bash "$CIRUN" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
  assert_eq 0 "$(agg_rc '{"python-ci":{"result":"success","outputs":{}}}')" "python-ci success -> ci green"
  assert_eq 1 "$(agg_rc '{"python-ci":{"result":"failure","outputs":{}}}')" "python-ci failure -> ci red"
  assert_eq 1 "$(agg_rc '{"python-ci":{"result":"cancelled","outputs":{}}}')" "python-ci cancelled -> ci red"
  assert_eq 1 "$(agg_rc '{"python-ci":{"result":"success","outputs":{}},"dbt-parse":{"result":"skipped","outputs":{}}}')" \
    "a per-repo extra that skipped -> ci red"
  assert_eq 1 "$(agg_rc '{}')" "no needs at all -> ci red (an aggregate over nothing proves nothing)"
  rm -f "$CIRUN"
  ```

  Run it. Expected: the caller section FAILS (today's `ci.yml` has jobs `test` and `ci`).

- [ ] **Step 3: Rewrite the caller.** Replace `templates/python/.github/workflows/ci.yml` with the
  following. Keep the `on:` block and its comment exactly as they are today; `test_ci_triggers.sh`
  asserts it.

  ```yaml
  name: ci

  on:
    # (keep today's pull_request + push: [main] block and its comment VERBATIM)

  permissions:
    contents: read

  # A CALLER, NOT A COPY. The build, the tests and Bandit live in repo-template's python-ci.yml,
  # reached at the moving tag python-ci-v1, so a fix there reaches this repo with no PR here —
  # including the pinned action SHAs, which Dependabot bumps once, in repo-template.
  jobs:
    python-ci:
      # A job-level block REPLACES the workflow-level one, so contents: read is restated. id-token:
      # write is what lets python-ci.yml find out which ref of the template it was called at (an OIDC
      # claim; see checks.yml). DROPPING IT DOES NOT PRODUCE A RED CHECK: the run is a startup_failure
      # with ZERO jobs, `ci` never reports, and where it is required the PR hangs PENDING FOREVER.
      # scripts/apply-rulesets.sh refuses to require `ci` from a caller missing it.
      permissions:
        contents: read
        id-token: write
      uses: Avenue-Z/repo-template/.github/workflows/python-ci.yml@python-ci-v1
      with:
        # THE VERSION THIS REPO DEPLOYS ON — the one in its Dockerfile's FROM line, as a quoted string.
        # Bump both together. A library installed by other repos lists every version it supports.
        python-versions: '["3.11"]'

    # WHY THIS JOB EXISTS. The required context is literally `ci` (scripts/apply-rulesets.sh). A called
    # job reports as `python-ci / test (3.11)` — the version is IN the name, so requiring it would break
    # on every Python bump. This job owns the stable name and does nothing else.
    #
    # `if: always()` is load-bearing: without it this job is SKIPPED when python-ci fails, and a skipped
    # required check never reports. Add any per-repo job (e.g. dbt-parse) to `needs:` and it is gated
    # automatically: the verdict requires EVERY needed job to be exactly `success`.
    ci:
      needs: [python-ci]
      if: always()
      runs-on: ubuntu-latest
      steps:
        - name: verdict
          env:
            NEEDS: ${{ toJSON(needs) }}
          run: |
            set -euo pipefail
            if jq -e 'length > 0 and all(.[]; .result == "success")' <<<"${NEEDS}" >/dev/null; then
              echo "every needed job succeeded"
            else
              echo "::error::a job this aggregate needs did not succeed:"
              jq -r 'to_entries[] | "  \(.key): \(.value.result)"' <<<"${NEEDS}"
              exit 1
            fi
  ```

- [ ] **Step 4:** `bash template-tests/test_python_ci.sh`. Expected: `ALL PASS`.
- [ ] **Step 5: Move `test_bandit.sh`'s wiring assertions to where Bandit now lives.** In
  `template-tests/test_bandit.sh`, change `PYCI=templates/python/.github/workflows/ci.yml` to
  `PYCI=.github/workflows/python-ci.yml`, and change the echo line to
  `echo "python-ci.yml wiring: the gate actually decides on bandit's result"`. Every existing regex
  holds against `python-ci.yml` (`scripts/bandit-gate\.sh` matches the staged `trusted-scripts/…`
  path). Then add, directly after that block:

  ```bash
  # The caller must NOT run Bandit itself: that would be the workspace copy of the gate, which a PR can
  # rewrite. Bandit runs inside python-ci.yml, on the staged script.
  caller_txt="$(cat templates/python/.github/workflows/ci.yml)"
  assert_nomatch "the python caller runs no bandit of its own" 'bandit' "$(python3 -c 'import yaml,sys; print(yaml.safe_dump(yaml.safe_load(open(sys.argv[1]))))' templates/python/.github/workflows/ci.yml)"
  assert_match   "the python caller still declares a 'ci:' job (context reports)" '^[[:space:]]*ci:[[:space:]]*$' "$caller_txt"
  ```

  Run `bash template-tests/test_bandit.sh`. Expected: `ALL PASS`.
- [ ] **Step 6:** Run everything. Expected: `all suites passed` (`test_ci_triggers.sh` confirms the
  triggers survived; `test_action_pins.sh` now has nothing to check in the Python caller).
- [ ] **Step 7: Commit.**

  ```bash
  git add templates/python/.github/workflows/ci.yml template-tests/test_python_ci.sh template-tests/test_bandit.sh
  git commit -m "feat: the Python template's ci.yml calls python-ci.yml@python-ci-v1, one version"
  ```

---

### Task 9: `apply-rulesets.sh` refuses a python-ci caller without the grant (PR 2)

**Files:**
- Modify: `scripts/apply-rulesets.sh:139-158` (and the `ci` `add_context` line, :171)
- Modify: `template-tests/test_apply_rulesets.sh` (new section after the checks-caller refusals)

- [ ] **Step 1: Failing test.** Append to `template-tests/test_apply_rulesets.sh`, after the last
  `caller_run`/`assert_refused` group and before `finish`:

  ```bash
  # ---------------------------------------------------------------------------------------
  # THE SAME REFUSAL FOR ci.yml. python-ci.yml requests id-token: write, so a ci.yml whose python-ci
  # caller job does not grant it is a startup_failure: `ci` never reports, and requiring it hangs every
  # PR PENDING FOREVER (lab-observed in Phase G, Task 6 Step 5). init-repo.sh ships the grant; this is
  # the guard for callers written by hand during migration.
  GRANTED_CHECKS='name: checks
  on: pull_request
  jobs:
    checks:
      permissions:
        contents: read
        id-token: write
      uses: Avenue-Z/repo-template/.github/workflows/checks.yml@v1'
  ci_caller_run() { # <ci.yml content> -- sets CALLER_RC and CALLER_OUT
    local fx
    fx="$(mktemp -d)"
    mkdir -p "${fx}/scripts" "${fx}/.github/rulesets" "${fx}/.github/workflows"
    cp scripts/apply-rulesets.sh "${fx}/scripts/apply-rulesets.sh"
    cp .github/rulesets/repo-ruleset.json "${fx}/.github/rulesets/repo-ruleset.json"
    printf '%s\n' "${GRANTED_CHECKS}" > "${fx}/.github/workflows/checks.yml"
    printf '%s\n' "$1" > "${fx}/.github/workflows/ci.yml"
    CALLER_RC=0
    CALLER_OUT="$(cd "${fx}" && PATH="${STUB}:${PATH}" ./scripts/apply-rulesets.sh --dry-run 2>&1)" || CALLER_RC=$?
    rm -rf "${fx}"
  }

  echo "apply-rulesets: a python-ci caller that grants nothing is refused"
  ci_caller_run 'name: ci
  on: pull_request
  jobs:
    python-ci:
      uses: Avenue-Z/repo-template/.github/workflows/python-ci.yml@python-ci-v1
    ci:
      needs: [python-ci]
      runs-on: ubuntu-latest'
  if [ "${CALLER_RC}" -ne 0 ]; then pass "refused (non-zero exit)"; else fail "should be refused, exited 0. Output: ${CALLER_OUT}"; fi
  assert_match   "the refusal names the missing grant" 'id-token: write' "${CALLER_OUT}"
  assert_nomatch "it never gets as far as requiring 'ci'" 'required: ci$' "${CALLER_OUT}"

  echo "apply-rulesets: a python-ci caller that grants it requires 'ci'"
  ci_caller_run 'name: ci
  on: pull_request
  jobs:
    python-ci:
      permissions:
        contents: read
        id-token: write
      uses: Avenue-Z/repo-template/.github/workflows/python-ci.yml@python-ci-v1
    ci:
      needs: [python-ci]
      runs-on: ubuntu-latest'
  assert_match "a granted python-ci caller requires 'ci'" 'required: ci$' "${CALLER_OUT}"

  echo "apply-rulesets: a self-contained ci.yml (no python-ci caller) is unaffected"
  ci_caller_run 'name: ci
  on: pull_request
  jobs:
    test:
      runs-on: ubuntu-latest
    ci:
      needs: [test]
      runs-on: ubuntu-latest'
  assert_match "a ci.yml with no python-ci caller still requires 'ci'" 'required: ci$' "${CALLER_OUT}"
  ```

  Run it. Expected: the first group FAILS (nothing refuses yet).

- [ ] **Step 2: Implement.** In `scripts/apply-rulesets.sh`:
  1. Rename `checks_job_grants_id_token() { # <workflow-file>` to
     `job_grants_id_token() { # <workflow-file> <job>`. Change its awk invocation to
     `awk -v job="$2" '`, and change the job-match line `/^  checks:$/ { injob=1; next }` to
     `$0 == "  " job ":" { injob=1; next }`. Change the file argument from `"$1"` to `"$1"`
     (unchanged). Update the comment's first line to say the function works for any caller job.
  2. Update its one call site to `job_grants_id_token .github/workflows/checks.yml checks || die …`
     (message unchanged).
  3. Directly before `add_context ci …`, add:

     ```bash
     # A ci.yml that CALLS python-ci.yml is held to the same rule as a checks.yml caller: python-ci.yml
     # requests id-token: write, and a caller job that does not grant it is a startup_failure, so `ci`
     # never reports and requiring it hangs every PR PENDING FOREVER.
     if [ -f .github/workflows/ci.yml ]; then
       py_caller="$(awk '/^  [A-Za-z0-9_-]+:$/ { j=substr($1, 1, length($1)-1) } /^    uses:.*\/python-ci\.yml@/ { print j; exit }' .github/workflows/ci.yml)"
       if [ -n "${py_caller}" ]; then
         job_grants_id_token .github/workflows/ci.yml "${py_caller}" || die ".github/workflows/ci.yml calls python-ci.yml from job '${py_caller}', which is not granted id-token: write.
            Refusing to require 'ci'. Without the grant the run is a startup_failure with ZERO jobs, so
            'ci' never reports and every PR would hang PENDING FOREVER. Add this to the '${py_caller}' job
            (a job-level block REPLACES the workflow-level one) and re-run:

                permissions:
                  contents: read
                  id-token: write"
       fi
     fi
     ```

- [ ] **Step 3:** `bash template-tests/test_apply_rulesets.sh`. Expected: `ALL PASS`, including the
  existing checks-caller refusals (the rename must not change them).
- [ ] **Step 4:** Run everything (`test_shellcheck.sh` covers the script). Expected: `all suites passed`.
- [ ] **Step 5: Commit.**

  ```bash
  git add scripts/apply-rulesets.sh template-tests/test_apply_rulesets.sh
  git commit -m "fix: apply-rulesets refuses a python-ci caller job without id-token: write"
  ```

---

### Task 10: Record it, and open PR 2

**Files:**
- Create: `docs/notes/2026-09-XX-phase-g-lab-proof.md` (from Task 6)
- Modify: `template-docs/specs/2026-09-09-reusable-workflows-design.md` (§3 phase table, G row)

- [ ] **Step 1:** Commit the lab note from Task 6 Step 7.
- [ ] **Step 2:** In the spec's §3 phase table, append to the G row:
  `**Done** <date> — python-ci-v1 cut at <sha>; lab proof in docs/notes/<file>.` Use the real date,
  SHA and file name.
- [ ] **Step 3:** Run everything. Expected: `all suites passed`.
- [ ] **Step 4: Commit and open PR 2** `feat/python-ci-caller → dev`. The body states:
  - New Python repos run 2 jobs per PR instead of 4, on the Dockerfile's version.
  - No existing repo is affected. Existing repos migrate in B–E.
  - `apply-rulesets.sh` now refuses a python-ci caller without the grant.

  Merging and promotion need the user's go-ahead. Once PR 2 reaches `main`, the Python template
  that `init-repo.sh` copies is the caller. Nothing needs to advance for that, because
  `templates/` is payload, not a reusable workflow.

---

## Self-review

- **Spec coverage.** §6's input surface → Task 2 (plus D3). Job-count reduction inside the reusable
  workflow → Task 2 (one leg, Bandit folded in). "§4's layers rebuilt for this workflow": layer 1 →
  Task 2's suite, layer 2 → Task 4, layer 3 → Task 3, layer 4 → Task 6 in the lab (real fleet
  pilot stays B). Decision 1 (own tag) → Tasks 5 and 7. Decision 2 → D1 and Task 1. Decision 3
  (contract records permissions) → Task 3. Decision 4 (proven in `adopter-python`) → Task 6. Caller
  keeps the `ci` aggregate → Task 8. Per-repo extras → Task 8 (the `needs` verdict and its extra-job
  test). Open item 13's guard, extended to the new caller → Task 9.
- **Not covered, deliberately:** §5's `concurrency` block, the 60-second measurement (lab durations
  are recorded, but B confirms), Open item 15, and any existing-repo migration.
- **Names used across tasks:** input names, job `test`, step ids `scripts_src`/`check`/`bandit`, step
  names `verdict` and `Stage the trusted scripts outside the workspace`, caller job `python-ci`,
  golden path `.github/reusable-contract-python-ci.json`, tag `python-ci-v1`, and move-step name
  `move the tag and cut the next point tag` are each defined once and used identically after that.
