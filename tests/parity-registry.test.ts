import { execFileSync } from "node:child_process";
import { describe, expect, it } from "vitest";
import {
  analyzeRegistry,
  readDispatchInventory,
} from "../scripts/audit-parity.js";

interface AuditRun {
  status: number;
  report: Record<string, any>;
  error?: string;
}

function runAudit(): AuditRun {
  try {
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
    return { status: 0, report: JSON.parse(stdout) };
  } catch (error: any) {
    return {
      status: error.status ?? 1,
      report: error.stdout ? JSON.parse(error.stdout) : {},
      error: error.stderr || error.message,
    };
  }
}

describe("production parity registry", () => {
  it("reads_production_mcp_registry", () => {
    const audit = runAudit();

    expect(
      audit.status,
      `audit:parity must successfully inspect the built MCP entry point: ${audit.error ?? "no stderr"}`,
    ).toBe(0);
    expect(
      audit.report.registry.full.observed,
      "full mode must be observed from the built MCP process",
    ).toBe(true);
    expect(audit.report.registry.full.tools).toContain(
      "add_animatable_body_2d_to_scene",
    );
    expect(
      audit.report.registry.discovery.observed,
      "discovery mode must be observed from the built MCP process",
    ).toBe(true);
    expect(audit.report.registry.discovery.tools).toContain("godot_call");
    expect(
      audit.report.registry.dispatch.observed,
      "dispatch inventory must be observed from the built entry point",
    ).toBe(true);
    expect(audit.report.registry.dispatch.tools).toContain("create_project");
    expect(
      audit.report.registry.full.tools.length,
      "the report must contain observed tools, not a README total",
    ).toBeGreaterThan(100);
  });

  it("rejects_claim_based_coverage", () => {
    const audit = runAudit();
    const injectedClaim = "README says 99,999 tools";
    const findings = analyzeRegistry({
      full: ["observed_tool", "advertised_only"],
      discovery: ["observed_tool"],
      dispatch: ["observed_tool"],
      readme: injectedClaim,
    });

    expect(audit.status).toBe(0);
    expect(audit.report.registry.claimedTotals).toEqual([]);
    expect(audit.report.registry.full.tools.length).toBeGreaterThan(100);
    expect(findings).toContainEqual(
      expect.objectContaining({
        kind: "advertised_without_dispatch",
        tool: "advertised_only",
      }),
    );
    expect(audit.report.registry.full.tools.join(",")).not.toContain("99,999");
  });

  it("preserves_duplicate_dispatch_names_for_findings", () => {
    const inventory = readDispatchInventory(`async dispatchTool(name) {
      switch (name) {
        case 'duplicate_tool': return null;
        case 'duplicate_tool': return null;
      }
    }
    async nextMethod() {}`);

    expect(inventory).toEqual(["duplicate_tool", "duplicate_tool"]);
  });
});
