import { readFileSync } from "node:fs";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { describe, expect, it } from "vitest";
import { createParityArtifacts } from "../scripts/parity-report.js";

const root = process.cwd();

async function readLiveProductionInventory(
  discoveryMode: boolean,
): Promise<string[]> {
  const env = { ...process.env };
  if (discoveryMode) env.GODOT_MCP_DISCOVERY_MODE = "true";
  else delete env.GODOT_MCP_DISCOVERY_MODE;
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [join(root, "build", "index.js")],
    cwd: root,
    env,
    stderr: "pipe",
  });
  const client = new Client({
    name: "independent-parity-report-reader",
    version: "1.0.0",
  });
  const tools: string[] = [];
  let cursor: string | undefined;

  try {
    await client.connect(transport);
    do {
      const response = await client.listTools(
        cursor === undefined ? undefined : { cursor },
      );
      tools.push(...response.tools.map((tool) => tool.name));
      cursor = response.nextCursor;
    } while (cursor !== undefined);
    return tools;
  } finally {
    await transport.close();
  }
}

function readBuiltDispatchInventory(): string[] {
  const source = readFileSync(join(root, "build", "index.js"), "utf8");
  const dispatchStart = source.indexOf("async dispatchTool(");
  const dispatchEnd = source.indexOf("\n    }\n    async ", dispatchStart);
  if (dispatchStart === -1)
    throw new Error("The built MCP entry point has no dispatchTool method.");
  return [
    ...source
      .slice(dispatchStart, dispatchEnd === -1 ? source.length : dispatchEnd)
      .matchAll(/case '([^']+)'/g),
  ].map((match) => match[1]);
}

describe("production parity report", () => {
  it("audits_running_production_entrypoint", async () => {
    const [artifacts, expectedFull, expectedDiscovery] = await Promise.all([
      createParityArtifacts(),
      readLiveProductionInventory(false),
      readLiveProductionInventory(true),
    ]);
    const expectedDispatch = readBuiltDispatchInventory();

    expect(
      artifacts.registry.full,
      "full-mode inventory must be observed from the real build/index.js process",
    ).toEqual({ observed: true, tools: expectedFull });
    expect(
      artifacts.registry.discovery,
      "discovery-mode inventory must be observed from the same real build/index.js process",
    ).toEqual({ observed: true, tools: expectedDiscovery });
    expect(
      artifacts.registry.dispatch,
      "direct-dispatch inventory must be extracted from that same built entry point",
    ).toEqual({ observed: true, tools: expectedDispatch });
    expect(
      artifacts.summary.registry,
      "the generated summary must report the independently observed production inventories",
    ).toEqual(
      expect.objectContaining({
        full: { toolCount: expectedFull.length },
        discovery: { toolCount: expectedDiscovery.length },
        dispatch: { toolCount: expectedDispatch.length },
      }),
    );
  }, 15000);
});
