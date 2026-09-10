#!/usr/bin/env bash
# Decision logic for the guard-base-branch workflow.
#
# Enforces the branch-promotion matrix from CONTRIBUTING.md:
#   feat/* | fix/* | docs/* | chore/* | ci/* | dependabot/* | perf/* | refactor/* | test/*  ->  dev
#   dev                                                                                      ->  staging
#   staging                                                                                  ->  main
#
# Any other head-branch prefix FAILS CLOSED (exit 1).
#
# Usage: check-base-branch.sh <head_ref> <base_ref>
set -euo pipefail

head_ref="${1:?usage: check-base-branch.sh <head_ref> <base_ref>}"
base_ref="${2:?usage: check-base-branch.sh <head_ref> <base_ref>}"

case "$head_ref" in
  feat/*|fix/*|docs/*|chore/*|ci/*|dependabot/*|perf/*|refactor/*|test/*) want=dev ;;
  dev)                                                                    want=staging ;;
  staging)                                                                want=main ;;
  *)
    echo "::error::Unrecognized branch prefix '${head_ref}'. This guard FAILS CLOSED."
    echo "Allowed: feat/ fix/ docs/ chore/ ci/ dependabot/ perf/ refactor/ test/ — or dev, staging."
    # THIS OUTPUT IS THE AUTHORITATIVE STATEMENT OF THE MATRIX. The script is central now: it is
    # staged from the template, and the repo the contributor is standing in does not contain it.
    # Each generated repo's CONTRIBUTING.md is a copy that drifts from this list the first time a
    # prefix is added, so the copies defer to this message rather than restating it.
    case "$head_ref" in
      feature/*)  echo "Did you mean 'feat/'? Use feat/, not feature/ — it is the conventional-commit type." ;;
      revert*)    echo "Reverts are done manually, as fix/ branches. There is deliberately no revert prefix." ;;
      security/*) echo "A security fix is still a fix/ branch (a dependency bump is fix(deps):, so fix/)." ;;
    esac
    echo "Need a new prefix? Open a PR against Avenue-Z/repo-template — this guard is shared by every repo."
    exit 1
    ;;
esac

if [ "$base_ref" != "$want" ]; then
  echo "::error::'${head_ref}' must target '${want}', not '${base_ref}'. See CONTRIBUTING.md."
  exit 1
fi

echo "OK: '${head_ref}' -> '${base_ref}'"
