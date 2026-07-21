import { existsSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const REQUIRED_PLUGIN_FILES = [
  "src/scripts/editor_mcp_server.gd",
  "src/scripts/plugin.cfg",
];
const STATES = ["verified", "represented_unverified", "broken", "gap"];
const DOGFOOD_PLACEHOLDER =
  /^\s*(?:action|do this|n\/?a|none|observable result|placeholder|result|same as above|setup|tbd|todo|unknown|works)\s*[.!]?\s*$/i;
const SETUP_CONTEXT =
  /\b(?:scene|project|plugin|filesystem|inspector|viewport|resource|png|node2d|sprite2d)\b/i;
const OBSERVABLE_SURFACE =
  /\b(?:scene dock|filesystem dock|inspector|viewport|response|game window|scene tab|import dock|resource)\b/i;
const OBSERVABLE_CHANGE =
  /\b(?:appears|becomes|centers|changes|clears|closes|created|disappears|ends|highlighted|lists|opens|preserves|reflects|reimports|returns|shows|switches|visible)\b/i;

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

function sourceToolRegistrations(): Set<string> {
  const source = readFileSync("src/index.ts", "utf8");
  return new Set(
    [...source.matchAll(/name:\s*'([^']+)'/g)].map((match) => match[1]),
  );
}

function dogfoodRecipeFailures(
  record: EditorEvidence["records"][number],
): string[] {
  const dogfood = record.dogfood;
  if (!dogfood) return ["missing dogfood recipe"];

  const failures: string[] = [];
  for (const [field, value] of Object.entries(dogfood)) {
    if (DOGFOOD_PLACEHOLDER.test(value))
      failures.push(`${field} is a placeholder`);
  }
  if (!SETUP_CONTEXT.test(dogfood.setup))
    failures.push("setup lacks an editor context");
  if (!record.mcpTools.some((tool) => dogfood.action.includes(tool)))
    failures.push("action does not name a capability tool");
  if (!OBSERVABLE_SURFACE.test(dogfood.observableResult))
    failures.push("observable result lacks an editor surface");
  if (!OBSERVABLE_CHANGE.test(dogfood.observableResult))
    failures.push("observable result lacks a visible change");
  return failures;
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
    const sourceRegisteredTools = sourceToolRegistrations();
    const represented = evidence.records.filter(
      (record) => record.disposition === "ui_capability",
    );
    const mappedCommands = represented.flatMap(
      (record) => record.handlerCommands,
    );
    const mappedTools = represented.flatMap((record) => record.mcpTools);

    expect(evidence.requiredPluginFiles).toEqual(REQUIRED_PLUGIN_FILES);
    expect(new Set(editorCommands).size).toBe(editorCommands.length);
    expect(new Set(mappedCommands).size).toBe(mappedCommands.length);
    expect(mappedCommands.sort()).toEqual([...editorCommands].sort());
    expect(new Set(mappedTools).size).toBe(mappedTools.length);
    expect(
      mappedTools.sort(),
      "every TypeScript tool that dispatches to port 9091 must have an evidence disposition, including aliases sharing a handler",
    ).toEqual([...sourceToolCommands.keys()].sort());
    for (const tool of sourceToolCommands.keys()) {
      expect(
        sourceRegisteredTools.has(tool),
        `${tool} must be registered by the production MCP server as well as dispatched to the editor`,
      ).toBe(true);
    }
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
        dogfoodRecipeFailures(record),
        `${record.capabilityId} needs a concrete setup, a named MCP action, and an observable editor result`,
      ).toEqual([]);
    }

    const mutableRecord = evidence.records.find(
      (record) => record.disposition === "ui_capability",
    );
    if (!mutableRecord) throw new Error("fixture needs an editor capability");
    expect(
      dogfoodRecipeFailures({
        ...mutableRecord,
        dogfood: {
          setup: "TODO",
          action: "Do this",
          observableResult: "Works",
        },
      }),
      "placeholder recipes must not count as manual verification evidence",
    ).toEqual([
      "setup is a placeholder",
      "action is a placeholder",
      "observableResult is a placeholder",
      "setup lacks an editor context",
      "action does not name a capability tool",
      "observable result lacks an editor surface",
      "observable result lacks a visible change",
    ]);
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
