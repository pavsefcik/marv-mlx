# Changelog fragments

Agents and contributors write **one fragment per change** here instead of
editing the top of `CHANGELOG.md`. Editing a shared version heading from two
concurrent writers is the failure this prevents: two sections and a
half-bumped `VERSION` landing in one working copy.

## Convention

- File name: `<slug>.md` (short, kebab-case), e.g. `cache-clean-verbs.md`.
- Content: Keep a Changelog headings and bullets only — no version heading, no
  date, no `VERSION`/`package.json`/README edit. Start at `### Added` /
  `### Changed` / `### Fixed`.

```markdown
### Added

- **`marv-mlx frobnicate`.** One-line description, then the observable
  behaviour and how it was verified.
```

## At release

`make release VERSION=X.Y.Z` expects the fragments to have been folded into
`CHANGELOG.md` under the new version heading first; delete the fragment files in
that same commit. Nothing in this directory survives a release.

`make doctor` fails if `CHANGELOG.md` has more than one `## [Unreleased]`
heading, which is the signature of two writers sharing a tree.
