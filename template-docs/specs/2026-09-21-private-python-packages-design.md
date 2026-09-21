# Installing the private Python clients without GitHub tokens — design

## Why this exists

Two shared Python packages are private GitHub repos: `glean-chat-api-client` (`glean_chat`) and
`drive-api-client` (`drive_client`). Consumers install them straight from git
(`pkg @ git+https://github.com/Avenue-Z/...`), which makes pip run `git clone`. That works on a
laptop with SSH or `gh auth setup-git` configured, and **fails in every CI and Cloud Build run**,
because nothing there holds a credential that can read a *second* private repo:

- The automatic `GITHUB_TOKEN` in Actions is scoped to the repo the workflow runs in. It cannot read
  any other private repo, same org or not.
- Cloud Build has no GitHub credential at all.

The usual advice for that error is "mint a PAT". Repos have followed it, in five different ways, and
the two marketplace skills that route people to these clients recommend a form that can never work:

- `claude-marketplace/plugins/glean/skills/glean-chat-client/SKILL.md:35` and
  `plugins/drive/skills/drive-api-client/SKILL.md:36` both say *CI without SSH:
  `git+https://${GITHUB_TOKEN}@github.com/Avenue-Z/...`*. `GITHUB_TOKEN` cannot read another repo, so
  every repo that follows the skill fails and then goes looking for a PAT.
- `drive-api-client/SKILL.md:33` pins `@v0.1.0`; the current tag is `v0.2.0`.

This design replaces git installs with a private Python package index in Google Artifact Registry.
Access becomes IAM: native on Cloud Build/Cloud Run, keyless from GitHub Actions via Workload Identity
Federation. No GitHub token of any kind is involved.

Making the two repos public would have removed the problem entirely (`data-contract` works that way).
**That option was declined**: the clients stay private.

## Established

Checked during design, on 2026-09-21.

1. **Visibility.** `data-contract` and `repo-template` are public; `glean-chat-api-client` and
   `drive-api-client` are private (`gh repo view --json visibility`).
2. **The clients build with hatchling** and carry a version in `pyproject.toml`:
   `glean-chat-api-client` 0.1.0 (tag `v0.1.0`), `drive-api-client` 0.2.0 (tag `v0.2.0`). Neither
   has a release workflow; `drive-api-client` has a `ci.yml`, `glean-chat-api-client` has no
   workflows.
3. **Eight consumers**, found by reading `pyproject.toml`, `requirements.txt`, `Dockerfile` and
   `cloudbuild.yaml` in every Avenue-Z repo (org-wide code search returned nothing and is not a
   reliable inventory):

   | Repo | Package | How it installs today |
   |---|---|---|
   | pptx-report-filler | drive | `git+ssh` @ v0.2.0 in `requirements.txt` |
   | noble-clone | drive | `git+https` @ v0.2.0 in `pyproject.toml` |
   | pr-aeo-report | glean | `git+ssh` @ v0.1.0, optional `live` extra; `Dockerfile` has a commented build-secret recipe |
   | narrative-control-gap-finder | glean | bare `glean-chat-api-client`, unpinned, no source |
   | automation-intake-agent | glean | wheel checked into `vendor/`, installed by `Dockerfile` |
   | cross-model-competitor-analysis | glean | vendored into `/app/vendor` on `PYTHONPATH` |
   | monthly-report-agent | glean | **PAT as Docker build `ARG`** via `cloudbuild.yaml` (`_GH_PAT` substitution) |
   | visibility-drop-root-cause-engine | glean | **PAT as Docker build `ARG`** |

4. **Two repos may have leaked a PAT into their images.** A value passed with `ARG` and used in a
   `RUN` is recorded in the image's layer history; anyone who can pull the image can read it with
   `docker history --no-trunc`. Whether the pushed images actually expose it is **not yet checked**
   (§3).
5. **Workload Identity Federation is already in use in the org.** `auto-slide-decks` deploys to Cloud
   Run from Actions with `google-github-actions/auth@v2` and a WIF provider in project
   `automated-slide-deck`, region `us-central1`. Other apps run in `us-east4`. GCP projects are
   per-app.
6. **Artifact Registry pricing** (cloud.google.com/artifact-registry/pricing): storage is free up to
   0.5 GiB per *billing account*, then about $0.10/GiB-month; transfer from a multi-region to a
   Google Cloud service on the same continent is free; transfer to the internet (GitHub-hosted
   runners) is billed at Premium-tier internet egress. Vulnerability scanning is billed per container
   image and does not apply here.

### OPEN — verify during implementation, before relying on them

- **O1.** Artifact Registry rejects a second upload of an existing Python package version (so
  versions are immutable). §2 relies on this; if it does not hold, the release workflow must check
  for the version before uploading.
- **O2.** A principal with `artifactregistry.reader` on the **virtual** repo can install packages that
  resolve from its upstreams without its own grant on each upstream.
- **O3.** Cloud Build's `gcr.io/cloud-builders/docker` step honours `--secret` with
  `DOCKER_BUILDKIT=1`.
- **O4.** Which service account each consumer's Cloud Build / Cloud Run build runs as (legacy Cloud
  Build SA vs. default compute SA vs. a custom one). The read grant in §1 goes to that account.

## Section 1 — The registry

A new GCP project, **`avenue-z-shared-artifacts`**, with its own billing link and nothing else in it.
Its lifetime and permissions are not tied to any app.

Artifact Registry, location **`us`** (multi-region), so that downloads from every US region any app
runs in (`us-central1`, `us-east4`) are free:

| Repo | Mode | Contents |
|---|---|---|
| `python-private` | standard, Python | Our wheels and sdists only. |
| `pypi` | remote, upstream PyPI | Cache of public PyPI. |
| `python` | virtual | Upstreams: `python-private` priority 100, `pypi` priority 10. |

**`python` is the only URL anyone uses:**

    https://us-python.pkg.dev/avenue-z-shared-artifacts/python/simple/

Because the virtual repo resolves a name from the higher-priority upstream first, a package on public
PyPI with the same name as one of ours cannot be installed in its place. That is the
dependency-confusion control, and it is why consumers use `--index-url` (single index), never
`--extra-index-url` (pip merges indexes and takes the highest version from any of them).

### Identities

All grants are on individual repositories, not the project.

- **Workload Identity pool** `github` with an OIDC provider for `token.actions.githubusercontent.com`:
  - attribute condition: `assertion.repository_owner_id == '<Avenue-Z org id>'`. The numeric ID,
    not the name, so a renamed or re-registered org name cannot satisfy it.
  - attribute mappings: `attribute.repository = assertion.repository`,
    `attribute.release = assertion.repository + ':' + assertion.ref_type`.
- **`pkg-publisher@`** service account: `artifactregistry.writer` on `python-private` only.
  Impersonable by `principalSet://…/attribute.release/Avenue-Z/glean-chat-api-client:tag` and
  `…/drive-api-client:tag`. A branch push or a PR in those repos cannot publish; neither can any
  other repo.
- **`pkg-reader@`** service account: `artifactregistry.reader` on `python`. Impersonable by any
  identity in the pool (i.e. any Avenue-Z repo).
- **Each consumer's build service account** (O4): `artifactregistry.reader` on `python`, granted
  cross-project. One grant per consuming GCP project.
- **Developers**: `artifactregistry.reader` on `python`, via a Google group.

No service-account key is created at any point.

### Cost

Storage for two small packages is a few MB; the PyPI cache is at most a few hundred MB. Cloud Build and
Cloud Run downloads are free (multi-region → same continent). The only line that scales is GitHub
Actions installs, which are internet egress: routing all PyPI traffic through `python` costs roughly
200 MB × runs per month. Every consumer's CI **must** enable pip caching
(`actions/setup-python` `cache: pip`), which makes most runs download almost nothing. Expected total:
under $5/month.

## Section 2 — Publishing (in each client repo)

A new `.github/workflows/release.yml` in `glean-chat-api-client` and `drive-api-client`:

    on: push: tags: ['v*']
    permissions: { contents: read, id-token: write }

Steps:

1. Fail unless the tag, minus the leading `v`, equals `project.version` in `pyproject.toml`. Nothing
   is built or uploaded on a mismatch.
2. Run the tests (`pip install -e '.[dev]' && pytest`).
3. `python -m build` → wheel + sdist.
4. `google-github-actions/auth@v2` as `pkg-publisher`.
5. `pip install twine keyrings.google-artifactregistry-auth` and
   `twine upload --repository-url https://us-python.pkg.dev/avenue-z-shared-artifacts/python-private/ dist/*`.

Versions are immutable once published (O1). The release process is: bump `version`, merge, push the
matching tag.

**Backfill.** The existing tags (`glean-chat-api-client` v0.1.0, `drive-api-client` v0.2.0) are
published once, by running the same build and upload from a checkout of each tag, so consumers can
switch index without also switching version.

**Failure visibility.** A failed release fails the tag's workflow run, which notifies the pusher. A
version mismatch fails at step 1, before anything reaches the registry.

## Section 3 — Migrating the consumers

One PR per repo, through that repo's normal branch flow.

### The common change

**Dependency.** `glean-chat-api-client @ git+…@v0.1.0` → `glean-chat-api-client==0.1.0` (and likewise
`drive-api-client==0.2.0`), wherever it is declared.

**GitHub Actions**, in any job that installs dependencies:

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - uses: actions/setup-python@v5
    with: { python-version: '3.12', cache: pip }
  - uses: google-github-actions/auth@v2
    with:
      workload_identity_provider: projects/<num>/locations/global/workloadIdentityPools/github/providers/github
      service_account: pkg-reader@avenue-z-shared-artifacts.iam.gserviceaccount.com
  - run: pip install keyrings.google-artifactregistry-auth
  - run: pip install -r requirements.txt
    env:
      PIP_INDEX_URL: https://us-python.pkg.dev/avenue-z-shared-artifacts/python/simple/
```

**Docker builds** (Cloud Build or Actions). A short-lived access token is passed **only** as a
BuildKit secret, never as `ARG` or `ENV`:

```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=secret,id=ar_token \
    PIP_INDEX_URL="https://oauth2accesstoken:$(cat /run/secrets/ar_token)@us-python.pkg.dev/avenue-z-shared-artifacts/python/simple/" \
    pip install --no-cache-dir -r requirements.txt
```

In `cloudbuild.yaml`: one step writes `gcloud auth print-access-token` to `/workspace/ar_token`, the
build step runs with `DOCKER_BUILDKIT=1` and `--secret id=ar_token,src=/workspace/ar_token` (O3). In
Actions: after `auth`, `--secret id=ar_token,env=AR_TOKEN` with `AR_TOKEN` from
`gcloud auth print-access-token`. The token lives about an hour and is not written to any layer.

**Laptops**, once per developer: `gcloud auth login`,
`pip install keyrings.google-artifactregistry-auth`, and `PIP_INDEX_URL` set as above (or in
`pip.conf`).

### Per repo

| Repo | Beyond the common change |
|---|---|
| pptx-report-filler | — |
| noble-clone | — |
| pr-aeo-report | Replace the commented `x-access-token` recipe in the `Dockerfile` with the build-secret recipe. |
| narrative-control-gap-finder | Pin `==0.1.0`; today it has no source and no version. |
| automation-intake-agent | Delete the checked-in wheel and the `Dockerfile` line that installs it. |
| cross-model-competitor-analysis | Delete the vendored copy and its `PYTHONPATH` entry; add the pin. |
| monthly-report-agent | PAT cleanup, below. Remove the `GH_PAT` `ARG` and the `_GH_PAT` substitution. |
| visibility-drop-root-cause-engine | PAT cleanup, below. Remove the `GH_PAT` `ARG` and its conditional install branch. |

### PAT cleanup (monthly-report-agent, visibility-drop-root-cause-engine)

Done as part of each repo's migration PR, in this order:

1. Inspect the published images with `docker history --no-trunc` and record whether the token is
   visible. This determines how far step 3 has to reach.
2. Merge the migration and confirm a build and deploy succeed **without** the PAT.
3. Revoke the PAT. A fine-grained token is visible to org owners under *Organization settings →
   Personal access tokens*; a classic token can only be revoked by its owner.
4. Delete every image version built with the `ARG` from its registry.
5. Delete the `_GH_PAT` substitution from the Cloud Build trigger and any `GH_PAT` secret in the repo
   or the trigger.

## Section 4 — The marketplace skills

In `Avenue-Z/claude-marketplace`, rewrite the install section of
`plugins/glean/skills/glean-chat-client/SKILL.md` and `plugins/drive/skills/drive-api-client/SKILL.md`
to contain:

- the dependency form (`==X.Y.Z`) and the current version;
- the index URL and why it is `--index-url`, never `--extra-index-url`;
- the GitHub Actions snippet and the Docker build-secret snippet from §3;
- the one-time laptop setup.

And these rules, stated as rules:

- Never install these packages with `git+ssh` or `git+https`.
- Never use `GITHUB_TOKEN` or a PAT to read another repo.
- Never pass a token as a Docker `ARG` or `ENV`.

Bump both plugins' versions in the marketplace manifest. Put the same install section in each client
repo's `README.md`, so the repo and the skill agree.

## Done when

1. `gcloud artifacts repositories describe python --location us` shows `python-private` at priority
   100 and `pypi` at 10.
2. Both client repos publish from a tag; a tag that does not match `pyproject.toml` fails before
   upload; a push to a branch cannot impersonate `pkg-publisher`.
3. All eight consumers pass CI on GitHub, and `monthly-report-agent` and
   `visibility-drop-root-cause-engine` build and deploy to Cloud Run through the new path.
4. Reading every Avenue-Z repo's dependency files finds no `git+…Avenue-Z/(glean-chat-api-client|drive-api-client)`,
   no `GH_PAT`, and no vendored copy of either package.
5. Both PATs are revoked and the images that carried them are deleted.
6. Both skills are updated and their plugins released.

## Rejected

- **Make the clients public.** Zero-auth and zero-cost, but declined: the clients stay private.
- **GitHub App installation token.** Tokens last an hour, so Cloud Build would need the App's private
  key in Secret Manager and code to mint a token per build, plus a second setup in every Actions
  workflow. A long-lived key to guard, in two places, for the same result.
- **Fine-grained PAT.** Belongs to one person, expires, breaks when they leave. This is the pattern
  being removed.
- **Deploy keys.** One key per client repo per consumer; does not scale past a handful.
- **`--extra-index-url` + placeholder packages reserved on PyPI.** Free, but safety depends on the
  placeholders staying registered, and it publishes the names.
- **Hash-pinned lockfiles in every consumer.** Safe and free, but changes dependency tooling in all
  eight repos to solve a problem the virtual repo solves once.

## Out of scope

- Making the registry setup a default in repo-template's Python stack or the reusable `python-ci.yml`.
  Worth doing once this is proven; separate spec.
- Publishing any other package (e.g. `data-contract`, which is public and works as is).
- Consumers that do not exist yet; they follow the updated skills.
