import { describe, expect, it } from "vitest";
import {
  assertAuditCoverage,
  buildParityArtifacts,
  renderParityReport,
} from "../scripts/parity-report.js";

const baseline = {
  godotVersion: "4.4",
  capabilities: [
    {
      id: "baseline-verified",
      editorSurface: "Project Manager",
      userAction: "Create a project",
      source: { version: "4.4", url: "https://example.test/baseline-verified" },
    },
    {
      id: "baseline-gap",
      editorSurface: "Scene dock",
      userAction: "Save a scene",
      source: { version: "4.4", url: "https://example.test/baseline-gap" },
    },
  ],
};

const evidence = {
  mappings: [
    {
      capabilityId: "baseline-verified",
      tools: ["create_project"],
      state: "verified",
    },
  ],
  editor: {
    records: [
      {
        capabilityId: "editor-broken",
        disposition: "ui_capability",
        mcpTools: ["editor_save_scene"],
        state: "broken",
        dogfood: { observableResult: "The scene saves in the editor." },
      },
    ],
  },
  headless: {
    records: [
      {
        tool: "create_scene",
        disposition: "ui_capability",
        capability: "scene-dock",
        route: "bundled_operation",
        state: "represented_unverified",
        reason: "No production artifact read-back is recorded.",
      },
    ],
  },
  runtime: {
    records: [
      {
        capabilityId: "runtime-gap",
        disposition: "ui_capability",
        tools: ["inspect_runtime"],
        commands: ["inspect_runtime"],
        state: "gap",
        reason: "The runtime command has no represented capability.",
      },
    ],
  },
  registry: {
    full: { tools: ["create_project", "create_scene", "inspect_runtime"] },
    discovery: { tools: ["create_project"] },
    dispatch: { tools: ["create_project", "create_scene", "inspect_runtime"] },
    findings: [
      { kind: "advertised_without_dispatch", tool: "would-be-inconsistent" },
      { kind: "readme_only_claim", claimedTotal: 1969 },
    ],
    mcpOnlyExtras: ["godot_start_here"],
  },
};

describe("generated MCP versus UI parity report", () => {
  it("calculates_parity_metrics", () => {
    const artifacts = buildParityArtifacts({ baseline, ...evidence });

    expect(artifacts.summary.godotBaseline).toBe("4.4");
    expect(artifacts.summary.denominator).toBe(5);
    expect(artifacts.summary.states).toEqual({
      verified: 1,
      represented_unverified: 1,
      broken: 1,
      gap: 2,
    });
    expect(artifacts.summary.verifiedParityPercent).toBe(20);
    expect(artifacts.summary.representedParityPercent).toBe(40);
    expect(artifacts.summary.bySurface["Project Manager"].verified).toBe(1);
    expect(artifacts.summary.bySurface["Godot editor plugin"].broken).toBe(1);
    expect(
      artifacts.summary.byPath.bundled_operation.represented_unverified,
    ).toBe(1);
    expect(artifacts.summary.byPath.runtime.gap).toBe(1);
  });

  it("exports_complete_unprioritized_gaps", () => {
    const artifacts = buildParityArtifacts({ baseline, ...evidence });

    expect(artifacts.gaps.map((gap) => gap.id)).toEqual([
      "baseline:baseline-gap",
      "editor:editor-broken",
      "runtime:runtime-gap",
    ]);
    for (const gap of artifacts.gaps) {
      expect(gap.uiSurface).toMatch(/\S/);
      expect(gap.userOutcome).toMatch(/\S/);
      expect(gap.sourceReference).toMatch(/\S/);
      expect(gap.relatedMcpTools).toEqual(expect.any(Array));
      expect(gap.evidenceReason).toMatch(/\S/);
      expect(JSON.stringify(gap)).not.toMatch(/priority|rank|score/i);
    }
    const report = renderParityReport(artifacts);
    expect(report).toContain("## Broken or missing capabilities");
    expect(report).toContain("baseline:baseline-gap");
    expect(report).toContain("runtime:runtime-gap");
  });

  it("detects_unmapped_drift", () => {
    expect(() =>
      assertAuditCoverage({
        canonicalCapabilities: ["mapped-capability", "new-capability"],
        mappingCapabilities: ["mapped-capability"],
        productionTools: ["mapped-tool", "new-tool"],
        dispositionTools: ["mapped-tool"],
      }),
    ).toThrow(/new-capability.*new-tool/);

    const before = renderParityReport(
      buildParityArtifacts({ baseline, ...evidence }),
    );
    const after = renderParityReport(
      buildParityArtifacts({
        baseline,
        ...evidence,
        registry: {
          ...evidence.registry,
          findings: [
            {
              kind: "advertised_without_dispatch",
              tool: "would-be-inconsistent",
            },
            { kind: "readme_only_claim", claimedTotal: 1969 },
            { kind: "readme_only_claim", claimedTotal: 1 },
          ],
        },
      }),
    );
    expect(after).toBe(before);
  });
});
