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

.PHONY: release check bump commit tag info test

release: check bump commit tag info

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
