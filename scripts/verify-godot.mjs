#!/usr/bin/env node
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const projectPath = mkdtempSync(join(tmpdir(), 'godot-mcp-semantic-'));
const client = new Client({ name: 'godot-mcp-semantic-verifier', version: '1.0.0' });
await client.connect(new StdioClientTransport({
  command: process.execPath,
  args: ['build/index.js'],
  env: { ...process.env, GODOT_MCP_DISCOVERY_MODE: 'true' },
}));

const results = [];
async function call(name, args = {}, retries = 1) {
  let result;
  for (let attempt = 0; attempt < retries; attempt++) {
    result = await client.callTool({ name: 'godot_call', arguments: { name, args } });
    if (!result.isError) break;
    await new Promise(resolve => setTimeout(resolve, 400));
  }
  const text = result?.content?.find(item => item.type === 'text')?.text || '';
  results.push({ name, ok: !result?.isError, preview: text.slice(0, 200) });
  if (result?.isError) throw new Error(`${name}: ${text}`);
  try { return JSON.parse(text); } catch { return text; }
}

try {
  await call('create_project', { projectPath, projectName: 'Godot MCP semantic fixture' });
  await call('create_scene', { projectPath, scenePath: 'main.tscn', rootNodeType: 'Node2D' });
  await call('add_node', { projectPath, scenePath: 'main.tscn', nodeType: 'Label', nodeName: 'Status', properties: { text: 'offline' } });
  await call('create_script', { projectPath, scriptPath: 'controller.gd', content: 'extends Node2D\nfunc _ready():\n\t$Status.text = "script"\n' });
  await call('attach_script', { projectPath, scenePath: 'main.tscn', nodePath: 'root', scriptPath: 'controller.gd' });
  await call('set_main_scene', { projectPath, scenePath: 'res://main.tscn' });
  await call('install_editor_plugin', { projectPath, enable: true });
  await call('read_scene', { projectPath, scenePath: 'main.tscn' });
  await call('run_project', { projectPath });
  await call('game_get_scene_tree', {}, 40);
  await call('game_set_property', { nodePath: '/root/root/Status', property: 'text', value: 'runtime' });
  const property = await call('game_get_property', { nodePath: '/root/root/Status', property: 'text' });
  await call('game_get_logs');
  await call('stop_project');
  const health = await call('get_project_health_report', { projectPath });
  await call('get_scene_dependency_graph', { projectPath });
  await call('find_orphaned_project_files', { projectPath });
  const comparison = await call('compare_project_settings', { projectPath, otherProjectPath: projectPath });
  if (property.value !== 'runtime' || health.healthy !== true || comparison.identical !== true) throw new Error('Semantic assertions failed.');
  console.log(JSON.stringify({ success: true, projectPath, results }, null, 2));
} finally {
  try { await client.callTool({ name: 'stop_project', arguments: {} }); } catch {}
  await client.close();
  rmSync(projectPath, { recursive: true, force: true });
}
