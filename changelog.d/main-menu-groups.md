### Changed

- **New main-menu layout.** The TUI is now four groups: `Select model and run:`
  (installed models), `Download new model:` (the curated picks for this Mac's
  RAM tier that aren't installed yet, plus `Custom (paste HuggingFace ID)` and
  `Open models folder`; the full multi-tier Download screen is no longer listed
  in the menu but its code and `download_all` action remain), the settings group (`Basic settings`, `Advanced settings`, `Chat history`,
  `Restart & refresh`), and `Stop & quit` on its own. Section headers and rules
  are not navigable, and the `Update to latest version` row still appears right
  above the lifecycle group when a newer release exists.

### Added

- **Inline downloads.** A curated row in the main menu downloads straight from
  the menu (same flow as the Download screen: HF-token offer, GGUF guard, offer
  to start the model). `Custom (paste HuggingFace ID)` does the same for any id
  without opening the Download screen.
