import { afterEach, describe, expect, it } from 'vitest';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

const clients: Client[] = [];
const temporaryDirectories: string[] = [];

async function connect(discoveryMode: boolean, env: Record<string, string> = {}): Promise<Client> {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: ['build/index.js'],
    env: {
      ...process.env,
      GODOT_MCP_DISCOVERY_MODE: discoveryMode ? 'true' : 'false',
      ...env,
    },
    stderr: 'pipe',
  });
  const client = new Client({ name: 'godot-mcp-tests', version: '1.0.0' });
  clients.push(client);
  await client.connect(transport);
  return client;
}

afterEach(async () => {
  await Promise.all(clients.splice(0).map(client => client.close()));
  for (const directory of temporaryDirectories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

describe('MCP protocol', () => {
  it('exposes all 1,969 tools in full mode without duplicate names', async () => {
    const client = await connect(false);
    const { tools } = await client.listTools();

    expect(tools).toHaveLength(1969);
    expect(new Set(tools.map(tool => tool.name))).toHaveLength(1969);
  });

  it('dispatches every advertised tool without protocol exceptions', async () => {
    const client = await connect(false);
    const { tools } = await client.listTools();
    const failures: Array<{ name: string; reason: string }> = [];

    for (const tool of tools) {
      try {
        const result = await client.callTool({ name: tool.name, arguments: {} });
        if (!Array.isArray(result.content)) failures.push({ name: tool.name, reason: 'Invalid result shape' });
      } catch (error) {
        failures.push({ name: tool.name, reason: String(error) });
      }
    }

    expect(failures).toEqual([]);
  }, 30_000);

  it('keeps discovery mode compact and dispatches hidden tools', async () => {
    const client = await connect(true);
    const { tools } = await client.listTools();
    expect(tools).toHaveLength(20);

    const search = await client.callTool({
      name: 'search_tools',
      arguments: { query: 'create project' },
    });
    const text = search.content.find(item => item.type === 'text');
    expect(text?.type === 'text' ? text.text : '').toContain('create_project');

    const hiddenTool = await client.callTool({
      name: 'godot_call',
      arguments: { name: 'get_beginner_guide', args: {} },
    });
    expect(hiddenTool.isError).not.toBe(true);

    const source = readFileSync('src/index.ts', 'utf8');
    const dispatchNames = new Set([...source.matchAll(/case '([^']+)':/g)].map(match => match[1]));
    expect(tools.filter(tool => !dispatchNames.has(tool.name))).toEqual([]);
  });

  it('runs the four project-analysis tools together on real project files', async () => {
    const root = mkdtempSync(join(tmpdir(), 'godot-mcp-analysis-'));
    const other = mkdtempSync(join(tmpdir(), 'godot-mcp-analysis-other-'));
    temporaryDirectories.push(root, other);
    mkdirSync(join(root, 'scripts'));
    writeFileSync(join(root, 'project.godot'), '[application]\nconfig/name="Primary"\nrun/main_scene="res://main.tscn"\n');
    writeFileSync(join(root, 'main.tscn'), '[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://scripts/player.gd" id="1"]\n[node name="Main" type="Node"]\n');
    writeFileSync(join(root, 'scripts', 'player.gd'), 'extends Node\n');
    writeFileSync(join(root, 'orphan.gd'), 'extends Node\n');
    writeFileSync(join(other, 'project.godot'), '[application]\nconfig/name="Other"\n');

    const client = await connect(false);
    const call = async (name: string, args: Record<string, unknown>) => {
      const result = await client.callTool({ name, arguments: args });
      expect(result.isError).not.toBe(true);
      const content = result.content.find(item => item.type === 'text');
      expect(content?.type).toBe('text');
      return JSON.parse(content?.type === 'text' ? content.text : '{}');
    };

    const health = await call('get_project_health_report', { projectPath: root });
    const graph = await call('get_scene_dependency_graph', { projectPath: root });
    const orphans = await call('find_orphaned_project_files', { projectPath: root });
    const comparison = await call('compare_project_settings', { projectPath: root, otherProjectPath: other });

    expect(health.healthy).toBe(true);
    expect(graph.graph['res://main.tscn']).toContain('res://scripts/player.gd');
    expect(orphans.orphanedFiles).toContain('orphan.gd');
    expect(comparison.identical).toBe(false);
  });

  it('supports dry-run sequences and rolls filesystem changes back on failure', async () => {
    const root = mkdtempSync(join(tmpdir(), 'godot-mcp-transaction-'));
    temporaryDirectories.push(root);
    writeFileSync(join(root, 'project.godot'), '[application]\nconfig/name="Transaction"\n');
    writeFileSync(join(root, 'state.txt'), 'original');
    const client = await connect(true);
    const sequence = [
      { name: 'write_file', args: { projectPath: root, filePath: 'state.txt', content: 'changed' } },
      { name: 'read_file', args: { projectPath: root, filePath: 'missing.txt' } },
    ];

    const preview = await client.callTool({ name: 'godot_call', arguments: { sequence, dryRun: true } });
    expect(preview.isError).not.toBe(true);
    expect(readFileSync(join(root, 'state.txt'), 'utf8')).toBe('original');

    const transaction = await client.callTool({ name: 'godot_call', arguments: { sequence, rollbackOnError: true } });
    expect(transaction.isError).toBe(true);
    expect(readFileSync(join(root, 'state.txt'), 'utf8')).toBe('original');
  });

  it('enforces allowed roots, destructive confirmation, and structured errors', async () => {
    const root = mkdtempSync(join(tmpdir(), 'godot-mcp-security-'));
    const outside = mkdtempSync(join(tmpdir(), 'godot-mcp-outside-'));
    temporaryDirectories.push(root, outside);
    writeFileSync(join(root, 'project.godot'), '[application]\nconfig/name="Security"\n');
    writeFileSync(join(root, 'delete-me.txt'), 'data');
    writeFileSync(join(outside, 'project.godot'), '[application]\nconfig/name="Outside"\n');
    const client = await connect(true, {
      GODOT_MCP_ALLOWED_ROOTS: root,
      GODOT_MCP_CONFIRM_DESTRUCTIVE: 'true',
    });

    const blockedRoot = await client.callTool({ name: 'godot_call', arguments: { name: 'get_project_info', args: { projectPath: outside } } });
    expect(blockedRoot.isError).toBe(true);
    expect((blockedRoot.structuredContent as any)?.error?.code).toBe('PERMISSION_DENIED');

    const blockedDelete = await client.callTool({ name: 'godot_call', arguments: { name: 'delete_file', args: { projectPath: root, filePath: 'delete-me.txt' } } });
    expect(blockedDelete.isError).toBe(true);
    const confirmedDelete = await client.callTool({ name: 'godot_call', arguments: { name: 'delete_file', args: { projectPath: root, filePath: 'delete-me.txt', confirmDestructive: true } } });
    expect(confirmedDelete.isError).not.toBe(true);
  });
});
