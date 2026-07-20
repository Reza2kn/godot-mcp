#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const entryPoint = join(root, "build", "index.js");
const baseline = readJson("audit/ui-baseline.json");
const mappings = readJson("audit/mappings.json").mappings;
const STATES = ["verified", "represented_unverified", "broken", "gap"];
const MCP_ONLY =
  /^(godot_(?:start_here|suggest|call)|search_tools|list_tool_categories|list_tools_in_category|get_beginner_guide|get_workflow|explain_godot_concept|write_.*_script|setup_.*|create_.*_template)$/;

function readJson(relativePath) {
  return JSON.parse(readFileSync(join(root, relativePath), "utf8"));
}

function unique(values) {
  return [...new Set(values)].sort();
}

function duplicates(values) {
  const seen = new Set();
  return unique(
    values.filter((value) => {
      if (seen.has(value)) return true;
      seen.add(value);
      return false;
    }),
  );
}

async function listProductionTools(discoveryMode) {
  const env = { ...process.env };
  if (discoveryMode) env.GODOT_MCP_DISCOVERY_MODE = "true";
  else delete env.GODOT_MCP_DISCOVERY_MODE;
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [entryPoint],
    cwd: root,
    env,
    stderr: "pipe",
  });
  const client = new Client({
    name: "godot-mcp-parity-audit",
    version: "1.0.0",
  });
  try {
    await client.connect(transport);
    const response = await client.listTools();
    return response.tools.map((tool) => tool.name);
  } finally {
    await transport.close();
  }
}

export function readDispatchInventory(source) {
  const dispatchStart = source.indexOf("async dispatchTool(");
  if (dispatchStart === -1)
    throw new Error("Built MCP entry point has no dispatchTool method.");
  const dispatchEnd = source.indexOf("\n    }\n    async ", dispatchStart);
  const body = source.slice(
    dispatchStart,
    dispatchEnd === -1 ? source.length : dispatchEnd,
  );
  return [...body.matchAll(/case '([^']+)'/g)].map((match) => match[1]);
}

export function analyzeRegistry({ full, discovery, dispatch }) {
  const findings = [];
  for (const tool of duplicates(full))
    findings.push({ kind: "duplicate_advertised_name", tool, mode: "full" });
  for (const tool of duplicates(discovery))
    findings.push({
      kind: "duplicate_advertised_name",
      tool,
      mode: "discovery",
    });
  for (const tool of duplicates(dispatch))
    findings.push({ kind: "duplicate_dispatch_name", tool });
  for (const tool of full.filter((tool) => !dispatch.includes(tool)))
    findings.push({ kind: "advertised_without_dispatch", tool });
  for (const tool of dispatch.filter((tool) => !full.includes(tool)))
    findings.push({ kind: "dispatch_not_advertised", tool });
  return findings.sort((left, right) =>
    `${left.kind}:${left.tool}`.localeCompare(`${right.kind}:${right.tool}`),
  );
}

export function summarizeParity({
  capabilities,
  mappings: mappingRows,
  fullTools,
  dispatchTools = fullTools,
}) {
  const mappingByCapability = new Map(
    mappingRows.map((mapping) => [mapping.capabilityId, mapping]),
  );
  const states = Object.fromEntries(STATES.map((state) => [state, 0]));
  for (const capability of capabilities) {
    const mapping = mappingByCapability.get(capability.id) ?? {
      state: "gap",
      tools: [],
    };
    if (!STATES.includes(mapping.state))
      throw new Error(
        `Unknown evidence state for ${capability.id}: ${mapping.state}`,
      );
    const state =
      mapping.tools.length > 0 &&
      (!mapping.tools.every((tool) => fullTools.includes(tool)) ||
        !mapping.tools.every((tool) => dispatchTools.includes(tool)))
        ? "broken"
        : mapping.state;
    states[state] += 1;
  }
  const coveredTools = new Set(mappingRows.flatMap((mapping) => mapping.tools));
  const extras = fullTools.filter(
    (tool) => MCP_ONLY.test(tool) && !coveredTools.has(tool),
  );
  return {
    denominator: capabilities.length,
    numerator: states.verified + states.represented_unverified,
    states,
    extras: unique(extras),
  };
}

export async function createAuditReport() {
  const [full, discovery] = await Promise.all([
    listProductionTools(false),
    listProductionTools(true),
  ]);
  const dispatch = readDispatchInventory(readFileSync(entryPoint, "utf8"));
  const findings = analyzeRegistry({ full, discovery, dispatch });
  return {
    generatedFrom: "built production MCP entry point",
    uiBaseline: baseline,
    registry: {
      full: { observed: true, tools: full },
      discovery: { observed: true, tools: discovery },
      dispatch: { observed: true, tools: dispatch },
      claimedTotals: [],
    },
    findings,
    summary: summarizeParity({
      capabilities: baseline.capabilities,
      mappings,
      fullTools: full,
      dispatchTools: dispatch,
    }),
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  createAuditReport()
    .then((report) => {
      if (process.argv.includes("--json"))
        process.stdout.write(`${JSON.stringify(report)}\n`);
      else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    })
    .catch((error) => {
      console.error(
        `audit:parity failed: ${error instanceof Error ? error.message : String(error)}`,
      );
      process.exitCode = 1;
    });
}
