import { execFileSync } from "node:child_process";
import { describe, expect, it } from "vitest";
import { summarizeParity } from "../scripts/audit-parity.js";

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

describe("versioned UI parity baseline", () => {
  it("validates_versioned_ui_capabilities", () => {
    const audit = runAudit();
    const baseline = audit.uiBaseline;

    expect(baseline.godotVersion).toMatch(/^4\.4(?:\.\d+)?$/);
    expect(baseline.capabilities.length).toBeGreaterThan(0);
    expect(
      new Set(baseline.capabilities.map((capability: any) => capability.id))
        .size,
    ).toBe(baseline.capabilities.length);
    for (const capability of baseline.capabilities) {
      expect(capability.id).toMatch(/^[a-z0-9]+(?:-[a-z0-9]+)*$/);
      expect(capability.editorSurface.length).toBeGreaterThan(0);
      expect(capability.userAction.length).toBeGreaterThan(0);
      expect(capability.source.version).toBe(baseline.godotVersion);
      expect(capability.source.url).toContain(`/en/${baseline.godotVersion}/`);
      expect(() => new URL(capability.source.url)).not.toThrow();
    }
  }, 15000);

  it("separates_ui_parity_from_mcp_extras", () => {
    const audit = runAudit();
    const summary = audit.summary;

    expect(Object.keys(summary.states).sort()).toEqual([
      "broken",
      "gap",
      "represented_unverified",
      "verified",
    ]);
    expect(summary.denominator).toBe(audit.uiBaseline.capabilities.length);
    expect(summary.numerator).toBeGreaterThanOrEqual(0);
    expect(summary.extras).toContain("write_platformer_player_script");
    expect(summary.extras).not.toContain("create_project");
  });

  it("keeps_a_template_only_tool_outside_the_ui_parity_measure", () => {
    const input = {
      capabilities: [{ id: "project-manager-create-project" }],
      mappings: [
        {
          capabilityId: "project-manager-create-project",
          tools: ["create_project"],
          state: "verified",
        },
      ],
      dispatchTools: ["create_project"],
    };
    const withoutTemplate = summarizeParity({
      ...input,
      fullTools: ["create_project"],
    });
    const withTemplate = summarizeParity({
      ...input,
      fullTools: ["create_project", "write_example_template_script"],
    });

    expect(withTemplate.denominator).toBe(withoutTemplate.denominator);
    expect(withTemplate.numerator).toBe(withoutTemplate.numerator);
    expect(withTemplate.extras).toHaveLength(withoutTemplate.extras.length + 1);
    expect(withTemplate.extras).toContain("write_example_template_script");
  });

  it("marks_an_advertised_but_undispatchable_mapping_broken", () => {
    const summary = summarizeParity({
      capabilities: [{ id: "scene-dock-create-node" }],
      mappings: [
        {
          capabilityId: "scene-dock-create-node",
          tools: ["advertised_only"],
          state: "verified",
        },
      ],
      fullTools: ["advertised_only"],
      dispatchTools: [],
    });

    expect(
      summary.states.broken,
      "an advertised tool without dispatch cannot count as parity",
    ).toBe(1);
    expect(summary.numerator).toBe(0);
  });

  it("requires_every_represented_mapping_to_be_both_full_advertised_and_dispatchable", () => {
    const summary = summarizeParity({
      capabilities: [
        { id: "verified-capability" },
        { id: "represented-unverified-capability" },
        { id: "full-only-verified-capability" },
        { id: "full-only-unverified-capability" },
        { id: "dispatch-only-verified-capability" },
        { id: "dispatch-only-unverified-capability" },
        { id: "empty-verified-capability" },
        { id: "empty-unverified-capability" },
        { id: "gap-capability" },
      ],
      mappings: [
        {
          capabilityId: "verified-capability",
          tools: ["verified_tool"],
          state: "verified",
        },
        {
          capabilityId: "represented-unverified-capability",
          tools: ["unverified_tool"],
          state: "represented_unverified",
        },
        {
          capabilityId: "full-only-verified-capability",
          tools: ["full_only_verified_tool"],
          state: "verified",
        },
        {
          capabilityId: "full-only-unverified-capability",
          tools: ["full_only_unverified_tool"],
          state: "represented_unverified",
        },
        {
          capabilityId: "dispatch-only-verified-capability",
          tools: ["dispatch_only_verified_tool"],
          state: "verified",
        },
        {
          capabilityId: "dispatch-only-unverified-capability",
          tools: ["dispatch_only_unverified_tool"],
          state: "represented_unverified",
        },
        {
          capabilityId: "empty-verified-capability",
          tools: [],
          state: "verified",
        },
        {
          capabilityId: "empty-unverified-capability",
          tools: [],
          state: "represented_unverified",
        },
      ],
      fullTools: [
        "verified_tool",
        "unverified_tool",
        "full_only_verified_tool",
        "full_only_unverified_tool",
      ],
      dispatchTools: [
        "verified_tool",
        "unverified_tool",
        "dispatch_only_verified_tool",
        "dispatch_only_unverified_tool",
      ],
    });

    expect(
      summary.states.verified,
      "verified mappings must remain separately counted",
    ).toBe(1);
    expect(
      summary.states.represented_unverified,
      "represented-but-unverified mappings must not be upgraded to verified",
    ).toBe(1);
    expect(
      summary.states.broken,
      "a represented mapping with no tool, no full advertisement, or no dispatchability must be broken",
    ).toBe(6);
    expect(
      summary.states.gap,
      "a baseline capability with no mapping row must remain an absent gap",
    ).toBe(1);
    expect(
      summary.numerator,
      "only mappings present in both production inventories count as represented",
    ).toBe(2);
    expect(summary.denominator).toBe(9);
  });
});
