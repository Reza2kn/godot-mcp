import { existsSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const SOURCE = "src/index.ts";
const BRIDGE = "src/scripts/mcp_interaction_server.gd";
const EVIDENCE = "audit/runtime-evidence.json";
const PORT = 9090;
const STATES = ["verified", "represented_unverified", "broken", "gap"];
const CAPABILITIES = [
  "runtime-remote-inspection",
  "runtime-live-node-mutation",
  "runtime-input-control",
  "runtime-debugging",
  "runtime-performance-monitoring",
  "runtime-audio-control",
  "runtime-physics-control",
  "runtime-scene-execution-control",
  "runtime-animation-control",
  "runtime-rendering-visual-control",
  "runtime-network-system-control",
  "runtime-game-control",
];

type Verification = {
  invocation: "production_mcp" | "mocked_bridge";
  fixture: "running_port_9090" | "test_double";
  readback: { stateTarget: string; observedValue: string };
};

type RuntimeRecord = {
  disposition: "ui_capability" | "mcp_only";
  capabilityId?: string;
  tools: string[];
  commands: string[];
  state?: string;
  reason: string;
  verification?: Verification;
};

type RuntimeEvidence = {
  generatedFrom: string;
  runtimePort: number;
  records: RuntimeRecord[];
  findings: Array<{
    kind:
      | "client_command_missing_bridge_handler"
      | "bridge_handler_missing_typescript_client";
    command: string;
  }>;
  summary: {
    denominator: number;
    numerator: number;
    states: Record<string, number>;
  };
};

function readEvidence(): RuntimeEvidence {
  if (!existsSync(EVIDENCE))
    return {
      generatedFrom: "missing runtime evidence",
      runtimePort: PORT,
      records: [],
      findings: [],
      summary: {
        denominator: 0,
        numerator: 0,
        states: Object.fromEntries(STATES.map((state) => [state, 0])),
      },
    };
  return JSON.parse(readFileSync(EVIDENCE, "utf8"));
}

function handlerBodies(source: string): Map<string, string> {
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

function productionRuntimeTools(): Map<string, string> {
  const source = readFileSync(SOURCE, "utf8");
  const bodies = handlerBodies(source);
  const commandByHandler = new Map<string, string>();
  for (const [handler, body] of bodies) {
    const commands = [...body.matchAll(/this\.gameCommand\('([^']+)'/g)].map(
      (match) => match[1],
    );
    if (commands.length === 1) commandByHandler.set(handler, commands[0]);
  }

  const tools = new Map<string, string>();
  for (const match of source.matchAll(
    /case '([^']+)':\s+return await this\.(handle[A-Za-z0-9]+)\(args\);/g,
  )) {
    const command = commandByHandler.get(match[2]);
    if (command) tools.set(match[1], command);
  }
  return tools;
}

function registeredTools(): Set<string> {
  return new Set(
    [...readFileSync(SOURCE, "utf8").matchAll(/name:\s*'([^']+)'/g)].map(
      (match) => match[1],
    ),
  );
}

function bridgeHandlers(): Map<string, string> {
  const source = readFileSync(BRIDGE, "utf8");
  const start = source.indexOf("match command:");
  const end = source.indexOf("\nfunc ", start);
  const body = source.slice(start, end === -1 ? source.length : end);
  return new Map(
    [
      ...body.matchAll(
        /^\s*"([^"]+)":\s*\n\s*(?:await )?(_cmd_[A-Za-z0-9_]+)\(/gm,
      ),
    ].map((match) => [match[1], match[2]]),
  );
}

function bridgeFindings(
  runtime: Map<string, string>,
  handlers: Map<string, string>,
) {
  const commands = new Set(runtime.values());
  return [
    ...[...commands]
      .filter((command) => !handlers.has(command))
      .map((command) => ({
        kind: "client_command_missing_bridge_handler" as const,
        command,
      })),
    ...[...handlers.keys()]
      .filter((command) => !commands.has(command))
      .map((command) => ({
        kind: "bridge_handler_missing_typescript_client" as const,
        command,
      })),
  ].sort((left, right) =>
    `${left.kind}:${left.command}`.localeCompare(
      `${right.kind}:${right.command}`,
    ),
  );
}

function hasProductionReadback(verification: Verification | undefined) {
  return (
    verification?.invocation === "production_mcp" &&
    verification.fixture === "running_port_9090" &&
    verification.readback.stateTarget.trim().length > 0 &&
    verification.readback.observedValue.trim().length > 0
  );
}

function effectiveState(record: RuntimeRecord, handlers: Map<string, string>) {
  if (record.disposition === "mcp_only") return "mcp_only";
  if (record.commands.some((command) => !handlers.has(command)))
    return "broken";
  if (
    record.state === "verified" &&
    !hasProductionReadback(record.verification)
  )
    return "represented_unverified";
  return record.state;
}

function runtimeSummary(
  evidence: RuntimeEvidence,
  handlers: Map<string, string>,
) {
  const states = Object.fromEntries(STATES.map((state) => [state, 0]));
  const capabilities = evidence.records.filter(
    (record) => record.disposition === "ui_capability",
  );
  for (const record of capabilities) {
    const state = effectiveState(record, handlers);
    if (!STATES.includes(state))
      throw new Error(
        `${record.capabilityId} has invalid runtime state ${state}`,
      );
    states[state] += 1;
  }
  return {
    denominator: capabilities.length,
    numerator: states.verified + states.represented_unverified,
    states,
  };
}

describe("runtime-path parity evidence", () => {
  it("covers_runtime_registry", () => {
    const evidence = readEvidence();
    const runtime = productionRuntimeTools();
    const registrations = registeredTools();
    const records = evidence.records;
    const classifiedTools = records.flatMap((record) => record.tools);

    expect(evidence.runtimePort).toBe(PORT);
    expect(evidence.generatedFrom).toContain("production MCP");
    expect(new Set(classifiedTools).size).toBe(classifiedTools.length);
    expect([...new Set(classifiedTools)].sort()).toEqual(
      [...runtime.keys()].sort(),
    );
    for (const record of records) {
      expect(record.tools.length).toBe(record.commands.length);
      expect(
        record.reason,
        `${record.capabilityId ?? "MCP-only"} needs evidence rationale`,
      ).toMatch(/\S.{15,}/);
      if (record.disposition === "ui_capability") {
        expect(CAPABILITIES).toContain(record.capabilityId);
        expect(STATES).toContain(record.state);
      } else {
        expect(record.capabilityId).toBeUndefined();
      }
      for (const [index, tool] of record.tools.entries()) {
        expect(
          registrations.has(tool),
          `${tool} must be registered by the production MCP entry point`,
        ).toBe(true);
        expect(
          runtime.get(tool),
          `${tool} must use the declared port-9090 command`,
        ).toBe(record.commands[index]);
      }
    }
    const uiCapabilities = records.filter(
      (record) => record.disposition === "ui_capability",
    );
    const helpers = records.filter(
      (record) => record.disposition === "mcp_only",
    );
    expect(
      helpers.length,
      "runtime-only helpers must be explicit exclusions",
    ).toBeGreaterThan(0);
    expect(
      new Set(uiCapabilities.map((record) => record.capabilityId)).size,
      "each runtime UI record must name one canonical capability",
    ).toBe(uiCapabilities.length);
    expect(
      uiCapabilities.map((record) => record.capabilityId).sort(),
      "the runtime slice must cover inspection, mutation, input, debugging, performance, audio, physics, and scene execution controls",
    ).toEqual([...CAPABILITIES].sort());
    expect(
      evidence.summary.denominator,
      "MCP-only evaluation and wait helpers must not increase the runtime UI coverage denominator",
    ).not.toBe(
      uiCapabilities.length + helpers.flatMap((record) => record.tools).length,
    );
    expect(evidence.summary.denominator).toBe(uiCapabilities.length);
  });

  it("reconciles_runtime_bridge", () => {
    const evidence = readEvidence();
    const runtime = productionRuntimeTools();
    const handlers = bridgeHandlers();
    const findings = bridgeFindings(runtime, handlers);

    expect(
      [...handlers.values()].every((handler) =>
        readFileSync(BRIDGE, "utf8").includes(`func ${handler}(`),
      ),
    ).toBe(true);
    expect(evidence.findings).toEqual(findings);
    expect(
      findings.some(
        (finding) => finding.kind === "client_command_missing_bridge_handler",
      ),
    ).toBe(true);
    expect(
      findings.some(
        (finding) =>
          finding.kind === "bridge_handler_missing_typescript_client",
      ),
    ).toBe(true);
    for (const record of evidence.records.filter(
      (candidate) => candidate.disposition === "ui_capability",
    ))
      if (record.commands.some((command) => !handlers.has(command)))
        expect(
          effectiveState(record, handlers),
          `${record.capabilityId} contains an unmatched client command`,
        ).toBe("broken");
  });

  it("requires_runtime_readback", () => {
    const evidence = readEvidence();
    const handlers = bridgeHandlers();
    for (const record of evidence.records)
      if (record.disposition === "ui_capability")
        expect(
          effectiveState(record, handlers),
          `${record.capabilityId} cannot be verified without a production MCP invocation and running-fixture read-back`,
        ).toBe(record.state);

    const candidate = evidence.records.find(
      (record) =>
        record.disposition === "ui_capability" &&
        record.commands.every((command) => handlers.has(command)),
    );
    if (!candidate)
      throw new Error("fixture needs a bridge-backed runtime capability");
    expect(
      effectiveState(
        {
          ...candidate,
          state: "verified",
          verification: {
            invocation: "mocked_bridge",
            fixture: "running_port_9090",
            readback: {
              stateTarget: "/root/Player",
              observedValue: "visible=false",
            },
          },
        },
        handlers,
      ),
      "a mocked bridge response must not promote a runtime capability to verified",
    ).toBe("represented_unverified");
  });

  it("reconciles_runtime_totals", () => {
    const evidence = readEvidence();
    const handlers = bridgeHandlers();
    const first = runtimeSummary(evidence, handlers);
    const second = runtimeSummary(evidence, handlers);

    expect(second).toEqual(first);
    expect(
      Object.values(first.states).reduce((total, count) => total + count, 0),
    ).toBe(first.denominator);
    expect(evidence.summary).toEqual(first);
  });
});
