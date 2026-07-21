import { execFileSync } from "node:child_process";
import { describe, expect, it } from "vitest";
import { createRecommendations } from "../scripts/audit-parity.js";

function runAudit() {
  const stdout = execFileSync(
    "npm",
    ["run", "--silent", "audit:parity", "--", "--json"],
    {
      cwd: process.cwd(),
      encoding: "utf8",
      env: process.env,
      maxBuffer: 20 * 1024 * 1024,
    },
  );
  return JSON.parse(stdout);
}

describe("parity prioritization", () => {
  it("emits_ranked_contract_from_production_cli", () => {
    const audit = runAudit();
    const recommendations = audit.recommendations;

    for (const action of ["add", "repair", "verify"]) {
      expect(
        Array.isArray(recommendations?.[action]),
        `production JSON must include the ${action} recommendation lane`,
      ).toBe(true);
      for (const [index, recommendation] of recommendations[action].entries()) {
        expect(recommendation.rank, `${action} rank must be contiguous`).toBe(
          index + 1,
        );
        expect(
          recommendation.action,
          `${action} action must match its lane`,
        ).toBe(action);
        expect(typeof recommendation.source, "source must be a string").toBe(
          "string",
        );
        expect(
          typeof recommendation.capabilityId,
          "capabilityId must be a string",
        ).toBe("string");
        expect(typeof recommendation.state, "state must be a string").toBe(
          "string",
        );
        expect(Array.isArray(recommendation.affectedTools)).toBe(true);
        expect(Array.isArray(recommendation.evidenceRefs)).toBe(true);
        expect(
          typeof recommendation.rationale,
          "rationale must be concrete text",
        ).toBe("string");
        expect(recommendation.rationale.length).toBeGreaterThan(0);
      }
    }
  }, 15000);

  it("ranks_import_project_as_next_true_addition", () => {
    const audit = runAudit();

    expect(audit.recommendations.add).toEqual([
      {
        rank: 1,
        action: "add",
        source: "baseline",
        capabilityId: "project-manager-import-project",
        state: "gap",
        affectedTools: [],
        evidenceRefs: ["audit/mappings.json", "audit/ui-baseline.json"],
        rationale:
          "Import an existing Godot project in the Project Manager has no MCP tool mapping, so MCP needs an addition.",
      },
    ]);
  }, 15000);

  it("separates_complete_repair_and_verification_inventories", () => {
    const audit = runAudit();
    const keys = (action: "repair" | "verify") =>
      audit.recommendations[action]
        .map(
          (recommendation: any) =>
            `${recommendation.action}:${recommendation.source}:${recommendation.capabilityId}`,
        )
        .sort();

    expect(audit.recommendations.add).toHaveLength(1);
    expect(audit.recommendations.repair).toHaveLength(21);
    expect(audit.recommendations.verify).toHaveLength(19);
    expect(
      [...new Set(audit.recommendations.repair.map(({ state }: any) => state))],
      "repair recommendations must preserve the broken evidence state rather than their action label",
    ).toEqual(["broken"]);
    expect(
      [...new Set(audit.recommendations.verify.map(({ state }: any) => state))],
      "verify recommendations must preserve the represented-unverified evidence state rather than their action label",
    ).toEqual(["represented_unverified"]);
    expect(keys("repair")).toEqual([
      "repair:editor:editor-filesystem-browsing",
      "repair:editor:editor-inspector-access",
      "repair:editor:editor-resource-reimport",
      "repair:editor:editor-scene-execution",
      "repair:editor:editor-scene-lifecycle",
      "repair:editor:editor-scene-saving",
      "repair:editor:editor-scene-tree-inspection",
      "repair:editor:editor-scene-tree-mutation",
      "repair:editor:editor-scene-tree-selection",
      "repair:editor:editor-script-authoring",
      "repair:editor:editor-undo-redo",
      "repair:editor:editor-viewport-focus",
      "repair:headless:import-dock",
      "repair:headless:project-settings",
      "repair:headless:resource-editor",
      "repair:headless:scene-dock",
      "repair:headless:script-editor",
      "repair:runtime:runtime-game-control",
      "repair:runtime:runtime-live-node-mutation",
      "repair:runtime:runtime-remote-inspection",
      "repair:runtime:runtime-rendering-visual-control",
    ]);
    expect(keys("verify")).toEqual([
      "verify:baseline:inspector-edit-property",
      "verify:baseline:output-panel-view-errors",
      "verify:baseline:scene-dock-create-node",
      "verify:baseline:scene-dock-save-scene",
      "verify:baseline:script-editor-create-script",
      "verify:headless:export-dialog",
      "verify:headless:import-dock",
      "verify:headless:project-settings",
      "verify:headless:resource-editor",
      "verify:headless:scene-dock",
      "verify:headless:script-editor",
      "verify:runtime:runtime-animation-control",
      "verify:runtime:runtime-audio-control",
      "verify:runtime:runtime-debugging",
      "verify:runtime:runtime-input-control",
      "verify:runtime:runtime-network-system-control",
      "verify:runtime:runtime-performance-monitoring",
      "verify:runtime:runtime-physics-control",
      "verify:runtime:runtime-scene-execution-control",
    ]);
  }, 15000);

  it("deduplicates_and_stably_orders_findings", () => {
    const input = {
      capabilities: [
        {
          id: "project-manager-import-project",
          userAction: "Import an existing project",
          editorSurface: "Project Manager",
        },
      ],
      mappings: [
        {
          capabilityId: "project-manager-import-project",
          tools: [],
          state: "gap",
        },
      ],
      editorRecords: [
        {
          disposition: "ui_capability",
          capabilityId: "editor-alpha",
          state: "broken",
          mcpTools: ["small_tool"],
          reason: "small editor route is broken",
        },
        {
          disposition: "ui_capability",
          capabilityId: "editor-zulu",
          state: "broken",
          mcpTools: ["large_tool_one", "large_tool_two"],
          reason: "large editor route is broken",
        },
      ],
      runtimeRecords: [],
      headlessRecords: [],
    };
    const canonical = createRecommendations(input);
    const shuffledAndDuplicated = createRecommendations({
      ...input,
      editorRecords: [
        input.editorRecords[1],
        input.editorRecords[0],
        input.editorRecords[1],
      ],
    });

    expect(shuffledAndDuplicated).toEqual(canonical);
    expect(
      canonical.repair.map((recommendation) => recommendation.capabilityId),
      "larger affected-tool groups must rank first before the stable key tie-break",
    ).toEqual(["editor-zulu", "editor-alpha"]);

    const repairedToUnverified = createRecommendations({
      ...input,
      editorRecords: [
        {
          ...input.editorRecords[0],
          state: "represented_unverified",
        },
        input.editorRecords[1],
      ],
    });
    expect(
      repairedToUnverified.repair.some(
        (recommendation) => recommendation.capabilityId === "editor-alpha",
      ),
      "a represented-unverified finding must not remain in repair",
    ).toBe(false);
    expect(
      repairedToUnverified.verify.filter(
        (recommendation) => recommendation.capabilityId === "editor-alpha",
      ),
      "a state change must create exactly one verification recommendation",
    ).toHaveLength(1);
  });

  it("uses_the_stable_key_tie_break_for_equal_breadth_groups", () => {
    const input = {
      capabilities: [],
      mappings: [],
      editorRecords: [
        {
          disposition: "ui_capability",
          capabilityId: "editor-zulu",
          state: "broken",
          mcpTools: ["zulu_tool"],
          reason: "zulu editor route is broken",
        },
        {
          disposition: "ui_capability",
          capabilityId: "editor-alpha",
          state: "broken",
          mcpTools: ["alpha_tool"],
          reason: "alpha editor route is broken",
        },
      ],
      runtimeRecords: [],
      headlessRecords: [],
    };

    const recommendations = createRecommendations(input);
    const reorderedRecommendations = createRecommendations({
      ...input,
      editorRecords: [...input.editorRecords].reverse(),
    });

    expect(
      recommendations.repair.map(({ capabilityId, rank }) => ({
        capabilityId,
        rank,
      })),
      "equal breadth repair groups must use their stable key rather than evidence insertion order",
    ).toEqual([
      { capabilityId: "editor-alpha", rank: 1 },
      { capabilityId: "editor-zulu", rank: 2 },
    ]);
    expect(
      reorderedRecommendations.repair,
      "reordered equal breadth evidence must retain the canonical recommendation ranks",
    ).toEqual(recommendations.repair);
  });

  it("uses_source_in_the_stable_key_for_equal_breadth_same_capability_groups", () => {
    const input = {
      capabilities: [],
      mappings: [],
      editorRecords: [],
      runtimeRecords: [
        {
          disposition: "ui_capability",
          capabilityId: "shared-evidence-capability",
          state: "broken",
          tools: ["runtime_only_tool"],
          reason: "runtime path is broken",
        },
      ],
      headlessRecords: [
        {
          disposition: "ui_capability",
          capability: "shared-evidence-capability",
          state: "broken",
          tool: "headless_only_tool",
          reason: "headless path is broken",
        },
      ],
    };

    const canonical = createRecommendations(input);
    const duplicated = createRecommendations({
      ...input,
      runtimeRecords: [...input.runtimeRecords, input.runtimeRecords[0]],
      headlessRecords: [...input.headlessRecords, input.headlessRecords[0]],
    });

    expect(
      canonical.repair.map(({ rank, source, capabilityId, affectedTools }) => ({
        rank,
        source,
        capabilityId,
        affectedTools,
      })),
      "equal-breadth findings with the same capability must use source in their stable key rather than retain runtime-first ingestion order",
    ).toEqual([
      {
        rank: 1,
        source: "headless",
        capabilityId: "shared-evidence-capability",
        affectedTools: ["headless_only_tool"],
      },
      {
        rank: 2,
        source: "runtime",
        capabilityId: "shared-evidence-capability",
        affectedTools: ["runtime_only_tool"],
      },
    ]);
    expect(
      duplicated.repair,
      "duplicating same-capability findings must preserve source-qualified ranks and deduplicate each group",
    ).toEqual(canonical.repair);
  });

  it("keeps_source_qualified_groups_and_source_tool_fields_distinct", () => {
    const recommendations = createRecommendations({
      capabilities: [
        {
          id: "cross-source-collision",
          userAction: "Repair the baseline capability",
          editorSurface: "Project Manager",
        },
      ],
      mappings: [
        {
          capabilityId: "cross-source-collision",
          state: "broken",
          tools: ["baseline_only_tool"],
        },
      ],
      editorRecords: [
        {
          disposition: "ui_capability",
          capabilityId: "cross-source-collision",
          state: "broken",
          mcpTools: ["editor_only_tool"],
          reason: "editor route is broken",
        },
      ],
      runtimeRecords: [
        {
          disposition: "ui_capability",
          capabilityId: "runtime-broad",
          state: "broken",
          tools: ["runtime_first_tool", "runtime_second_tool"],
          reason: "runtime route is broken",
        },
      ],
      headlessRecords: [
        {
          disposition: "ui_capability",
          capability: "headless-single",
          state: "broken",
          tool: "headless_only_tool",
          reason: "headless route is broken",
        },
      ],
    });

    expect(
      recommendations.repair.map(
        ({ rank, source, capabilityId, affectedTools, evidenceRefs }) => ({
          rank,
          source,
          capabilityId,
          affectedTools,
          evidenceRefs,
        }),
      ),
      "source-qualified keys must not merge same-action findings, and every source must preserve its actual MCP tools for breadth ranking",
    ).toEqual([
      {
        rank: 1,
        source: "runtime",
        capabilityId: "runtime-broad",
        affectedTools: ["runtime_first_tool", "runtime_second_tool"],
        evidenceRefs: ["audit/runtime-evidence.json"],
      },
      {
        rank: 2,
        source: "baseline",
        capabilityId: "cross-source-collision",
        affectedTools: ["baseline_only_tool"],
        evidenceRefs: ["audit/mappings.json", "audit/ui-baseline.json"],
      },
      {
        rank: 3,
        source: "editor",
        capabilityId: "cross-source-collision",
        affectedTools: ["editor_only_tool"],
        evidenceRefs: ["audit/editor-evidence.json"],
      },
      {
        rank: 4,
        source: "headless",
        capabilityId: "headless-single",
        affectedTools: ["headless_only_tool"],
        evidenceRefs: ["audit/headless-evidence.json"],
      },
    ]);
  });
});
