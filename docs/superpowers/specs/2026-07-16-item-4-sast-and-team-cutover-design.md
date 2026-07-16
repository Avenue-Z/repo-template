# Item 4 — first-party SAST + Team cutover — design

**Date:** 2026-07-16
**Repo:** `Avenue-Z/repo-template`
**Parent:** `2026-07-16-hardening-additions-sca-and-supply-chain-design.md` (Item 4)

## Why this is its own spec

The parent bundle spec deferred all of Item 4 to the GitHub Team cutover on a single premise:
*static analysis needs GitHub Advanced Security, which does not exist on private + Free.* That premise
is **half wrong**, and the error is worth correcting because it left first-party code unscanned
indefinitely.

**What is actually Team-gated is GitHub's private-repo Code Scanning *UI* — not static analysis
itself.** SAST-the-capability can run on private + Free the same way Item 1's SCA does: a plain
workflow that resolves findings and **fails the CI job**, with no Security tab in the loop. So Item 4
does not split cleanly along the Free/Team line. It splits along **capability + stack**:

| Piece | Gate | This spec |
|---|---|---|
| **A. Bandit SAST — `python` stack** | none — runs today on Free | design + implement now |
| **B. CodeQL cross-file SAST — Python + TS** | Team (GitHub Advanced Security) | design decisions recorded; deferred |
| **C. Org-ruleset rollout + the two open questions** | Team (org rulesets don't exist on Free) | research protocol; deferred |

Part A is the correction. Parts B and C remain genuinely Team-gated — Part C is the highest-leverage
work in the whole hardening effort, because its two open questions gate whether the org-wide +
emergency-bypass design is even correct.

---

## Part A — Bandit SAST for the `python` stack (implementable now)

**The osv-scanner pattern, applied to first-party code.** Bandit walks the Python AST for
vulnerability patterns — `shell=True`/`subprocess` injection, `yaml.load`, `pickle`, hardcoded
secrets, weak crypto, SQL built by string concatenation, `assert` in production paths. It runs as a
plain workflow that **fails the `ci` job** on findings that clear the tier's threshold; no Security
tab, no Advanced Security.

### Decision: reuse Item 1's tier, gate on severity **and** confidence

Bandit emits a **severity** *and* a **confidence** level (each low/med/high) per finding. That maps
directly onto Item 1's "severity floor + threshold, never all-or-nothing" philosophy, so Part A does
not invent a second policy dial — it **reuses Item 1's committed, CODEOWNERS-guarded policy value**:

| Tier | Bandit blocks on | Everything else |
|---|---|---|
| `client-facing` (default) | **high severity AND high confidence** | warns |
| `internal` | nothing | warns |

Gating on high-confidence-too is the SAST analogue of Item 1's *never-block-without-a-fix* invariant:
pattern SAST is noisier than dataflow, and a low-confidence hit is the SAST equivalent of an
unactionable finding. Blocking only on high/high collapses the volume to the handful a small team can
actually own — the same reasoning that rescued Item 1 from theater.

### Self-contained, consistent with the template's posture

Bandit is Apache-2.0 (PyCQA), installs from PyPI, and makes **no network calls** — no token, no
registry, no cloud egress. That is why it, not Semgrep, is the right Free-tier tool here (see
Rejected). It fits the template's offline, no-external-service stance without qualification.

### Stated boundary (in the template's own idiom)

Two boundaries go in `SECURITY.md` alongside the merge-not-push and SCA-tier boundaries:

1. *Bandit is AST-pattern analysis, not cross-file dataflow. It flags shapes, not proven exploit
   paths, and it will both miss dataflow bugs and false-positive on safe patterns.*
2. *Bandit sees the `python` stack only. The `node` and `next` stacks' first-party TypeScript is
   **unscanned** until Part B (CodeQL) lands at the Team cutover.* This gap is named, not hidden —
   a failure to verify is not a verified pass.

Suppression is in-code `# nosec` (or a checked-in `[tool.bandit]` skip list). Named as a rot risk of
the same class as Item 1's boundary: a suppression is a silent, un-expiring hole, and without a
Security-tab dismissal trail the only control is code review of the diff that adds it.

### Open decisions for the plan

- Exact wiring: a dedicated `bandit` job vs. a step in the existing `ci` job; how the `python`-only
  scope is expressed so `node`/`next` repos don't run it.
- Config location: `pyproject.toml` `[tool.bandit]` vs. a `.bandit` file — follow whatever the
  `python` stack already uses for tool config.
- The plan **must** confirm Item 1's policy value exists and is the exact key Part A reads (see
  Dependencies).

---

## Part B — CodeQL cross-file SAST (deferred to Team)

CodeQL is the **depth upgrade**, not a competitor to Part A: it does cross-file / cross-function
taint analysis for **Python *and* TypeScript**, which closes Part A's stated `node`/`next` gap and
adds real dataflow to the Python stack. It requires GitHub Advanced Security, so it cannot run on
private + Free and is part of the Team cutover.

Recorded so it is not re-litigated later; **not resolved here, and no dormant workflow is committed**
(a no-op file that ships now and silently does nothing is exactly the enforcement theater the parent
doc rejects):

- **Default setup vs. committed advanced workflow.** Default setup is one toggle and auto-updates;
  an advanced `codeql-analysis.yml` is version-controlled and CODEOWNERS-guardable but must be
  SHA-pinned and lockstepped like every other action (Item 3). Lean advanced, to keep the control
  committed and reviewed — confirm at cutover.
- **Warn vs. block per tier.** Mirror Item 1 / Part A: `client-facing` blocks on high, `internal`
  warns. CodeQL severity maps to the same committed policy value.
- **Relationship to Part A.** Once CodeQL covers Python, decide whether Bandit stays as a fast
  pre-Team gate or is retired to avoid double-reporting. Default: keep Bandit (it is free, local, and
  faster); dedupe noise via tier discipline.

---

## Part C — Org-cutover research protocol (the spine; Team-gated)

The two questions carried open since the org-ruleset design
([`docs/ADOPTION.md`](../../ADOPTION.md) §3) are **unanswerable on Free and gate correctness, not
polish** — they decide whether the emergency-bypass story in `CONTRIBUTING.md` is true or fiction. So
this part is a **research protocol, run first, on Team**: for each question, the exact probe, both
possible answers, and what each answer *forces*. It is deliberately not an implementation plan —
there is nothing correct to implement until these return.

### Q1 — Does a repo creator in `Avenue-Z` receive the **Admin** role on the repo they create?

This decides who can run [`apply-rulesets.sh`](../../../scripts/apply-rulesets.sh) — repo-level
protection requires admin on the repo.

**Probe (on Team, as a non-owner org member):**

```
# 1. A plain member creates a repo (or is given one created via the template).
# 2. Query that member's own permission on it:
gh api repos/Avenue-Z/<test-repo>/collaborators/<creator-login>/permission -q .permission
# expect: "admin" | "maintain" | "write"
```

| Answer | What it forces |
|---|---|
| **`admin`** | Repo creators self-serve protection. `apply-rulesets.sh` works for any member on repos they create; `CONTRIBUTING.md` can state "you own protection on repos you create." Adoption playbook unchanged. |
| **`maintain`/`write`** | Non-owner creators **cannot** apply repo rulesets. `apply-rulesets.sh` must be run by an org owner (or protection comes only from the org ruleset). The adoption playbook and `CONTRIBUTING.md` must reassign that step to an owner — a real change to the net-new flow in `ADOPTION.md §1`. |

### Q2 — Does a repo-level **bypass actor survive an org-level ruleset**, or does the org ruleset outrank it?

This decides whether an emergency break-glass at the repo level even functions once the org ruleset
(`enforcement=active`, `bypass_actors=[]`) is live. The likely answer from GitHub's layering
semantics is *org outranks* — rulesets are additive and the most-restrictive wins, each ruleset's
bypass list applying only to itself — but it **must be confirmed empirically**, because being wrong
here means either a break-glass that silently doesn't work or a false claim of one.

**Probe (on Team):**

```
# 1. Apply the org ruleset (bypass_actors=[]) via scripts/apply-org-ruleset.sh.
# 2. On a test repo, add a REPO ruleset that names an admin as a bypass actor.
# 3. As that admin, attempt a direct push to a protected branch:
git push origin HEAD:main    # on the test repo
```

| Answer | What it forces |
|---|---|
| **push blocked → org outranks; repo bypass does NOT survive** | There is **no repo-level break-glass** while the org ruleset is active. Emergencies require editing/disabling the *org* ruleset — the highest-blast-radius action in the repo. `CONTRIBUTING.md`'s emergency procedure must say so loudly, and the org ruleset itself becomes the single break-glass surface. |
| **push succeeds → repo bypass survives** | Repo owners can define a working per-repo break-glass actor even under the org ruleset. Document the pattern; the emergency-bypass design as sketched is viable. |

### Rollout mechanics (already built; runs after Q1/Q2 answer)

The org rollout tool exists and is deliberately hard to run:
[`scripts/apply-org-ruleset.sh`](../../../scripts/apply-org-ruleset.sh) (typed live-count challenge,
no `--yes`, refuses a required-status-check payload). Part C adds **no new tooling** — it gates the
*run* of that script on Q1/Q2 landing, and folds their answers into `CONTRIBUTING.md` before the
first org-wide apply.

### SCA tooling swap (Team)

Per the parent doc's sequencing: on Team, swap Item 1's `osv-scanner` for GitHub's
`dependency-review-action` in warn/block mode per tier. Same tier policy value, better native
integration. Recorded here to keep the cutover checklist in one place; no design change.

---

## Dependencies

- **Part A reads Item 1's policy value.** Item 1's committed, CODEOWNERS-guarded tier file/variable
  must exist and be merged first; Part A's plan must confirm the exact key it reads. As of this
  writing the parent hardening spec (and Item 1) live on `docs/sca-and-hardening-additions` and are
  **not yet on `dev`** — Part A cannot merge ahead of it.
- Parts B and C depend only on the org reaching GitHub Team.

## Sequencing

- **Now (Free):** Part A (Bandit on the `python` stack), after Item 1 merges.
- **At Team cutover:** Part C research protocol **first** (Q1, Q2), then `CONTRIBUTING.md` updates,
  then the org-ruleset apply, then Part B (CodeQL) and the osv → `dependency-review-action` swap.

Part A is a small standalone plan (or folds into Item 1's plan). Parts B + C are a single Team-cutover
plan, gated on the research protocol.

## Testing

- **Part A:** a `template-tests/` case asserting (a) the Bandit gate ships with the `client-facing`
  default (fail-safe), (b) it reads Item 1's committed policy value rather than a second dial, and
  (c) the block threshold is **high-severity-AND-high-confidence**, encoded in the workflow logic,
  not just prose. Optionally a negative test: a `python` stack with a seeded high/high finding must
  make `ci` go red on `client-facing`, green on `internal`.
- **Parts B & C:** out of scope for CI tests — B is Team-gated config and C is research whose output
  is decisions and `CONTRIBUTING.md` prose. Their verification is the probe results themselves.

## Rejected (pressure-tested out)

- **Semgrep OSS instead of Bandit** — its cross-file/cross-function taint (the part that would beat
  Bandit) is **paywalled** in Semgrep's Pro tier, so on OSS you get single-file pattern matching, the
  same class Bandit gives — while adding a registry/network dependency (`registry.semgrep.dev`, an
  optional `SEMGREP_APP_TOKEN` with findings egress to their cloud) and a larger third-party
  supply-chain surface to SHA-pin. Trading GitHub's paywall for Semgrep's, at a higher integration
  and egress cost, for no depth gain on Free. Bandit is free, local, and offline. Revisit Semgrep
  only if it replaces CodeQL for TS coverage before the org reaches Team.
- **A dormant/no-op CodeQL workflow committed now** — ships non-functional config that reads as
  coverage and does nothing; the exact theater the parent doc rejects. CodeQL lands at Team, live.
- **A separate SAST policy dial** — three levels or a Bandit-specific tier is the severity matrix in
  a policy costume. Part A reuses Item 1's two tiers; one honest dial, not two.
- **Attempting Part C now on Free** — the probes cannot return a valid answer without Team; running
  them on Free would launder "could not ask" into a false "it works," the precise failure
  `apply-org-ruleset.sh` was written to refuse.

## Out of scope

- CodeQL implementation and the org-wide apply (both Team-gated; their own plan).
- Any change to Items 1–3.
