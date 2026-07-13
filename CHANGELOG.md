# Changelog

## Unreleased

- Makes viewport capture wait for the renderer's completed frame so screenshots
  reflect the latest runtime input and property changes.
- Replaces screenshot byte equality with decoded, tolerance-aware per-pixel
  comparison and quantitative difference metrics.
- Prevents an exiting Godot process from disconnecting a newly launched runtime
  bridge during immediate repair-and-restart workflows.
- Adds an automated seven-point visual feedback gate covering run, capture,
  inspection artifacts, diagnostics, player input, comparison, and persistent
  repair/relaunch.
- Eliminates intentional compatibility-shim warnings from runtime diagnostics and
  fixes `wait_for_signal` to report actual firing or timeout state.

## 1.0.0 - 2026-07-12

- Exposes 1,969 unique Godot tools with compact progressive discovery.
- Adds runtime and editor TCP bridges, editor-plugin installation, and universal
  dispatch through `godot_call`.
- Adds dry-run sequences and filesystem rollback on failure.
- Adds configurable workspace-safe ports, allowed-root enforcement, destructive
  confirmation mode, structured errors, and optional response limits.
- Adds exhaustive dispatcher verification, semantic Godot workflows, generated
  tool reference, compatibility CI, and performance benchmarks.
