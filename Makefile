# marv-mlx release tooling.
#
#   make release              -> bump VERSION, commit, tag vX.Y.Z (local)
#
# Example flow:
#   make release VERSION=0.1.0
#   git push origin main v0.1.0
SHELL := /bin/bash

VERSION ?= $(shell cat VERSION)
TAG     := v$(VERSION)
REPO    := pavsefcik/marv-mlx

.PHONY: release check bump commit tag info test doctor

release: check doctor bump commit tag info

# Run the test suite: Python (stream filter, request body, pty integration)
# and zsh (thinking classifier/spec, launch flags).
test:
	python3 -m unittest discover -s tests
	zsh tests/test_helpers.zsh
	zsh tests/test_cli.zsh
	zsh tests/test_migration.zsh

# Refuse to tag a dirty tree.
check:
	@test -z "$$(git status --porcelain)" \
		|| { echo "git tree is dirty — commit or stash first"; exit 1; }
	@test -n "$(VERSION)"

# Keep VERSION + package.json in sync.
bump:
	@echo "$(VERSION)" > VERSION
	@perl -0pi -e 's/"version": *"[^"]*"/"version": "$(VERSION)"/' package.json

commit:
	git add VERSION package.json README.md
	git commit -m "Release $(VERSION)"

tag:
	git tag -a "$(TAG)" -m "marv-mlx $(VERSION)"
	@echo "Tagged $(TAG). Push with:"
	@echo "  git push origin main $(TAG)"

info:
	@echo "Release $(VERSION) tagged. Push with:"
	@echo "  git push origin main $(TAG)"

# Guard the installer invariants documented in AGENTS.md. `make test` covers
# behavior; this covers the things that silently *drift*: a version pin that
# stops matching between install.sh and the pi extension, a dropped --force,
# the invalid --bin-dir flag creeping back, or the APC marker going missing.
doctor:
	@sh -n install.sh || { echo "doctor: install.sh does not parse"; exit 1; }
	@grep -q 'mlx-vlm@0.7.4' install.sh || { echo "doctor: install.sh lost the mlx-vlm pin"; exit 1; }
	@grep -q -- '--with setproctitle' install.sh || { echo "doctor: install.sh lost setproctitle"; exit 1; }
	@grep -q -- '--force' install.sh || { echo "doctor: install.sh lost --force"; exit 1; }
	@grep -q -- '-ge 3' install.sh || { echo "doctor: install.sh lost the 3-attempt retry"; exit 1; }
	@if grep -q -- '--bin-dir' install.sh; then echo "doctor: install.sh passes --bin-dir (invalid flag)"; exit 1; fi
	@grep -q 'astral.sh/uv/install.sh' install.sh || { echo "doctor: install.sh lost the brew-free uv installer"; exit 1; }
	@grep -q 'charmbracelet/gum/releases' install.sh || { echo "doctor: install.sh lost the gum release binary"; exit 1; }
	@grep -q 'GUM_SHA256="4777a69b' install.sh || { echo "doctor: install.sh lost the pinned gum sha256"; exit 1; }
	@if grep -q 'Xcode CLT not installed' install.sh; then echo "doctor: install.sh gates on Xcode CLT again"; exit 1; fi
	@grep -q 'mlx-vlm@0.7.4' extensions/marv-mlx.ts || { echo "doctor: pi extension pin drifted from install.sh"; exit 1; }
	@grep -q 'setproctitle' extensions/marv-mlx.ts || { echo "doctor: pi extension lost setproctitle"; exit 1; }
	@grep -q -- '--force' extensions/marv-mlx.ts || { echo "doctor: pi extension lost --force"; exit 1; }
	@grep -q 'attempt <= 3' extensions/marv-mlx.ts || { echo "doctor: pi extension retry count drifted from install.sh"; exit 1; }
	@grep -q 'astral.sh/uv/install.sh' extensions/marv-mlx.ts || { echo "doctor: pi extension lost the brew-free uv installer"; exit 1; }
	@grep -q 'charmbracelet/gum/releases' extensions/marv-mlx.ts || { echo "doctor: pi extension lost the gum release binary"; exit 1; }
	@grep -q 'GUM_SHA256 = "4777a69b' extensions/marv-mlx.ts || { echo "doctor: pi extension gum sha drifted from install.sh"; exit 1; }
	@grep -q 'marv-mlx APC sitecustomize' lib/marv-mlx-apc-sitecustomize.py || { echo "doctor: APC sitecustomize marker missing"; exit 1; }
	@grep -q -- '-Fpcn' lib/marv-mlx-helpers.zsh || { echo "doctor: lsof field list lost 'n' (live-server guard goes inert)"; exit 1; }
	@n=$$(grep -c '^## \[Unreleased\]' CHANGELOG.md); \
	  [ "$$n" -eq 1 ] || { echo "doctor: expected exactly one '## [Unreleased]' heading, found $$n - two writers edited CHANGELOG.md?"; exit 1; }
	@echo "doctor: installer invariants OK"
