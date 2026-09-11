# 2026-09-11 — Phase A: `v1` cut, protected, and both refusal paths observed

Phase A Task 10 Step 6. **Phase B starts from this state.** Everything below was *observed* unless it
says otherwise — the distinction matters, because the next person's default assumption should be that
nothing is proven until it has been watched.

## Tag state

| Tag | SHA | Note |
|---|---|---|
| `v1.0.0` | `79e1f30616f7166b2dc8e2b2af88c7c7d2ceb455` | Hand-cut, the one time a human touches the tag |
| `v1.1.0` | `91247ce15dd842d6b901b11a779e7538e1681783` | First automated advance |
| `v1.2.0` | `5d1617763fcd8fee895a0a0791302c89e3c0324f` | Cut when the Step 5 probe was reverted |
| `v1` | `5d1617763fcd8fee895a0a0791302c89e3c0324f` | Moving; owned by `advance-v1.yml` from here on |

The point tags are immutable and were never touched by an advance — `v1.0.0` still resolves to the
commit it was cut at after two advances, so "pin to the last good version" is a sentence with a real
argument behind it.

## The bypass actor is NOT what the design said

The design and the plan both specified the **GitHub Actions app** as the tag ruleset's bypass actor,
looked up via `gh api /repos/.../installation`. **Neither half works:**

- that endpoint needs a GitHub App JWT and returns 401 for a user token
- the rulesets API refuses app `15368` outright — `Actor GitHub Actions integration must be part of
  the ruleset source or owner organization`. GitHub Actions is not an installable app and never
  appears in `/orgs/Avenue-Z/installations`

So the bypass is a **dedicated GitHub App**, and `advance-v1.yml` authenticates as it:

| Thing | Value |
|---|---|
| App | `avenue-z-v1-tag-advance` |
| App id (the ruleset's `actor_id`) | `4911635` |
| Installed on | `repo-template` only (`repository_selection: selected`) |
| Repo secrets | `V1_TAG_APP_ID`, `V1_TAG_APP_PRIVATE_KEY` |
| Ruleset | id `22951344`, `v1-tag-protection`, target `refs/tags/v1`, rules `deletion` + `non_fast_forward` |

GITHUB_TOKEN in `advance-v1.yml` is `contents: read`. This **closes** spec Open item 8 rather than
accepting it: under the old design any workflow requesting `contents: write` inherited the bypass;
now that permission moves nothing. The residual is the secret — repo secrets are readable by any
workflow in the repo — and the unpriced hardening is an `advance-v1` environment with deployment
branches restricted to `main`.

## Step 4 — the protection is real in both directions

**It refuses a human.** A deliberate force-push of `v1` onto `main~1`, by an org admin:

```
remote: error: GH013: Repository rule violations found for refs/tags/v1.
remote: - Cannot force-push to this tag
 ! [remote rejected] v1 -> v1 (push declined due to repository rule violations)
```

The ruleset also self-reports `current_user_can_bypass: never` for an org admin.

**It permits the workflow.** Promoting the app-token change to `main` ran `advance-v1` with the app
token for the first time: it moved `v1` from `79e1f30` to `91247ce` and cut `v1.1.0`. Run
`34633508030`.

## Step 5 — the sticky refusal, observed in production

A deliberate additive contract change (a `probe` input with a default, moved in `checks.yml` **and**
`.github/reusable-contract.json` together so the tripwire suite stayed green) was promoted to `main`.
`advance-v1` refused — run `34633917633`:

```
::error::.github/reusable-contract.json has changed since v1 — the consumer-visible surface moved.
Cut v2 by hand if this is a break (a renamed job, a required input, or a new failure
```

`main` advanced to `770920d`; **`v1` did not move.** Reverting the probe restored the surface to
byte-identical with what `v1` pointed at, and the next advance proceeded normally (`v1.2.0`). So the
refusal is sticky *and* clears on human action — both halves of the property, not just the first.

## Still open going into Phase B

1. **Actions billing is NOT restored.** This was misread earlier in the day: `repo-template` is
   **public**, so its Actions minutes are free and every green run here proves nothing about billing.
   The first private-repo run failed instantly — `The job was not started because recent account
   payments have failed or your spending limit needs to be increased`. **Phase B's pilot,
   `data-warehouse`, is private, so Phase B is hard-blocked until this is fixed.** So is the
   companion marketplace PR's own gate.
2. **The three Step 0 mechanics remain unverified** and cannot be answered from inside this repo:
   private→public reusable-workflow execution, `actions/checkout` resolution inside a called workflow,
   and whether a consumer's default `GITHUB_TOKEN` can check out `Avenue-Z/repo-template` at all.
3. **Layer 4 is unproven** — "a failing gate turns the *caller* red" needs a real consumer.
4. **No consumer calls `v1` yet.** Everything above is the template proving things about itself.
