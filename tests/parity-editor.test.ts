import { existsSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const REQUIRED_PLUGIN_FILES = [
  "src/scripts/editor_mcp_server.gd",
  "src/scripts/plugin.cfg",
];
const STATES = ["verified", "represented_unverified", "broken", "gap"];

interface EditorEvidence {
  requiredPluginFiles: string[];
  summary: {
    denominator: number;
    numerator: number;
    states: Record<string, number>;
  };
  records: Array<{
    capabilityId?: string;
    disposition: "ui_capability" | "mcp_only";
    mcpTools: string[];
    handlerCommands: string[];
    state?: string;
    representation?: string;
    dogfood?: {
      setup: string;
      action: string;
      observableResult: string;
    };
  }>;
}

function readEvidence(): EditorEvidence {
  return JSON.parse(readFileSync("audit/editor-evidence.json", "utf8"));
}

function sourceEditorCommands(): string[] {
  const source = readFileSync("src/index.ts", "utf8");
  return [...source.matchAll(/editorCommand\('([^']+)'/g)].map(
    (match) => match[1],
  );
}

function sourceEditorToolCommands(): Map<string, string> {
  const source = readFileSync("src/index.ts", "utf8");
  const commandByHandler = new Map<string, string>();
  for (const match of source.matchAll(/editorCommand\('([^']+)'/g)) {
    const handlerStart = source.lastIndexOf("\n  private async ", match.index);
    const handlerNameStart = handlerStart + "\n  private async ".length;
    const handlerNameEnd = source.indexOf("(", handlerNameStart);
    commandByHandler.set(
      source.slice(handlerNameStart, handlerNameEnd),
      match[1],
    );
  }

  const toolCommands = new Map<string, string>();
  for (const match of source.matchAll(
    /case '([^']+)':\s+return await this\.(handle[A-Za-z0-9]+)\(args\);/g,
  )) {
    const command = commandByHandler.get(match[2]);
    if (command) toolCommands.set(match[1], command);
  }
  return toolCommands;
}

function pluginEvidenceFailures(
  requiredPluginFiles: string[],
  handlerCommands: string[],
  pluginSource: string | undefined,
): string[] {
  const failures = requiredPluginFiles.filter((path) => !existsSync(path));
  if (pluginSource === undefined) return failures;
  for (const command of handlerCommands)
    if (
      !pluginSource.includes(`"${command}"`) &&
      !pluginSource.includes(`'${command}'`)
    )
      failures.push(`handler:${command}`);
  return failures;
}

function effectiveState(
  record: EditorEvidence["records"][number],
  pluginFailures: string[],
  sourceCommands: string[],
) {
  if (record.disposition === "mcp_only") return "mcp_only";
  if (
    pluginFailures.length > 0 ||
    !record.handlerCommands.every((command) => sourceCommands.includes(command))
  )
    return "broken";
  return record.state;
}

describe("editor-path parity evidence", () => {
  it("maps_editor_registry_once", () => {
    const evidence = readEvidence();
    const editorCommands = sourceEditorCommands();
    const sourceToolCommands = sourceEditorToolCommands();
    const represented = evidence.records.filter(
      (record) => record.disposition === "ui_capability",
    );
    const mappedCommands = represented.flatMap(
      (record) => record.handlerCommands,
    );

    expect(evidence.requiredPluginFiles).toEqual(REQUIRED_PLUGIN_FILES);
    expect(new Set(editorCommands).size).toBe(editorCommands.length);
    expect(new Set(mappedCommands).size).toBe(mappedCommands.length);
    expect(mappedCommands.sort()).toEqual([...editorCommands].sort());
    for (const record of represented) {
      expect(record.mcpTools.length).toBe(record.handlerCommands.length);
      for (const [index, tool] of record.mcpTools.entries())
        expect(
          sourceToolCommands.get(tool),
          `${tool} must dispatch to the declared port-9091 handler`,
        ).toBe(record.handlerCommands[index]);
    }
    const transportRecords = evidence.records.filter(
      (record) => record.disposition === "mcp_only",
    );
    const transportTools = transportRecords.flatMap(
      (record) => record.mcpTools,
    );
    expect(transportTools.sort()).toEqual([
      "connect_to_godot_editor",
      "disconnect_from_godot_editor",
    ]);
    const source = readFileSync("src/index.ts", "utf8");
    for (const tool of transportTools) {
      expect(source).toContain(`name: '${tool}'`);
      expect(source).toContain(`case '${tool}'`);
    }
    expect(
      new Set(represented.map((record) => record.capabilityId)).size,
      "each editor UI capability must have one canonical disposition even when several MCP aliases map to it",
    ).toBe(represented.length);
    expect(
      represented.some((record) => record.mcpTools.length > 1),
      "the fixture must contain aliases so the one-capability denominator is proven rather than assumed",
    ).toBe(true);
    expect(
      represented.length,
      "adding another alias to a record must not add a new canonical UI capability",
    ).toBe(new Set(represented.map((record) => record.capabilityId)).size);
    for (const record of evidence.records) {
      if (record.disposition === "ui_capability")
        expect(record.capabilityId).toMatch(/^[a-z0-9]+(?:-[a-z0-9]+)*$/);
      else expect(record.capabilityId).toBeUndefined();
    }
  });

  it("requires_shipped_editor_plugin", () => {
    const evidence = readEvidence();
    const sourceCommands = sourceEditorCommands();
    const pluginSourcePath = evidence.requiredPluginFiles[0];
    const pluginSource = existsSync(pluginSourcePath)
      ? readFileSync(pluginSourcePath, "utf8")
      : undefined;
    const pluginFailures = pluginEvidenceFailures(
      evidence.requiredPluginFiles,
      [],
      pluginSource,
    );
    const dependentRecords = evidence.records.filter(
      (record) => record.disposition === "ui_capability",
    );

    expect(pluginFailures.sort()).toEqual([...REQUIRED_PLUGIN_FILES].sort());
    for (const record of dependentRecords) {
      const recordPluginFailures = pluginEvidenceFailures(
        evidence.requiredPluginFiles,
        record.handlerCommands,
        pluginSource,
      );
      expect(
        effectiveState(record, recordPluginFailures, sourceCommands),
        `${record.capabilityId} must be broken when the required editor plugin files are absent`,
      ).toBe("broken");
      expect(record.state).toBe("broken");
      expect(record.representation).toBe("represented_unverified");
      expect(record.handlerCommands.length).toBeGreaterThan(0);
      expect(
        record.handlerCommands.every((command) =>
          sourceCommands.includes(command),
        ),
        `${record.capabilityId} must name commands actually routed by TypeScript to the editor port`,
      ).toBe(true);
    }
    expect(
      pluginEvidenceFailures(
        [],
        ["missing_handler"],
        'func dispatch(command):\n  match command:\n    "present_handler": pass',
      ),
      "a shipped plugin that lacks a TypeScript-routed command must not count as coverage",
    ).toEqual(["handler:missing_handler"]);
  });

  it("validates_editor_dogfood_recipes", () => {
    const evidence = readEvidence();
    const sourceCommands = sourceEditorCommands();
    const pluginSourcePath = evidence.requiredPluginFiles[0];
    const pluginSource = existsSync(pluginSourcePath)
      ? readFileSync(pluginSourcePath, "utf8")
      : undefined;

    for (const record of evidence.records) {
      const state = effectiveState(
        record,
        pluginEvidenceFailures(
          evidence.requiredPluginFiles,
          record.handlerCommands,
          pluginSource,
        ),
        sourceCommands,
      );
      if (state === "mcp_only") continue;
      expect(STATES).toContain(state);
      expect(
        record.dogfood?.setup,
        `${record.capabilityId} needs dogfood setup`,
      ).toMatch(/\S/);
      expect(
        record.dogfood?.action,
        `${record.capabilityId} needs dogfood action`,
      ).toMatch(/\S/);
      expect(
        record.dogfood?.observableResult,
        `${record.capabilityId} needs a concrete observable result`,
      ).toMatch(/\S/);
    }
  });

  it("reconciles_editor_totals", () => {
    const evidence = readEvidence();
    const sourceCommands = sourceEditorCommands();
    const pluginSourcePath = evidence.requiredPluginFiles[0];
    const pluginSource = existsSync(pluginSourcePath)
      ? readFileSync(pluginSourcePath, "utf8")
      : undefined;
    const represented = evidence.records.filter(
      (record) => record.disposition === "ui_capability",
    );
    const states = Object.fromEntries(STATES.map((state) => [state, 0]));

    for (const record of represented) {
      const state = effectiveState(
        record,
        pluginEvidenceFailures(
          evidence.requiredPluginFiles,
          record.handlerCommands,
          pluginSource,
        ),
        sourceCommands,
      );
      expect(STATES).toContain(state);
      states[state as keyof typeof states] += 1;
    }

    expect(new Set(represented.map((record) => record.capabilityId)).size).toBe(
      represented.length,
    );
    expect(
      Object.values(states).reduce((total, count) => total + count, 0),
    ).toBe(represented.length);
    const expectedSummary = {
      denominator: represented.length,
      numerator: states.verified + states.represented_unverified,
      states,
    };
    expect(expectedSummary).toEqual({
      denominator: 12,
      numerator: 0,
      states: {
        verified: 0,
        represented_unverified: 0,
        broken: represented.length,
        gap: 0,
      },
    });
    expect(evidence.summary).toEqual(expectedSummary);
  });
});
