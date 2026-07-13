#!/usr/bin/env node
import { mkdirSync, writeFileSync } from 'node:fs';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const client = new Client({ name: 'godot-mcp-doc-generator', version: '1.0.0' });
const transport = new StdioClientTransport({
  command: process.execPath,
  args: ['build/index.js'],
  env: { ...process.env, GODOT_MCP_DISCOVERY_MODE: 'false' },
  stderr: 'pipe',
});
await client.connect(transport);
const tools = (await client.listTools()).tools.slice().sort((a, b) => a.name.localeCompare(b.name));
await client.close();

const category = name => {
  if (/^editor_|godot_|search_tools|list_tool|get_workflow|get_beginner|explain_/.test(name)) return 'Navigation and editor';
  if (/project|export|launch|run_project|stop_project/.test(name)) return 'Project and release';
  if (/scene|node|tree|group/.test(name)) return 'Scenes and nodes';
  if (/audio|sound|music/.test(name)) return 'Audio';
  if (/physics|collision|rigid|raycast|joint/.test(name)) return 'Physics';
  if (/animation|tween|sprite_frame/.test(name)) return 'Animation';
  if (/camera|viewport|render|shader|material|light|environment/.test(name)) return 'Rendering';
  if (/file|directory|script|resource/.test(name)) return 'Files, scripts, and resources';
  if (/ui|control|button|label|menu|container|panel|theme/.test(name)) return 'UI';
  return 'Runtime and specialized';
};

const groups = new Map();
for (const tool of tools) {
  const key = category(tool.name);
  if (!groups.has(key)) groups.set(key, []);
  groups.get(key).push(tool);
}

const lines = [
  '# Complete tool reference',
  '',
  `Generated from the compiled MCP server. Total unique tools: **${tools.length}**.`,
  '',
  'The machine-readable schemas are in `tool-reference.json`. Regenerate both files with `npm run docs:generate`.',
  '',
];
for (const [group, entries] of [...groups].sort(([a], [b]) => a.localeCompare(b))) {
  lines.push(`## ${group}`, '', '| Tool | Description | Required arguments |', '|---|---|---|');
  for (const tool of entries) {
    const required = Array.isArray(tool.inputSchema?.required) ? tool.inputSchema.required.join(', ') : '';
    const description = String(tool.description || '').replace(/\|/g, '\\|').replace(/\s+/g, ' ').trim();
    lines.push(`| \`${tool.name}\` | ${description} | ${required || 'None'} |`);
  }
  lines.push('');
}

mkdirSync('docs', { recursive: true });
writeFileSync('docs/tool-reference.md', `${lines.join('\n').trimEnd()}\n`);
writeFileSync('docs/tool-reference.json', `${JSON.stringify({ count: tools.length, tools }, null, 2)}\n`);
console.log(`Generated docs for ${tools.length} tools.`);
