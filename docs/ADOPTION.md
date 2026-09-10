# Adopting the Avenue-Z repo template

Three tracks: a **net-new** repo (ready today), an **existing** repo (a careful manual port), and
**org-wide** protection (needs a GitHub plan upgrade). Read the one you need.

The template's governing rule applies to adoption too: **a failure to verify is not a verified
pass.** Where a step cannot be checked by a script, it is called out as a human gate — do not skip it.

---

## 1. Net-new repo — ready today

The whole point of the template: one click plus one script.

1. **Create the repo.** On `Avenue-Z/repo-template`, click **Use this template** → new **private**
   repo. GitHub copies only the default branch (`main`).
2. **Initialize the stack.** Clone it, then:

       git checkout -b dev
       ./scripts/init-repo.sh <python|node|next> [--team <slug>]

   - Copies the chosen stack into place and deletes the others.
   - Strips the template's own machinery (`templates/`, `template-tests/`, its workflow and specs)
     so the new repo carries **zero** template cruft.
   - Commits once and pushes `dev`, `staging`, and `main`.
   - **Run it from `dev`.** The default branch is `main` on purpose — Vercel and most tooling take
     the *production* branch from the repository default, so defaulting to `dev` would deploy every
     merged PR straight to production. A fresh copy lands you on `main`, and the script refuses to
     run until you `git checkout -b dev`.
   - `--team <slug>` writes `.github/CODEOWNERS` **only** after verifying the team exists and has
     write access — granting write if it is missing. GitHub silently ignores a CODEOWNERS entry for
     a team without write, so the script grants it or ships no file at all. Omit `--team` and no
     permissions are touched. Note: CODEOWNERS **routes** reviewers; the ruleset ships
     `required_approving_review_count: 0`, so it does not by itself **require** approval.
3. **Apply protection.** `./scripts/apply-rulesets.sh` applies branch protection where the plan
   allows and prints exactly what it skipped. On a **private repo on the Free plan** it will tell
   you plainly that `main` is *not* protected and that enforcement is the `checks` workflow +
   convention. That is expected, not a failure.
4. **`next` stack only — link Vercel.** `vercel login`, then `./scripts/link-vercel.sh`. It links but
   **never deploys**: `vercel.json` ships `deploymentEnabled: false`, and it refuses to link unless
   the default branch is `main`. Enabling a branch means editing `vercel.json` in a reviewed PR.
5. **Turn on dependency auto-remediation.** So a known-vulnerable dependency arrives as an open fix
   PR, not a bare red `sca` check, enable Dependabot alerts and security updates:

       REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
       gh api -X PUT "repos/${REPO}/vulnerability-alerts"
       gh api -X PUT "repos/${REPO}/automated-security-fixes"

   This is a repository **setting**, not a committed file — it cannot live in `dependabot.yml`, so it
   is a deliberate one-time step here (same class as `apply-rulesets.sh`). The `sca` check enforces
   the tier in `.github/sca-policy.json` (default `client-facing`: blocks CI on High/Critical vulns
   **that have a fix**); these settings make that fix show up automatically. Downgrading the tier to
   `internal` routes an edit to that CODEOWNERS-guarded file to a code owner and surfaces it in the PR
   (routing, not required approval) — see `SECURITY.md`.

6. **Fill in the skeleton.** Complete the `<!-- TODO -->` markers in `README.md` and `CLAUDE.md`, and
   install the local hook: `pre-commit install`.

**If this repo will read external data — later, not now.**

A repo that reads a vendor API, an MCP tool, a CSV drop or LLM output should declare a data
contract. This is **not** an init-time step and there is no `init-repo.sh` flag for it, on purpose:
on the day you create a repo you usually do not yet know whether it reads external data, and the
scaffolder needs your package to have its real name — not the `app` placeholder the template ships.

When that day comes, from the repo root:

    pip install "contract-core @ git+https://github.com/Avenue-Z/data-contract.git@<tag>"
    contract init --system <name> --platform <platform> --source <api|mcp|llm|file>

`--platform` takes letters, digits, hyphens and underscores only — `google-ads`, **not**
`google.ads`. A dot separates segments in a schema ref, so a dotted platform generates refs that
will not resolve against the tree `init` just wrote. It refuses one rather than writing it.

It writes `contract.yaml`, the schema tree, `boundaries.py`, a drift test and the CI workflow, and
registers the `raw_drift` pytest marker. It prints — rather than writes — the `contract-core`
dependency pin; add that line to `pyproject.toml` yourself. No read token is needed:
`data-contract` is public.

**Python only.** `contract-core` is pandera/pandas and the gate needs an importable Python package.
There is no node or next path; a non-Python repo that needs a contract should move the external read
into a Python job that owns it.

**Adopting contracts makes this a 3.13 repo.** `contract-core` declares `requires-python = ">=3.13"`
while the python stack ships `>=3.11` and a 3.11/3.12/3.13 matrix. Narrow `requires-python`,
`[tool.ruff] target-version`, `[tool.mypy] python_version`, the `ci.yml` matrix **and the
`Dockerfile` base image** together — leaving the Dockerfile behind reproduces
Avenue-Z/data-contract#53.

Expect a red check on the first run. The generated drift test fails by design until you write its
assertion, and the generated schema fields are `REPLACE_ME_` placeholders until you author them from
the real export. That red is the remaining work, not a broken scaffold.

Full detail: `Avenue-Z/data-contract` `docs/consuming-repo-setup.md`; the
`authoring-data-contracts` Claude Code skill carries the authoring workflow.

**Claude Code skills (once per machine, not per repo):**

    /plugin marketplace add Avenue-Z/claude-marketplace
    /plugin install setup@avenue-z

`repo-template-first` also routes "new repo / scaffold a service" requests to this flow
automatically, so for net-new work adoption is essentially free once people know to start here.

### Where the gate actually lives

A repo generated after 2026-09 carries a nine-line `.github/workflows/checks.yml` that calls
`Avenue-Z/repo-template/.github/workflows/checks.yml@v1`. The gate's logic — the branch matrix, the
secret scan, the dependency policy — lives in the template and reaches this repo through the moving
`v1` tag. **There is nothing to update here when the gate improves.**

Two consequences worth knowing before they surprise you:

- **`.github/sca-policy.json` is still yours.** The tier is per-repo on purpose: a client-facing repo
  and an internal one legitimately differ.
- **Your triggers are still yours.** A reusable workflow cannot define `on:` for its callers, so the
  `pull_request` types and the weekly cron live in your file. Changing the audit schedule fleet-wide is
  a PR per repo.

If `@v1` ever breaks your repo, pin the caller to the last good point tag (`@v1.N.0`) and open an issue
against the template. Do not delete the caller — that removes the only gate the repo has.

---

## 2. Existing repo — a careful manual port

There is **no retrofit script, on purpose.** The design leaves existing repos untouched because the
obvious shortcut is dangerous: getting free branch protection means making the repo **public**, and
making a private repo public **exposes its entire git history**. Some existing repos have credentials
in their working trees or history. So the port is manual and gated on a secret audit.

**Do this in order:**

1. **Audit history for secrets first.** Before anything else, and before any thought of changing
   visibility:

       gitleaks detect --source . --log-opts="--all"

   **Rotate anything it finds.** Removing the commit is not enough — a key that reached the remote is
   burned. This step is non-negotiable and comes before the rest.
2. **Write the stack-agnostic governance** (safe on a private repo, no visibility change needed):
   - `.github/workflows/checks.yml` as a **caller** — see "Where the gate actually lives" above for
     what it looks like. Do **not** copy `checks.yml`'s body from `repo-template` itself: outside
     `repo-template`, `GITHUB_REPOSITORY` takes the consumer path, and the file either refuses
     outright or tries to check out `Avenue-Z/repo-template` at your own PR ref. Either way the
     gate comes up red and cannot be made green from inside your repo.
   - `.pre-commit-config.yaml` (then `pre-commit install`)
   - the credential and env blocks from `.gitignore`, and `.env.example`
   - `CONTRIBUTING.md`, `SECURITY.md`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/dependabot.yml`
3. **Adopt the branch model.** Create `dev` and `staging`; set the default branch per the model
   (and to `main` if the repo deploys to Vercel — see the production-branch note above).
4. **Protection comes last, and only where possible.** Branch protection and rulesets are
   unavailable on private repos on Free. Until the repo is public or the org is on Team, enforcement
   is exactly what a new private repo gets: the `checks` workflow + convention.
   **Do not flip a private repo to public** without completing step 1 and rotating any findings.

---

## 3. Org-wide protection — needs GitHub Team

`scripts/apply-org-ruleset.sh` applies one ruleset to **every** repo in `Avenue-Z` at once, so it is
deliberately hard to run: no `--yes`, no non-interactive path, a typed challenge phrase, and a
refusal to apply a payload that declares required status checks (which would hang every PR pending in
repos that lack those workflows). It requires the **GitHub Team** plan — org-level rulesets do not
exist on Free.

Before the org-wide rollout, two questions from the design are still **open** and must be confirmed
on Team first (both are unanswerable on Free):

1. Does a repo creator in `Avenue-Z` actually receive the **Admin** role on the repo they create?
2. Does a repo-level **bypass actor survive an org-level ruleset**, or does the org ruleset outrank it?

The answers determine whether the emergency-bypass design works and whether non-owners can manage
protection. Confirm them before either claim lands in `CONTRIBUTING.md`. Upgrading the org to Team is
a deliberate decision, not a step this template can take for you.
