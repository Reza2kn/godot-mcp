#!/usr/bin/env node
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';

const workspace = process.cwd();
const projectPath = process.env.GODOT_MCP_FEEDBACK_PROJECT || join(workspace, '.context', 'seven-point-fixture');
const artifactPath = process.env.GODOT_MCP_FEEDBACK_ARTIFACTS || join(workspace, '.context', 'seven-point-artifacts');
rmSync(projectPath, { recursive: true, force: true });
rmSync(artifactPath, { recursive: true, force: true });
mkdirSync(projectPath, { recursive: true });
mkdirSync(artifactPath, { recursive: true });

const projectFile = `[application]
config/name="Seven Point Verification"
run/main_scene="res://main.tscn"

[display]
window/size/viewport_width=640
window/size/viewport_height=360
window/size/window_width_override=640
window/size/window_height_override=360

[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
`;

const scene = (status) => `[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://main.gd" id="1"]

[node name="Main" type="Control"]
layout_mode = 3
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
grow_horizontal = 2
grow_vertical = 2
script = ExtResource("1")

[node name="Background" type="ColorRect" parent="."]
layout_mode = 0
offset_right = 640.0
offset_bottom = 360.0
mouse_filter = 2
color = Color(0.047, 0.067, 0.106, 1)

[node name="Title" type="Label" parent="."]
layout_mode = 0
offset_left = 145.0
offset_top = 45.0
offset_right = 495.0
offset_bottom = 85.0
theme_override_colors/font_color = Color(0.95, 0.95, 1, 1)
theme_override_font_sizes/font_size = 28
text = "GODOT MCP FEEDBACK LOOP"
horizontal_alignment = 1

[node name="Status" type="Label" parent="."]
layout_mode = 0
offset_left = 220.0
offset_top = 112.0
offset_right = 420.0
offset_bottom = 160.0
theme_override_colors/font_color = Color(1, 0.84, 0.25, 1)
theme_override_font_sizes/font_size = 24
text = "${status}"
horizontal_alignment = 1

[node name="Swatch" type="ColorRect" parent="."]
layout_mode = 0
offset_left = 270.0
offset_top = 168.0
offset_right = 370.0
offset_bottom = 210.0
mouse_filter = 2
color = Color(0.8, 0.18, 0.18, 1)

[node name="Button" type="Button" parent="."]
layout_mode = 0
offset_left = 220.0
offset_top = 235.0
offset_right = 420.0
offset_bottom = 295.0
theme_override_font_sizes/font_size = 20
text = "ACTIVATE"

[node name="Hint" type="Label" parent="."]
layout_mode = 0
offset_left = 170.0
offset_top = 312.0
offset_right = 470.0
offset_bottom = 340.0
theme_override_colors/font_color = Color(0.65, 0.72, 0.85, 1)
text = "Click ACTIVATE or press SPACE"
horizontal_alignment = 1

[node name="TestTimer" type="Timer" parent="."]
one_shot = true
`;

const script = `extends Control

func _ready() -> void:
    $Button.pressed.connect(_on_activated)
    print("TPOINT_READY:", $Status.text)
    push_error("TPOINT_EXPECTED_DIAGNOSTIC")

func _on_activated() -> void:
    $Status.text = "CLICK_OK"
    $Status.add_theme_color_override("font_color", Color("70e1a1"))
    $Swatch.color = Color("27ae60")
    print("TPOINT_CLICK_OK")

func _input(event: InputEvent) -> void:
    if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
        $Status.text = "KEY_OK"
        $Status.add_theme_color_override("font_color", Color("8ac7ff"))
        $Swatch.color = Color("3498db")
        print("TPOINT_KEY_OK")
        get_viewport().set_input_as_handled()
`;

writeFileSync(join(projectPath, 'project.godot'), projectFile);
writeFileSync(join(projectPath, 'main.tscn'), scene('BROKEN'));
writeFileSync(join(projectPath, 'main.gd'), script);

const client = new Client({ name: 'seven-point-verifier', version: '1.0.0' });
await client.connect(new StdioClientTransport({
  command: process.execPath,
  args: ['build/index.js'],
  env: { ...process.env, GODOT_MCP_DISCOVERY_MODE: 'false' },
  stderr: 'pipe',
}));

const report = { projectPath, artifactPath, checks: [], calls: [] };

function parseText(result) {
  const item = result.content?.find(entry => entry.type === 'text');
  if (!item?.text) return null;
  try { return JSON.parse(item.text); } catch { return item.text; }
}

async function call(name, args = {}, { retries = 1, allowError = false } = {}) {
  let result;
  for (let attempt = 0; attempt < retries; attempt++) {
    result = await client.callTool({ name, arguments: args });
    if (!result.isError) break;
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  const parsed = parseText(result);
  const reportValue = name === 'capture_frames' && parsed?.frames
    ? { ...parsed, frames: parsed.frames.map(({ base64: _base64, ...frame }) => frame) }
    : parsed;
  report.calls.push({ name, ok: !result.isError, parsed: reportValue });
  if (result.isError && !allowError) throw new Error(`${name}: ${JSON.stringify(parsed)}`);
  return { result, parsed };
}

function saveImage(result, filename) {
  const image = result.content?.find(entry => entry.type === 'image');
  if (!image?.data) throw new Error(`No image content returned for ${filename}`);
  const target = join(artifactPath, filename);
  writeFileSync(target, Buffer.from(image.data, 'base64'));
  return target;
}

function imageHash(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

async function waitForGame() {
  await call('game_get_scene_tree', {}, { retries: 50 });
}

try {
  // 1-3: run, capture, inspectable artifact. Begin in a deliberately wrong state.
  await call('run_project', { projectPath });
  await waitForGame();
  const initialShot = await call('game_screenshot');
  const initialPath = saveImage(initialShot.result, '01-broken.png');
  const mismatch = await call('assert_node_state', {
    nodePath: '/root/Main/Status', property: 'text', expectedValue: 'READY',
  });
  if (mismatch.parsed.passed !== false) throw new Error('Expected initial READY assertion to fail.');

  // 4: capture both logs and an intentional Godot runtime diagnostic.
  const logsBeforeRepair = await call('game_get_logs');
  const errorsBeforeRepair = await call('game_get_errors');
  const diagnosticText = JSON.stringify(errorsBeforeRepair.parsed);
  if (!diagnosticText.includes('TPOINT_EXPECTED_DIAGNOSTIC')) throw new Error('Expected runtime diagnostic was not captured.');
  const bridgeWarningPattern = /(declared but never used|never used in the function|shadowing an already-declared|Integer used when an enum value is expected|Values of the ternary operator are not mutually compatible|Standalone ternary operator)/;
  const diagnosticLines = [...logsBeforeRepair.parsed.logs, ...errorsBeforeRepair.parsed.errors];
  const warningLines = diagnosticLines.filter(line => bridgeWarningPattern.test(line));
  if (warningLines.length) throw new Error(`Runtime bridge emitted Godot warnings: ${JSON.stringify([...new Set(warningLines)])}`);
  await call('stop_project');

  // 6-7: compare actual to intent, persist a repair through MCP, relaunch, reassert.
  await call('write_file', { projectPath, filePath: 'main.tscn', content: scene('READY') });
  await call('run_project', { projectPath });
  await waitForGame();
  const repaired = await call('assert_node_state', {
    nodePath: '/root/Main/Status', property: 'text', expectedValue: 'READY',
  });
  if (repaired.parsed.passed !== true) throw new Error('Persistent repair did not survive relaunch.');
  const repairedShot = await call('game_screenshot');
  const repairedPath = saveImage(repairedShot.result, '02-repaired-ready.png');

  await call('game_call_method', { nodePath: '/root/Main/TestTimer', method: 'start', args: [0.1] });
  const waitedSignal = await call('wait_for_signal', {
    nodePath: '/root/Main/TestTimer', signalName: 'timeout', timeoutMs: 1000,
  });
  if (waitedSignal.parsed.fired !== true || waitedSignal.parsed.timed_out !== false) throw new Error('wait_for_signal did not observe the timer timeout.');

  // 5: player-like mouse input, recorded for replay.
  await call('start_recording');
  await call('game_click', { x: 320, y: 265, button: 1 });
  const clicked = await call('assert_node_state', {
    nodePath: '/root/Main/Status', property: 'text', expectedValue: 'CLICK_OK',
  });
  if (clicked.parsed.passed !== true) throw new Error('Mouse click did not activate the UI.');
  const recording = await call('stop_recording');
  if (!recording.parsed.events?.length) throw new Error('Input recording returned no events.');
  const clickedShot = await call('game_screenshot');
  const clickedPath = saveImage(clickedShot.result, '03-clicked.png');
  if (imageHash(clickedPath) === imageHash(repairedPath)) throw new Error('Click screenshot is stale and matches READY.');

  // Visual comparison must reject the old state and accept the current state.
  const changedComparison = await call('compare_screenshots', { referencePath: repairedPath });
  if (changedComparison.parsed.match !== false || changedComparison.parsed.diffPercent <= 0) throw new Error('Visual comparison did not detect the changed frame.');
  const matchingComparison = await call('compare_screenshots', { referencePath: clickedPath });
  if (matchingComparison.parsed.match !== true) throw new Error('Visual comparison rejected the current reference frame.');

  // Keyboard input and behavioral assertion.
  await call('game_key_press', { key: 'SPACE' });
  const keyed = await call('assert_node_state', {
    nodePath: '/root/Main/Status', property: 'text', expectedValue: 'KEY_OK',
  });
  if (keyed.parsed.passed !== true) throw new Error('Keyboard input did not reach the game.');
  const keyedShot = await call('game_screenshot');
  const keyedPath = saveImage(keyedShot.result, '04-keyboard.png');
  if (imageHash(keyedPath) === imageHash(clickedPath)) throw new Error('Keyboard screenshot is stale and matches CLICK_OK.');

  // Replay the captured mouse interaction, then assert the game returned to CLICK_OK.
  await call('replay_recording', { events: recording.parsed.events, speedScale: 10 });
  const replayed = await call('assert_node_state', {
    nodePath: '/root/Main/Status', property: 'text', expectedValue: 'CLICK_OK',
  });
  if (replayed.parsed.passed !== true) throw new Error('Recorded input replay did not reproduce the click behavior.');

  const frames = await call('capture_frames', { count: 2, intervalFrames: 1 });
  if (frames.parsed.frames?.length !== 2) throw new Error('Multi-frame capture did not return two frames.');
  writeFileSync(join(artifactPath, '05-captured-frame.png'), Buffer.from(frames.parsed.frames[0].base64, 'base64'));

  const finalLogs = await call('game_get_logs');
  const finalLogText = JSON.stringify(finalLogs.parsed);
  for (const marker of ['TPOINT_CLICK_OK', 'TPOINT_KEY_OK']) {
    if (!finalLogText.includes(marker)) throw new Error(`Missing expected log marker: ${marker}`);
  }

  report.checks = [
    { point: 1, name: 'run project', passed: true },
    { point: 2, name: 'capture viewport/screenshots', passed: true, artifacts: [initialPath, repairedPath, clickedPath, keyedPath] },
    { point: 3, name: 'produce inspectable visual output', passed: true, artifact: clickedPath },
    { point: 4, name: 'read logs and runtime errors', passed: true, logCount: logsBeforeRepair.parsed.count, errorCount: errorsBeforeRepair.parsed.count },
    { point: 5, name: 'interact as player', passed: true, mouse: true, keyboard: true, recordedEvents: recording.parsed.events.length, replayed: true },
    { point: 6, name: 'compare behavior to requested result', passed: true, stateAssertions: true, pixelScreenshotComparison: true },
    { point: 7, name: 'repair and repeat', passed: true, initialMismatchDetected: true, persistentRepairSurvivedRelaunch: true },
  ];
  await call('stop_project');
  writeFileSync(join(artifactPath, 'report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify({ success: true, projectPath, artifactPath, checks: report.checks }, null, 2));
} finally {
  try { await client.callTool({ name: 'stop_project', arguments: {} }); } catch {}
  await client.close();
}
