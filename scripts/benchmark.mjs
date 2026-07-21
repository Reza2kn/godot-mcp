#!/usr/bin/env node
import { performance } from 'node:perf_hooks';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

async function measure(discoveryMode) {
  const started = performance.now();
  const client = new Client({ name: 'godot-mcp-benchmark', version: '1.0.0' });
  await client.connect(new StdioClientTransport({
    command: process.execPath,
    args: ['build/index.js'],
    env: { ...process.env, GODOT_MCP_DISCOVERY_MODE: discoveryMode ? 'true' : 'false' },
    stderr: 'pipe',
  }));
  const connectedMs = performance.now() - started;
  const listStarted = performance.now();
  const response = await client.listTools();
  const listMs = performance.now() - listStarted;
  const schemaBytes = Buffer.byteLength(JSON.stringify(response), 'utf8');
  const callStarted = performance.now();
  await client.callTool({ name: discoveryMode ? 'search_tools' : 'get_beginner_guide', arguments: discoveryMode ? { query: 'camera' } : {} });
  const callMs = performance.now() - callStarted;
  await client.close();
  return { mode: discoveryMode ? 'discovery' : 'full', tools: response.tools.length, connectedMs, listMs, callMs, schemaBytes };
}

const results = [await measure(true), await measure(false)];
console.log(JSON.stringify({ node: process.version, platform: process.platform, memoryRssBytes: process.memoryUsage().rss, results }, null, 2));
if (results[0].tools !== 20 || results[1].tools !== 1969) process.exitCode = 1;
if (results.some(result => result.connectedMs > 5000 || result.listMs > 5000)) process.exitCode = 1;
if (results[0].schemaBytes > 10_000 || results[1].schemaBytes > 2_000_000) process.exitCode = 1;
