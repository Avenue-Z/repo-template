#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=template-tests/lib.sh disable=SC1091
source template-tests/lib.sh

# ---------------------------------------------------------------------------------------
# TRIGGERS ARE THE ONE THING A REUSABLE WORKFLOW CAN NEVER PROPAGATE.
#
# `workflow_call` carries the DECISIONS — jobs, steps, matrix, pinned action SHAs. It cannot carry
# `on:`, because a called workflow does not define triggers for its consumers. So a repo's trigger
# set is fixed at birth by what init-repo.sh copies in, and changing it later is a PR per repo,
# forever. That makes the templates' `on:` block the only place this is cheap to get right, and the
# reason it is asserted here rather than left to review.
#
# WHY `push: [main]` AND NOT [dev, staging, main]. A change walks feat -> dev -> staging -> main, so
# with all three branches it is built SIX times: three PR runs and three push runs. The three push
# runs re-build merge commits whose content was just built as the PR head. checks.yml already made
# exactly this trade — it dropped its push triggers for a cron, documented as "~30 billed jobs a
# month to re-scan commits that had just been scanned as PR heads" — and Avenue-Z has since run out
# of Actions minutes org-wide, so this is a measured lesson rather than a theoretical saving.
#
# `main` SURVIVES deliberately. Every commit there arrived through a PR that was built, but a
# promotion merge that resolves a conflict produces content no PR run ever saw. One push run on main
# is what covers that, and it is one job rather than three.

STACKS=(python node next)

for s in "${STACKS[@]}"; do
  wf="templates/${s}/.github/workflows/ci.yml"
  assert_file "${s}: ci.yml exists" "$wf"

  # PyYAML resolves an unquoted `on:` key to the BOOLEAN True (the YAML 1.1 y/n/on/off rule), so
  # d['on'] returns None on a perfectly valid workflow and every assertion below would pass
  # vacuously against an empty dict. Accept either key — the same guard test_reusable_contract.sh
  # carries, for the same reason.
  if ! err="$(python3 - "$wf" "$s" 2>&1 <<'PYCHK'
import sys, yaml
path, stack = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(path))
on = d.get('on', d.get(True))
if on is None:
    sys.exit(f"{stack}: could not read the `on:` block at all")
if 'pull_request' not in on:
    sys.exit(f"{stack}: ci.yml must still run on pull_request — that is the gate that guards a merge")
push = on.get('push')
if push is None:
    sys.exit(f"{stack}: ci.yml declares no push trigger; main must keep one so a conflict resolved "
             f"inside a promotion merge is still built")
branches = push.get('branches') if isinstance(push, dict) else None
if branches != ['main']:
    sys.exit(f"{stack}: push.branches must be exactly ['main'], got {branches!r}. dev and staging "
             f"re-build commits that were just built as PR heads — six runs per change instead of four")
PYCHK
)"; then
    fail "$err"
  else
    pass "${s}: triggers are pull_request + push:[main] only"
  fi
done

finish
