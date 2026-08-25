# The correctness gate. `make check` is the single aggregate command every stack shares, so
# it runs identically in any generated repo, and ci.yml calls this same target — one definition,
# invoked from both places, so the local command and the CI gate can never drift.
# Deps are installed separately (`pip install -e ".[dev]"`), by CI and once locally.
# Security scans (secret-scan, sca, bandit) are separate CI jobs, not part of this target.
.PHONY: check
check:
	ruff check .
	mypy
	pytest -q
