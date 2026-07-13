# Godot MCP verification

This checklist covers the release gates that unit-only testing cannot prove.

## Automated checks

```bash
npm ci
npm test
npm pack --dry-run
```

`npm test` rebuilds first. The protocol tests start the compiled stdio server in
both modes and verify schema count, unique names, discovery size, dispatcher
coverage, search behavior, and universal dispatch. They invoke all 1,969 tool
names on every run; this is exhaustive dispatcher/transport coverage, not a
sample. Tools that require a running game, editor selection, imported asset, or
specialized scene state return their documented precondition error in this
phase and are covered by the relevant end-to-end workflow phase.

The suite also combines the four project-analysis tools on the same real fixture:
`get_project_health_report`, `get_scene_dependency_graph`,
`find_orphaned_project_files`, and `compare_project_settings`.

## Godot compatibility check

Set `GODOT_PATH` to the executable you intend to support, then compile both
bundled bridges with that exact Godot version:

```bash
"$GODOT_PATH" --version
"$GODOT_PATH" --headless --script build/scripts/mcp_interaction_server.gd --check-only
```

Headless operations are exercised when tools such as `create_scene` run. The
runtime bridge is exercised only after `run_project` injects it as the
`McpInteractionServer` autoload and connects to TCP port 9090.

## End-to-end smoke test

From an MCP client:

1. Call `get_godot_version`.
2. Call `create_project` in a disposable directory.
3. Call `create_scene`, `add_node`, and `read_scene`.
4. Call `set_main_scene`.
5. Call `install_editor_plugin`; confirm both files exist under
   `addons/godot_mcp_editor/`.
6. Call `run_project`. Use `headless=true` in CI or on a server without a
   display. Initial connection can take a few seconds.
7. Call `game_get_scene_tree`, `game_get_logs`, `game_set_property`, and
   `game_get_property`.
8. Call `stop_project` and confirm port 9090 is no longer listening.

## Seven-point visual feedback gate

Run the complete self-evaluation loop on a machine with a display server:

```bash
npm run verify:feedback
```

Linux CI runs the same command under `xvfb-run`. The verifier creates a
disposable UI project and proves all seven capabilities together:

1. launch the project and connect to its runtime bridge;
2. capture complete rendered PNG frames;
3. retain frames as inspectable artifacts under `.context/seven-point-artifacts`;
4. collect stdout and a known runtime diagnostic without bridge-warning noise;
5. send mouse and keyboard input, record it, and replay it;
6. assert runtime state and perform decoded per-pixel screenshot comparison;
7. detect an intentionally wrong state, persist a repair, immediately restart,
   and prove that the repaired state survives relaunch.

The check additionally requires the `BROKEN`, `READY`, `CLICK_OK`, and `KEY_OK`
screenshots to be distinct. `compare_screenshots` decodes both PNGs and reports
the differing-pixel percentage and mean absolute channel error. Its default
tolerance ignores channel deltas up to `0.1` and permits at most `0.5%`
differing pixels; callers can override these with `channelThreshold` and
`maxDiffPercent`.

For editor tools, enable **Godot MCP Editor** under **Project > Project Settings
> Plugins**, launch the project in the editor, then call
`connect_to_godot_editor`. Editor control uses TCP port 9091.

## Conductor / Codex installation

```bash
codex mcp add godot \
  --env GODOT_PATH=/Applications/Godot.app/Contents/MacOS/Godot \
  --env GODOT_MCP_DISCOVERY_MODE=true \
  -- node /absolute/path/to/godot-mcp/build/index.js
codex mcp get godot
```

Restart the agent session after changing MCP configuration. Remove the server
with `codex mcp remove godot`.

When Conductor supplies `CONDUCTOR_PORT`, the MCP uses offsets `+8` and `+9` for
runtime and editor control. Explicit `GODOT_MCP_RUNTIME_PORT` and
`GODOT_MCP_EDITOR_PORT` values take precedence.

## Guarded multi-tool execution

`godot_call` accepts `sequence: [{name, args}]`, `dryRun: true`, and
`rollbackOnError: true`. Rollback snapshots and restores one shared
`projectPath`; it does not attempt to reverse runtime physics, network, audio,
or editor state.

## Common failures

- **Unknown tool in discovery mode:** run `npm test`; every discovery schema is
  checked against the dispatcher.
- **Not connected to game interaction server:** wait a few seconds after
  `run_project`, inspect `get_debug_output`, and check that port 9090 is free.
- **Feedback artifacts are stale:** run `npm run verify:feedback`; capture waits
  for `RenderingServer.frame_post_draw`, so each PNG must contain the most
  recently asserted state.
- **Editor tools are not connected:** install and enable the plugin, open the
  project in Godot, and confirm port 9091 is free.
- **Godot script parse error:** rebuild, then run the compatibility check above
  with the same Godot executable configured for the MCP.
- **MCP starts but the client does not show it:** confirm `codex mcp get godot`,
  use an absolute path to `build/index.js`, and start a new client session.

## Promotion checklist

- Automated tests pass on supported Node versions.
- Both GDScript bridges parse on the promoted Godot version.
- npm dry-run includes `build/index.js`, both runtime scripts, and the editor
  plugin.
- The end-to-end smoke test passes.
- The seven-point visual feedback gate passes without a stop/start delay.
- README, `package.json`, `server.json`, and the observed MCP tool count agree.

No finite test can cover every possible ordering, argument value, or combination
of 1,969 stateful tools. Release verification therefore uses exhaustive
tool-by-tool dispatch, schema/handler identity checks, GDScript compilation, and
stateful workflow chains spanning offline editing, runtime control, editor plugin
installation, and project analysis.
