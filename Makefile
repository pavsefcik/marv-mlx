# ymlx release tooling.
#
#   make release              -> bump VERSION, commit, tag vX.Y.Z (local)
#   make formula              -> rewrite the Homebrew formula sha256/url from the
#                                actual GitHub tarball (run AFTER pushing the tag)
#
# Example flow:
#   make release VERSION=0.1.0
#   git push origin main v0.1.0
#   make formula
#   (cd ../homebrew-ymlx && git add Formula && git commit -m "ymlx 0.1.0" && git push)
SHELL := /bin/bash

VERSION ?= $(shell cat VERSION)
TAG     := v$(VERSION)
REPO    := pavsefcik/ymlx
# Sibling checkout of the tap repo (create it with: git init ../homebrew-ymlx)
BREW    := ../homebrew-ymlx
FORMULA := $(BREW)/Formula/ymlx.rb

.PHONY: release check bump commit tag info formula test

release: check bump commit tag info

# Run the test suite: Python (stream filter, request body, pty integration)
# and zsh (thinking classifier/spec, launch flags).
test:
	python3 -m unittest discover -s tests
	zsh tests/test_helpers.zsh
	zsh tests/test_cli.zsh

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
	git tag -a "$(TAG)" -m "ymlx $(VERSION)"
	@echo "Tagged $(TAG). Push with:"
	@echo "  git push origin main $(TAG)"

info:
	@echo "After pushing the tag, refresh the tap formula hash:"
	@echo "  make formula"

# Recompute the Homebrew formula from the ACTUAL tarball GitHub serves for the
# current tag. Needs the tag pushed to GitHub first.
formula:
	@test -f "$(FORMULA)" || { echo "$(FORMULA) not found"; exit 1; }
	@test -n "$(TAG)"
	@curl -fsSL "https://github.com/$(REPO)/archive/refs/tags/$(TAG).tar.gz" \
		-o "/tmp/ymlx-$(TAG).tar.gz"
	@sha="$$(shasum -a 256 "/tmp/ymlx-$(TAG).tar.gz" | awk '{print $$1}')"; \
	sed -e "s|archive/refs/tags/v[^/]*\.tar\.gz|archive/refs/tags/$(TAG).tar.gz|" \
	    -e "s|^  sha256 .*|  sha256 \"$$sha\"|" "$(FORMULA)" > "$(FORMULA).tmp" \
	&& mv "$(FORMULA).tmp" "$(FORMULA)"; \
	echo "Updated $(FORMULA)"; \
	echo "  url    -> .../archive/refs/tags/$(TAG).tar.gz"; \
	echo "  sha256 -> $$sha"; \
	echo "Commit and push inside $(BREW)."
