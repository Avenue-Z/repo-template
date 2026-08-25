# The correctness gate. `make check` is the single aggregate command every stack shares, so
# it runs identically in any generated repo, and ci.yml calls this same target — one definition,
# invoked from both places, so the local command and the CI gate can never drift.
# Deps are installed separately (`npm ci`), by CI and once locally.
# Security scans (secret-scan, sca) are separate CI jobs, not part of this target.
#
# `build` is not redundant with `typecheck` for a Next app the way it would be for a library:
# a project that type-checks clean can still fail `next build` (a bad route export, a
# server/client boundary violation, a missing env var at build time). Vercel runs this build on
# every deploy, so the correctness gate must run it too — otherwise the first place a broken
# build surfaces is the deploy itself.
.PHONY: check
check:
	npm run lint
	npm run typecheck
	npm test
	npm run build
