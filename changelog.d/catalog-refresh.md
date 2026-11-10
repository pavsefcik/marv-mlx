### Added

- **Curated list refreshes from upstream.** The TUI now keeps
  `~/.cache/marv/mlx/curated-llms.md` current from
  `https://raw.githubusercontent.com/pavsefcik/marv-mlx/main/curated-llms.md`
  instead of only copying the bundled `curated-llms.md` when it changes, so
  hand-picked models added between releases show up in the Download menu without
  an upgrade. The refresh is TTL-gated (`MARV_MLX_CATALOG_TTL`, default 3600s;
  `0` = every launch, `never` = off, `MARV_MLX_CATALOG_URL` overrides) and uses
  a 3s connect / 5s total timeout. A failed or non-catalog response never
  replaces a good cache and still stamps the attempt, so an offline machine pays
  the timeout at most once per TTL. A newly bundled catalog still wins
  immediately (offline-safe) and is served for one TTL before upstream can
  supersede it. Headless verbs (`run`/`stop`/`status`/`curated`)
  never fetch — they seed from the bundled list and read the cache.
  `MARV_MLX_CATALOG` continues to point at a custom list and disables the
  refresh.

### Changed

- **The catalog parser accepts a trimmed id-only list** — one bare model id per
  line, no taglines, no blank-line separators (tier headers unchanged). Taglines
  stay optional, and the legacy 2-line/3-line shapes still parse.
