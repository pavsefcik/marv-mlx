#!/usr/bin/env python3
"""Migrate cached models out of huggingface_hub's Xet shared-blob store.

huggingface_hub >= 1.33 caches Xet-served files (large .safetensors, tokenizers)
in a cache-wide store at <cache>/blobs/<first-2-hex>/<xet-hash> and leaves only a
symlink in each model's own blobs/ dir. marv-mlx keeps every model self-contained, so
this tool:

  1. finds each model symlink that points into the shared store,
  2. copies the payload back into the model's own blobs/ dir as a regular file,
  3. rewrites each store payload's .refs manifest to drop migrated references, and
  4. deletes store payloads (and their .refs/.lock sidecars) left unreferenced.

Idempotent: after a successful run there are no shared-store symlinks left, so a
re-run reports nothing to do. Use after enabling HF_HUB_DISABLE_SHARED_BLOBS=1 so
future downloads stay per-model.

Usage:
    python3 scripts/migrate-shared-blobs.py                # migrate default cache
    python3 scripts/migrate-shared-blobs.py --cache X      # custom cache dir
    python3 scripts/migrate-shared-blobs.py --dry-run      # show plan only
"""

import argparse
import os
import re
import shutil
import sys
from pathlib import Path

HASH_RE = re.compile(r"[0-9a-f]{64}")
MODEL_DIR_RE = re.compile(r"^(?:models|datasets|spaces|collections|metrics)--.+")
MARKER_NAME = ".huggingface-shared-blobs"


def _collect_refs(store: Path, hub: Path) -> dict[Path, list[Path]]:
    """Map each shared-store payload to the model symlinks that reference it."""
    refs: dict[Path, list[Path]] = {}
    store_resolved = store.resolve()
    for model in hub.iterdir():
        if not model.is_dir() or MODEL_DIR_RE.fullmatch(model.name) is None:
            continue
        bdir = model / "blobs"
        if not bdir.is_dir():
            continue
        for entry in os.scandir(bdir):
            link = Path(entry.path)
            if not link.is_symlink():
                continue
            try:
                target = Path(os.path.realpath(link))
            except OSError:
                continue
            try:
                rel = target.relative_to(store_resolved)
            except ValueError:
                continue
            parts = rel.parts
            if len(parts) == 2 and HASH_RE.fullmatch(parts[1]) and parts[0] == parts[1][:2]:
                refs.setdefault(target, []).append(link)
    return refs


def _materialize(src: Path, link: Path) -> None:
    """Copy `src` over the symlink `link` so the model blob becomes a regular file."""
    tmp = link.parent / f".migrate.{link.name}.tmp"
    shutil.copyfile(src, tmp)
    os.chmod(tmp, 0o644)
    try:
        os.replace(tmp, link)  # replaces the symlink entry in place, atomically
    finally:
        tmp.unlink(missing_ok=True)


def _live_references(store_path: Path, hub: Path) -> set[Path]:
    """Symlinks that still point at this payload after the migration pass."""
    live: set[Path] = set()
    for model in hub.iterdir():
        if not model.is_dir() or MODEL_DIR_RE.fullmatch(model.name) is None:
            continue
        bdir = model / "blobs"
        if not bdir.is_dir():
            continue
        for entry in os.scandir(bdir):
            p = Path(entry.path)
            if p.is_symlink() and Path(os.path.realpath(p)) == store_path.resolve():
                live.add(p)
    return live


def _write_manifest(manifest: Path, refs: set[Path], hub: Path) -> None:
    tmp = manifest.with_name(f"{manifest.name}.{os.urandom(4).hex()}.tmp")
    content = "".join(f"{p.relative_to(hub).as_posix()}\n" for p in sorted(refs))
    tmp.write_text(content)
    os.replace(tmp, manifest)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cache", default="~/.cache/huggingface/hub",
                    help="HuggingFace hub cache dir (default: %(default)s)")
    ap.add_argument("--dry-run", action="store_true", help="show the plan, change nothing")
    args = ap.parse_args()

    hub = Path(os.path.expanduser(args.cache)).resolve()
    store = hub / "blobs"
    if not (store / MARKER_NAME).is_file():
        print(f"No Xet shared-blob store at {store} — nothing to migrate.")
        return 0

    refs = _collect_refs(store, hub)
    if not refs:
        print("No cached models reference the shared store — nothing to migrate.")
        return 0

    total = 0
    for store_path, links in sorted(refs.items(), key=lambda kv: kv[0].name):
        try:
            size = store_path.stat().st_size if store_path.is_file() else 0
        except OSError:
            size = 0
        total += size
        if args.dry_run:
            print(f"[dry] {store_path.name} ({size / 1e6:.1f} MB), {len(links)} model link(s):")
            for link in links:
                print(f"        -> materialize {link}")

    if args.dry_run:
        print(f"\nDRY RUN: would copy {total / 1e9:.2f} GB into model folders and prune the store.")
        return 0

    # 1) Materialize every referenced payload into its model folder.
    for store_path, links in refs.items():
        if not store_path.is_file():
            print(f"  skip missing store payload {store_path}")
            continue
        for link in links:
            try:
                _materialize(store_path, link)
            except OSError as e:
                print(f"  ERROR materializing {link}: {e}", file=sys.stderr)

    # 2) Rewrite manifests; drop payloads that are now unreferenced.
    pruned = 0
    for store_path in refs:
        live = _live_references(store_path, hub)
        manifest = store_path.with_name(store_path.name + ".refs")
        if live:
            _write_manifest(manifest, live, hub)
            continue
        store_path.unlink(missing_ok=True)
        manifest.unlink(missing_ok=True)
        store_path.with_name(store_path.name + ".lock").unlink(missing_ok=True)
        try:
            store_path.parent.rmdir()  # prune empty <2-hex> prefix dir
        except OSError:
            pass
        pruned += 1

    print(f"Migrated {len(refs)} shared blob(s) into model folders; pruned {pruned} store payload(s).")
    remaining = _collect_refs(store, hub)
    print("Verification: shared-store symlinks remaining =", len(remaining))
    return 0 if not remaining else 1


if __name__ == "__main__":
    sys.exit(main())