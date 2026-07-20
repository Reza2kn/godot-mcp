import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
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

function independentlyReadBuiltDispatchCases(source: string): string[] {
  const dispatchStart = source.indexOf("async dispatchTool(");
  const switchStart = source.indexOf("switch (name)", dispatchStart);
  const switchBodyStart = source.indexOf("{", switchStart);
  let depth = 0;
  let switchBodyEnd = -1;

  for (let index = switchBodyStart; index < source.length; index += 1) {
    if (source[index] === "{") depth += 1;
    if (source[index] === "}") depth -= 1;
    if (depth === 0) {
      switchBodyEnd = index;
      break;
    }
  }

  if (
    dispatchStart === -1 ||
    switchStart === -1 ||
    switchBodyStart === -1 ||
    switchBodyEnd === -1
  )
    throw new Error(
      "Unable to independently locate the built dispatch switch.",
    );

  return [
    ...source.slice(switchBodyStart, switchBodyEnd).matchAll(/case '([^']+)'/g),
  ].map((match) => match[1]);
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
    const builtEntryPoint = readFileSync("build/index.js", "utf8");
    const expectedDispatch =
      independentlyReadBuiltDispatchCases(builtEntryPoint);
    expect(
      audit.report.registry.dispatch.tools,
      "the audit dispatch inventory must contain every case in the built dispatch switch, including cases after create_project",
    ).toEqual(expectedDispatch);
    expect(
      audit.report.registry.full.tools.length,
      "the report must contain observed tools, not a README total",
    ).toBeGreaterThan(100);
  }, 15000);

  it("rejects_claim_based_coverage", () => {
    const audit = runAudit();
    const injectedClaim = {
      source: "README.md",
      total: 99999,
      text: "README says 99,999 tools",
    };
    const findings = analyzeRegistry({
      full: ["observed_tool", "advertised_only"],
      discovery: ["observed_tool"],
      dispatch: ["observed_tool"],
      readmeClaims: [injectedClaim],
    });

    expect(audit.status).toBe(0);
    expect(audit.report.registry.claimedTotals).toContainEqual(
      expect.objectContaining({ source: "README.md", total: 1969 }),
    );
    expect(audit.report.findings).toContainEqual(
      expect.objectContaining({
        kind: "readme_only_claim",
        source: "README.md",
        claimedTotal: 1969,
      }),
    );
    expect(audit.report.registry.full.tools.length).toBeGreaterThan(100);
    expect(findings).toContainEqual(
      expect.objectContaining({
        kind: "advertised_without_dispatch",
        tool: "advertised_only",
      }),
    );
    expect(findings).toContainEqual({
      kind: "readme_only_claim",
      source: "README.md",
      claimedTotal: 99999,
      text: "README says 99,999 tools",
    });
    expect(audit.report.registry.full.tools.join(",")).not.toContain("99,999");
  });

  it("emits_duplicate_findings_for_every_registry_inventory", () => {
    const inventory = readDispatchInventory(`async dispatchTool(name) {
      switch (name) {
        case 'duplicate_tool': return null;
        case 'duplicate_tool': return null;
      }
    }
    async nextMethod() {}`);

    expect(inventory).toEqual(["duplicate_tool", "duplicate_tool"]);
    expect(
      analyzeRegistry({
        full: ["duplicate_full", "duplicate_full"],
        discovery: ["duplicate_discovery", "duplicate_discovery"],
        dispatch: inventory,
      }),
    ).toEqual(
      expect.arrayContaining([
        {
          kind: "duplicate_advertised_name",
          tool: "duplicate_full",
          mode: "full",
        },
        {
          kind: "duplicate_advertised_name",
          tool: "duplicate_discovery",
          mode: "discovery",
        },
        { kind: "duplicate_dispatch_name", tool: "duplicate_tool" },
      ]),
    );
  });

  it("emits_findings_for_every_advertised_and_dispatch_membership_mismatch", () => {
    const findings = analyzeRegistry({
      full: ["full_only", "shared"],
      discovery: ["discovery_only", "shared"],
      dispatch: ["shared", "dispatch_only"],
    });

    expect(findings).toEqual(
      expect.arrayContaining([
        {
          kind: "advertised_without_dispatch",
          tool: "full_only",
          mode: "full",
        },
        {
          kind: "advertised_without_dispatch",
          tool: "discovery_only",
          mode: "discovery",
        },
        { kind: "dispatch_not_advertised", tool: "dispatch_only" },
      ]),
    );
  });
});
