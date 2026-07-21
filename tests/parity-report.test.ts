import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  assertAuditCoverage,
  buildParityArtifacts,
  createParityArtifacts,
  renderParityReport,
} from "../scripts/parity-report.js";

const root = process.cwd();

function formatGapDataset(gaps: unknown): string {
  return `${JSON.stringify(gaps, null, 2).replace(
    /"relatedMcpTools": \[\n((?:\s+"[^"]+",?\n)+)\s+\]/g,
    (_match, values: string) =>
      `"relatedMcpTools": [${values.match(/"[^"]+"/g).join(", ")}]`,
  )}\n`;
}

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

  it("renders_the_exact_baseline_denominator_percentages_and_surface_path_totals", () => {
    const report = renderParityReport(
      buildParityArtifacts({ baseline, ...evidence }),
    );

    expect(report).toContain("Godot baseline: 4.4");
    expect(report).toContain("Canonical UI capability denominator: 5");
    expect(report).toContain("Strict verified parity: 20% (1/5)");
    expect(report).toContain("Represented parity: 40% (2/5)");
    expect(report).toContain("| Project Manager | 1 | 0 | 0 | 0 |");
    expect(report).toContain("| Godot editor plugin | 0 | 0 | 1 | 0 |");
    expect(report).toContain("| bundled_operation | 0 | 1 | 0 | 0 |");
    expect(report).toContain("| runtime | 0 | 0 | 0 | 1 |");
  });

  it("exports_complete_unprioritized_gaps", () => {
    const artifacts = buildParityArtifacts({ baseline, ...evidence });

    expect(artifacts.gaps.map((gap) => gap.id)).toEqual([
      "baseline:baseline-gap",
      "editor:editor-broken",
      "runtime:runtime-gap",
    ]);
    expect(artifacts.gaps).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: "baseline:baseline-gap",
          uiSurface: "Scene dock",
          userOutcome: "Save a scene",
          sourceReference: "https://example.test/baseline-gap",
          relatedMcpTools: [],
          evidenceReason:
            "No MCP disposition is recorded for this canonical UI capability.",
        }),
        expect.objectContaining({
          id: "editor:editor-broken",
          uiSurface: "Godot editor plugin",
          userOutcome: "The scene saves in the editor.",
          sourceReference: "audit/editor-evidence.json#records/0",
          relatedMcpTools: ["editor_save_scene"],
          evidenceReason:
            "Editor evidence records this capability as broken; no representation evidence.",
        }),
        expect.objectContaining({
          id: "runtime:runtime-gap",
          uiSurface: "Running game",
          userOutcome: "Use the runtime-gap running-game capability.",
          sourceReference: "audit/runtime-evidence.json#records/0",
          relatedMcpTools: ["inspect_runtime"],
          evidenceReason: "The runtime command has no represented capability.",
        }),
      ]),
    );
    for (const gap of artifacts.gaps) {
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

  it("downgrades_verified_or_represented_records_without_full_and_dispatch_exposure_in_every_evidence_slice", () => {
    const artifacts = buildParityArtifacts({
      baseline: {
        ...baseline,
        capabilities: [
          ...baseline.capabilities,
          {
            id: "baseline-dispatch-only",
            editorSurface: "Node dock",
            userAction: "Rename a node",
            source: {
              version: "4.4",
              url: "https://example.test/baseline-dispatch-only",
            },
          },
        ],
      },
      mappings: [
        ...evidence.mappings,
        {
          capabilityId: "baseline-dispatch-only",
          tools: ["dispatch_only_tool"],
          state: "verified",
        },
      ],
      editor: {
        records: [
          {
            capabilityId: "editor-full-only",
            disposition: "ui_capability",
            mcpTools: ["editor_full_only_tool"],
            state: "verified",
            dogfood: { observableResult: "Editor action is available." },
          },
        ],
      },
      headless: {
        records: [
          {
            tool: "headless-dispatch-only-tool",
            disposition: "ui_capability",
            capability: "headless-surface",
            route: "bundled_operation",
            state: "represented_unverified",
            reason: "The operation has a representation.",
          },
        ],
      },
      runtime: {
        records: [
          {
            capabilityId: "runtime-full-only",
            disposition: "ui_capability",
            tools: ["runtime_full_only_tool"],
            state: "verified",
            reason: "The command has a representation.",
          },
        ],
      },
      registry: {
        ...evidence.registry,
        full: {
          tools: [
            "create_project",
            "create_scene",
            "inspect_runtime",
            "editor_full_only_tool",
            "runtime_full_only_tool",
          ],
        },
        dispatch: {
          tools: [
            "create_project",
            "create_scene",
            "inspect_runtime",
            "headless-dispatch-only-tool",
            "dispatch_only_tool",
          ],
        },
      },
    });

    for (const id of [
      "baseline:baseline-dispatch-only",
      "editor:editor-full-only",
      "headless:headless-dispatch-only-tool",
      "runtime:runtime-full-only",
    ]) {
      expect(
        artifacts.records.find((record) => record.id === id)?.state,
        `${id} must be broken when any represented tool is absent from one production inventory`,
      ).toBe("broken");
    }
  });

  it("does_not_count_empty_tool_mappings_as_direct_exposure_in_baseline_editor_or_runtime_evidence", () => {
    const artifacts = buildParityArtifacts({
      baseline: {
        ...baseline,
        capabilities: [
          ...baseline.capabilities,
          {
            id: "baseline-empty-tools",
            editorSurface: "Inspector",
            userAction: "Edit an exported property",
            source: {
              version: "4.4",
              url: "https://example.test/baseline-empty-tools",
            },
          },
        ],
      },
      mappings: [
        ...evidence.mappings,
        {
          capabilityId: "baseline-empty-tools",
          tools: [],
          state: "verified",
        },
      ],
      editor: {
        records: [
          {
            capabilityId: "editor-empty-tools",
            disposition: "ui_capability",
            mcpTools: [],
            state: "verified",
            dogfood: { observableResult: "An inspector property changes." },
          },
        ],
      },
      headless: evidence.headless,
      runtime: {
        records: [
          {
            capabilityId: "runtime-empty-tools",
            disposition: "ui_capability",
            tools: [],
            state: "represented_unverified",
            reason: "A claimed runtime mapping has no tool.",
          },
        ],
      },
      registry: evidence.registry,
    });

    for (const id of [
      "baseline:baseline-empty-tools",
      "editor:editor-empty-tools",
      "runtime:runtime-empty-tools",
    ]) {
      expect(
        artifacts.records.find((record) => record.id === id)?.state,
        `${id} must be broken because an empty tool list has no direct MCP exposure`,
      ).toBe("broken");
    }
  });

  it("requires_every_tool_in_multi_tool_baseline_editor_and_runtime_mappings_to_be_directly_exposed", () => {
    const artifacts = buildParityArtifacts({
      baseline: {
        godotVersion: "4.4",
        capabilities: [
          {
            id: "baseline-multi-tool",
            editorSurface: "Scene dock",
            userAction: "Save a scene and its resources",
            source: {
              version: "4.4",
              url: "https://example.test/baseline-multi-tool",
            },
          },
        ],
      },
      mappings: [
        {
          capabilityId: "baseline-multi-tool",
          tools: ["shared_direct_tool", "baseline_dispatch_missing_tool"],
          state: "verified",
        },
      ],
      editor: {
        records: [
          {
            capabilityId: "editor-multi-tool",
            disposition: "ui_capability",
            mcpTools: ["shared_direct_tool", "editor_full_missing_tool"],
            state: "represented_unverified",
            dogfood: { observableResult: "The editor scene and resource save." },
          },
        ],
      },
      headless: { records: [] },
      runtime: {
        records: [
          {
            capabilityId: "runtime-multi-tool",
            disposition: "ui_capability",
            tools: ["shared_direct_tool", "runtime_dispatch_missing_tool"],
            state: "verified",
            reason: "Both runtime operations are claimed to be represented.",
          },
        ],
      },
      registry: {
        full: {
          tools: [
            "shared_direct_tool",
            "baseline_dispatch_missing_tool",
            "runtime_dispatch_missing_tool",
          ],
        },
        discovery: { tools: ["shared_direct_tool"] },
        dispatch: {
          tools: ["shared_direct_tool", "editor_full_missing_tool"],
        },
        findings: [],
        mcpOnlyExtras: [],
      },
    });

    for (const id of [
      "baseline:baseline-multi-tool",
      "editor:editor-multi-tool",
      "runtime:runtime-multi-tool",
    ]) {
      expect(
        artifacts.records.find((record) => record.id === id)?.state,
        `${id} must be broken when its first tool is directly exposed but a required second tool is absent from full or dispatch`,
      ).toBe("broken");
    }
    expect(
      artifacts.summary.states,
      "multi-tool exposure failures must not inflate either parity numerator",
    ).toEqual({
      verified: 0,
      represented_unverified: 0,
      broken: 3,
      gap: 0,
    });
    expect(artifacts.summary.verifiedParityPercent).toBe(0);
    expect(artifacts.summary.representedParityPercent).toBe(0);
  });

  it("preserves_source_derived_provenance_for_mapped_baseline_and_broken_headless_gaps", () => {
    const artifacts = buildParityArtifacts({
      baseline: {
        ...baseline,
        capabilities: [
          ...baseline.capabilities,
          {
            id: "baseline-broken-provenance",
            editorSurface: "Filesystem dock",
            userAction: "Move a resource",
            source: {
              version: "4.4",
              url: "https://example.test/baseline-broken-provenance",
            },
          },
        ],
      },
      mappings: [
        ...evidence.mappings,
        {
          capabilityId: "baseline-broken-provenance",
          tools: ["move_resource"],
          state: "broken",
        },
      ],
      editor: evidence.editor,
      headless: {
        records: [
          {
            tool: "headless_broken_provenance",
            disposition: "ui_capability",
            capability: "headless provenance surface",
            route: "direct_operation",
            state: "broken",
            reason:
              "The direct operation returns a bridge-not-implemented error.",
          },
        ],
      },
      runtime: evidence.runtime,
      registry: evidence.registry,
    });

    expect(
      artifacts.gaps.find(
        (gap) => gap.id === "baseline:baseline-broken-provenance",
      ),
      "a mapped baseline failure must retain its baseline fields and mapped tools",
    ).toEqual({
      id: "baseline:baseline-broken-provenance",
      state: "broken",
      uiSurface: "Filesystem dock",
      executionPath: "baseline",
      userOutcome: "Move a resource",
      sourceReference: "https://example.test/baseline-broken-provenance",
      relatedMcpTools: ["move_resource"],
      evidenceReason: "Baseline mapping is broken.",
    });
    expect(
      artifacts.gaps.find(
        (gap) => gap.id === "headless:headless_broken_provenance",
      ),
      "a broken headless record must retain the evidence record's tool, surface, route, and reason",
    ).toEqual({
      id: "headless:headless_broken_provenance",
      state: "broken",
      uiSurface: "headless provenance surface",
      executionPath: "direct_operation",
      userOutcome:
        "Use headless_broken_provenance through a headless Godot operation.",
      sourceReference: "audit/headless-evidence.json#records/0",
      relatedMcpTools: ["headless_broken_provenance"],
      evidenceReason:
        "The direct operation returns a bridge-not-implemented error.",
    });
  });

  it("keeps_mcp_only_records_out_of_the_ui_denominator_and_lists_each_as_an_extra", () => {
    const artifacts = buildParityArtifacts({
      baseline,
      mappings: evidence.mappings,
      editor: {
        records: [
          ...evidence.editor.records,
          {
            disposition: "mcp_only",
            mcpTools: ["editor_transport_extra"],
          },
        ],
      },
      headless: {
        records: [
          ...evidence.headless.records,
          {
            disposition: "mcp_only",
            tool: "headless_template_extra",
          },
        ],
      },
      runtime: {
        records: [
          ...evidence.runtime.records,
          {
            disposition: "mcp_only",
            tools: ["runtime_transport_extra"],
          },
        ],
      },
      registry: {
        ...evidence.registry,
        mcpOnlyExtras: ["registry_extra"],
      },
    });

    expect(artifacts.summary.denominator).toBe(5);
    expect(artifacts.summary.mcpOnlyExtras).toEqual([
      "editor_transport_extra",
      "headless_template_extra",
      "registry_extra",
      "runtime_transport_extra",
    ]);
  });

  it("enforces_coverage_from_the_production_artifact_composition_even_when_a_runtime_classifier_would_call_the_new_tool_an_extra", async () => {
    await expect(
      createParityArtifacts({
        createAuditReport: async () => ({
          registry: {
            full: { observed: true, tools: ["write_unmapped_tool"] },
            discovery: { observed: true, tools: [] },
            dispatch: { observed: true, tools: ["write_unmapped_tool"] },
          },
          findings: [],
          summary: { extras: ["write_unmapped_tool"] },
        }),
      }),
    ).rejects.toThrow(/undispositioned MCP tools: write_unmapped_tool/);
  });

  it("refreshes_all_committed_artifacts_and_ignores_readme_only_counts_through_the_real_write_entrypoint", async () => {
    const artifactPaths = [
      "audit/parity-summary.json",
      "audit/parity-gaps.json",
      "audit/parity-report.md",
    ];
    const expected = await createParityArtifacts();
    const expectedContents = new Map([
      [
        "audit/parity-summary.json",
        `${JSON.stringify(expected.summary, null, 2)}\n`,
      ],
      ["audit/parity-gaps.json", formatGapDataset(expected.gaps)],
      ["audit/parity-report.md", renderParityReport(expected)],
    ]);
    const readmePath = join(root, "README.md");
    const originalReadme = readFileSync(readmePath, "utf8");

    try {
      for (const relativePath of artifactPaths)
        writeFileSync(join(root, relativePath), "stale parity artifact\n");
      writeFileSync(
        readmePath,
        `${originalReadme}\nThis README-only note claims 99,999 tools.\n`,
      );

      execFileSync(
        "npm",
        ["run", "--silent", "audit:parity-report", "--", "--write"],
        { cwd: root, encoding: "utf8", maxBuffer: 20 * 1024 * 1024 },
      );

      for (const relativePath of artifactPaths)
        expect(
          readFileSync(join(root, relativePath), "utf8"),
          `${relativePath} must be regenerated from production evidence rather than left stale or changed by a README count`,
        ).toBe(expectedContents.get(relativePath));
    } finally {
      writeFileSync(readmePath, originalReadme);
    }
  }, 30000);
});
