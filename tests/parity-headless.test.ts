import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const SOURCE = "src/index.ts";
const OPERATIONS_SCRIPT = "src/scripts/godot_operations.gd";
const EVIDENCE = "audit/headless-evidence.json";
const STATES = ["verified", "represented_unverified", "broken"];
const MCP_ONLY =
  /^(godot_(?:start_here|suggest|call)|search_tools|list_tool_categories|list_tools_in_category|get_beginner_guide|get_workflow|explain_godot_concept|write_.*_script|setup_.*|create_.*_template)$/;

type HeadlessRecord = {
  tool: string;
  disposition: "ui_capability" | "mcp_only";
  capability?: string;
  rationale?: string;
  route: "bundled_operation" | "direct_godot";
  operation?: string;
  state: string;
  reason: string;
  postcondition?: {
    artifact: string;
    readbackTool: string;
    expected: string;
  };
};

type HeadlessEvidence = {
  generatedFrom: string;
  bundledOperationScript: string;
  records: HeadlessRecord[];
  summary: {
    denominator: number;
    states: Record<string, number>;
    mcpExtras: string[];
  };
};

function methodBodies(source: string): Map<string, string> {
  const starts = [
    ...source.matchAll(/^  private async (handle[A-Za-z0-9]+)\(/gm),
  ];
  return new Map(
    starts.map((match, index) => [
      match[1],
      source.slice(match.index, starts[index + 1]?.index ?? source.length),
    ]),
  );
}

function productionHeadlessTools(): Map<
  string,
  { route: HeadlessRecord["route"]; operation?: string }
> {
  const source = readFileSync(SOURCE, "utf8");
  const bodies = methodBodies(source);
  const dispatched = [
    ...source.matchAll(
      /case '([^']+)':\s+return await this\.(handle[A-Za-z0-9]+)\(args\);/g,
    ),
  ];
  const tools = new Map<
    string,
    { route: HeadlessRecord["route"]; operation?: string }
  >();

  for (const match of dispatched) {
    const body = bodies.get(match[2]) ?? "";
    const operation = body.match(
      /this\.(?:headlessOp|executeOperation)\('([^']+)'/,
    )?.[1];
    if (operation)
      tools.set(match[1], { route: "bundled_operation", operation });
    else if (
      body.includes("execFileAsync(this.godotPath!") &&
      body.includes("'--headless'")
    )
      tools.set(match[1], { route: "direct_godot" });
  }
  return tools;
}

function productionMcpExtras(): string[] {
  const source = readFileSync(SOURCE, "utf8");
  return [
    ...new Set(
      [...source.matchAll(/name:\s*'([^']+)'/g)].map((match) => match[1]),
    ),
  ]
    .filter((tool) => MCP_ONLY.test(tool))
    .sort();
}

function bundledOperations(): Set<string> {
  const source = readFileSync(OPERATIONS_SCRIPT, "utf8");
  const matchBody = source.slice(
    source.indexOf("match operation:"),
    source.indexOf("func ", source.indexOf("match operation:")),
  );
  return new Set(
    [...matchBody.matchAll(/^\s*"([^"]+)":/gm)].map((match) => match[1]),
  );
}

function verificationFailures(
  record: HeadlessRecord,
  available: boolean,
  operations: Set<string>,
): string[] {
  if (record.state !== "verified") return [];
  const failures: string[] = [];
  if (record.route !== "bundled_operation")
    failures.push("verified path must use the bundled operation script");
  if (!record.operation || !operations.has(record.operation))
    failures.push("verified operation is absent from bundled script");
  if (!available)
    failures.push("Godot executable unavailable for production execution");
  if (!record.postcondition?.artifact)
    failures.push("verified evidence lacks project artifact");
  if (!record.postcondition?.readbackTool)
    failures.push("verified evidence lacks production read-back tool");
  if (!record.postcondition?.expected)
    failures.push("verified evidence lacks concrete expected read-back value");
  return failures;
}

function expectedState(
  record: HeadlessRecord,
  available: boolean,
  operations: Set<string>,
) {
  if (
    record.route === "bundled_operation" &&
    !operations.has(record.operation ?? "")
  )
    return {
      state: "broken",
      reason: `Bundled operation ${record.operation} is missing from ${OPERATIONS_SCRIPT}.`,
    };
  if (!available)
    return {
      state: "represented_unverified",
      reason: "Godot executable is unavailable for production MCP execution.",
    };
  return undefined;
}

function unrecordedReason(record: HeadlessRecord): string {
  if (record.route === "direct_godot")
    return "Direct headless Godot route is registered but has no recorded production artifact read-back.";
  return "No recorded production MCP execution and artifact read-back.";
}

function readEvidence(): HeadlessEvidence {
  return JSON.parse(readFileSync(EVIDENCE, "utf8"));
}

describe("headless-path parity evidence", () => {
  it("covers_headless_registry", () => {
    const evidence = readEvidence();
    const production = productionHeadlessTools();
    const classified = evidence.records.map((record) => record.tool);

    expect(
      new Set(classified).size,
      "a production headless tool may have only one disposition",
    ).toBe(classified.length);
    expect([...new Set(classified)].sort()).toEqual(
      [...production.keys()].sort(),
    );
    for (const record of evidence.records) {
      expect(
        ["ui_capability", "mcp_only"],
        `${record.tool} must be classified as a canonical UI capability or an explicit MCP-only exclusion`,
      ).toContain(record.disposition);
      expect(STATES).toContain(record.state);
      if (record.disposition === "ui_capability") {
        expect(
          record.capability,
          `${record.tool} needs a canonical editor capability`,
        ).toMatch(/^[a-z0-9]+(?:-[a-z0-9]+)*$/);
        expect(record.rationale).toBeUndefined();
      } else {
        expect(record.capability).toBeUndefined();
        expect(
          record.rationale,
          `${record.tool} needs a specific MCP-only rationale`,
        ).toMatch(/\S.{15,}/);
      }
      expect(record.route).toBe(production.get(record.tool)?.route);
      expect(record.operation).toBe(production.get(record.tool)?.operation);
    }
  });

  it("requires_real_headless_postcondition", () => {
    const evidence = readEvidence();
    const operations = bundledOperations();
    for (const record of evidence.records)
      expect(
        verificationFailures(record, true, operations),
        `${record.tool} cannot be verified without a real bundled operation and artifact read-back`,
      ).toEqual([]);

    const base: HeadlessRecord = {
      tool: "create_scene",
      disposition: "ui_capability",
      capability: "scene-dock",
      route: "bundled_operation",
      operation: "create_scene",
      state: "verified",
      reason: "test only",
    };
    expect(verificationFailures(base, true, operations)).toEqual([
      "verified evidence lacks project artifact",
      "verified evidence lacks production read-back tool",
      "verified evidence lacks concrete expected read-back value",
    ]);
    expect(
      verificationFailures(
        { ...base, route: "direct_godot" },
        true,
        operations,
      ),
    ).toContain("verified path must use the bundled operation script");
    expect(
      verificationFailures(
        { ...base, operation: "README-only" },
        true,
        operations,
      ),
    ).toContain("verified operation is absent from bundled script");
  });

  it("keeps_unrecorded_production_paths_represented_unverified", () => {
    const evidence = readEvidence();
    const operations = bundledOperations();
    const missingOperation = evidence.records.filter(
      (record) =>
        record.route === "bundled_operation" &&
        !operations.has(record.operation ?? ""),
    );
    const unrecorded = evidence.records.filter(
      (record) => !missingOperation.includes(record),
    );

    expect(missingOperation.length).toBeGreaterThan(0);
    expect(unrecorded.length).toBeGreaterThan(0);
    for (const record of missingOperation) {
      expect(
        record.state,
        `${record.tool} must expose a missing operation`,
      ).toBe("broken");
      expect(
        record.reason,
        `${record.tool} must name its missing operation`,
      ).toBe(
        `Bundled operation ${record.operation} is missing from ${OPERATIONS_SCRIPT}.`,
      );
    }
    for (const record of unrecorded) {
      expect(
        record.state,
        `${record.tool} must remain unverified until a real production MCP write and artifact read-back are recorded`,
      ).toBe("represented_unverified");
      expect(record.reason, `${record.tool} must name the missing proof`).toBe(
        unrecordedReason(record),
      );
    }
  });

  it("classifies_unexercised_headless_paths", () => {
    const evidence = readEvidence();
    const operations = bundledOperations();
    const unavailable = {
      route: "bundled_operation",
      operation: "create_scene",
    } as HeadlessRecord;
    const missing = {
      route: "bundled_operation",
      operation: "missing_operation",
    } as HeadlessRecord;

    expect(expectedState(unavailable, false, operations)).toEqual({
      state: "represented_unverified",
      reason: "Godot executable is unavailable for production MCP execution.",
    });
    expect(expectedState(missing, true, operations)).toEqual({
      state: "broken",
      reason: `Bundled operation missing_operation is missing from ${OPERATIONS_SCRIPT}.`,
    });
    for (const record of evidence.records) {
      const expected = expectedState(record, true, operations);
      if (expected) {
        expect(
          record.state,
          `${record.tool} must not be falsely verified`,
        ).toBe(expected.state);
        expect(
          record.reason,
          `${record.tool} must state the missing prerequisite`,
        ).toBe(expected.reason);
      }
    }
  });

  it("reconciles_headless_totals", () => {
    const evidence = readEvidence();
    const extras = productionMcpExtras();
    const stateCounts = Object.fromEntries(STATES.map((state) => [state, 0]));
    for (const record of evidence.records) stateCounts[record.state] += 1;

    expect(evidence.generatedFrom).toContain("production MCP dispatch");
    expect(evidence.bundledOperationScript).toBe(OPERATIONS_SCRIPT);
    expect(evidence.summary.denominator).toBe(evidence.records.length);
    expect(evidence.summary.states).toEqual(stateCounts);
    expect(
      evidence.summary.mcpExtras,
      "navigation and generated-template helpers must be excluded from the headless UI denominator and reported only as MCP extras",
    ).toEqual(extras);
    expect(evidence.records.some((record) => MCP_ONLY.test(record.tool))).toBe(
      false,
    );
    expect(
      evidence.records.some((record) =>
        /^(?:godot_start_here|search_tools|list_tools)/.test(record.tool),
      ),
    ).toBe(false);
  });
});
