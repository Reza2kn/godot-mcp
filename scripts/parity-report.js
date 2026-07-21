#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createAuditReport } from "./audit-parity.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const STATES = ["verified", "represented_unverified", "broken", "gap"];
const GAP_STATES = new Set(["broken", "gap"]);

function readJson(relativePath) {
  return JSON.parse(readFileSync(join(root, relativePath), "utf8"));
}

function emptyStates() {
  return Object.fromEntries(STATES.map((state) => [state, 0]));
}

function addState(groups, key, state) {
  if (!groups[key]) groups[key] = emptyStates();
  groups[key][state] += 1;
}

function percentage(numerator, denominator) {
  return denominator === 0
    ? 0
    : Number(((numerator / denominator) * 100).toFixed(2));
}

function sourcePointer(file, index) {
  return `${file}#records/${index}`;
}

function mappingState(mapping, registry) {
  if (!mapping) return "gap";
  if (!STATES.includes(mapping.state))
    throw new Error(
      `Unknown mapping state for ${mapping.capabilityId}: ${mapping.state}`,
    );
  const represented = ["verified", "represented_unverified"].includes(
    mapping.state,
  );
  const direct =
    mapping.tools.length > 0 &&
    mapping.tools.every((tool) => registry.full.tools.includes(tool)) &&
    mapping.tools.every((tool) => registry.dispatch.tools.includes(tool));
  return represented && !direct ? "broken" : mapping.state;
}

function normalizeEvidence({
  baseline,
  mappings,
  editor,
  headless,
  runtime,
  registry,
}) {
  const records = [];
  const mappingByCapability = new Map(
    mappings.map((mapping) => [mapping.capabilityId, mapping]),
  );

  for (const capability of baseline.capabilities) {
    const mapping = mappingByCapability.get(capability.id);
    const state = mappingState(mapping, registry);
    records.push({
      id: `baseline:${capability.id}`,
      state,
      uiSurface: capability.editorSurface,
      executionPath: "baseline",
      userOutcome: capability.userAction,
      sourceReference: capability.source.url,
      relatedMcpTools: mapping?.tools ?? [],
      evidenceReason: mapping
        ? `Baseline mapping is ${state}.`
        : "No MCP disposition is recorded for this canonical UI capability.",
    });
  }

  for (const [index, record] of editor.records.entries()) {
    if (record.disposition !== "ui_capability") continue;
    const state = mappingState(
      {
        capabilityId: record.capabilityId,
        tools: record.mcpTools,
        state: record.state,
      },
      registry,
    );
    records.push({
      id: `editor:${record.capabilityId}`,
      state,
      uiSurface: "Godot editor plugin",
      executionPath: "editor_plugin",
      userOutcome:
        record.dogfood?.observableResult ??
        `Use the ${record.capabilityId} editor capability.`,
      sourceReference: sourcePointer("audit/editor-evidence.json", index),
      relatedMcpTools: record.mcpTools,
      evidenceReason: `Editor evidence records this capability as ${state}; ${record.representation ?? "no representation evidence"}.`,
    });
  }

  for (const [index, record] of headless.records.entries()) {
    if (record.disposition !== "ui_capability") continue;
    const state = mappingState(
      {
        capabilityId: record.tool,
        tools: [record.tool],
        state: record.state,
      },
      registry,
    );
    records.push({
      id: `headless:${record.tool}`,
      state,
      uiSurface: record.capability,
      executionPath: record.route,
      userOutcome: `Use ${record.tool} through a headless Godot operation.`,
      sourceReference: sourcePointer("audit/headless-evidence.json", index),
      relatedMcpTools: [record.tool],
      evidenceReason: record.reason,
    });
  }

  for (const [index, record] of runtime.records.entries()) {
    if (record.disposition !== "ui_capability") continue;
    const state = mappingState(
      {
        capabilityId: record.capabilityId,
        tools: record.tools,
        state: record.state,
      },
      registry,
    );
    records.push({
      id: `runtime:${record.capabilityId}`,
      state,
      uiSurface: "Running game",
      executionPath: "runtime",
      userOutcome: `Use the ${record.capabilityId} running-game capability.`,
      sourceReference: sourcePointer("audit/runtime-evidence.json", index),
      relatedMcpTools: record.tools,
      evidenceReason: record.reason,
    });
  }

  for (const record of records)
    if (!STATES.includes(record.state))
      throw new Error(
        `Unknown evidence state for ${record.id}: ${record.state}`,
      );
  return records.sort((left, right) => left.id.localeCompare(right.id));
}

function mcpOnlyExtras({ editor, headless, runtime, registry }) {
  return [
    ...new Set([
      ...registry.mcpOnlyExtras,
      ...editor.records
        .filter((record) => record.disposition === "mcp_only")
        .flatMap((record) => record.mcpTools),
      ...headless.records
        .filter((record) => record.disposition === "mcp_only")
        .map((record) => record.tool),
      ...runtime.records
        .filter((record) => record.disposition === "mcp_only")
        .flatMap((record) => record.tools),
    ]),
  ].sort();
}

export function assertAuditCoverage({
  canonicalCapabilities,
  mappingCapabilities,
  productionTools,
  dispositionTools,
}) {
  const unmappedCapabilities = canonicalCapabilities.filter(
    (capability) => !mappingCapabilities.includes(capability),
  );
  const undispositionedTools = productionTools.filter(
    (tool) => !dispositionTools.includes(tool),
  );
  if (unmappedCapabilities.length || undispositionedTools.length)
    throw new Error(
      `Parity audit drift: unmapped UI capabilities: ${unmappedCapabilities.join(", ") || "none"}; undispositioned MCP tools: ${undispositionedTools.join(", ") || "none"}.`,
    );
}

function dispositionTools({
  mappings,
  editor,
  headless,
  runtime,
  mcpOnlyExtras,
}) {
  return [
    ...new Set([
      ...mappings.flatMap((mapping) => mapping.tools),
      ...editor.records.flatMap((record) => record.mcpTools ?? []),
      ...headless.records.map((record) => record.tool),
      ...runtime.records.flatMap((record) => record.tools ?? []),
      ...mcpOnlyExtras,
    ]),
  ];
}

export function buildParityArtifacts(input) {
  const records = normalizeEvidence(input);
  const states = emptyStates();
  const bySurface = {};
  const byPath = {};
  for (const record of records) {
    states[record.state] += 1;
    addState(bySurface, record.uiSurface, record.state);
    addState(byPath, record.executionPath, record.state);
  }
  const denominator = records.length;
  const verifiedParityPercent = percentage(states.verified, denominator);
  const representedParityPercent = percentage(
    states.verified + states.represented_unverified,
    denominator,
  );
  const registryFindings = input.registry.findings.filter(
    (finding) => finding.kind !== "readme_only_claim",
  );
  const summary = {
    godotBaseline: input.baseline.godotVersion,
    denominator,
    states,
    verifiedParityPercent,
    representedParityPercent,
    bySurface,
    byPath,
    registry: {
      full: { toolCount: input.registry.full.tools.length },
      discovery: { toolCount: input.registry.discovery.tools.length },
      dispatch: { toolCount: input.registry.dispatch.tools.length },
      inconsistencies: registryFindings,
    },
    mcpOnlyExtras: mcpOnlyExtras(input),
    evidenceLimitations: records
      .filter((record) => record.state !== "verified")
      .map((record) => ({
        id: record.id,
        evidenceReason: record.evidenceReason,
      })),
  };
  return {
    summary,
    gaps: records.filter((record) => GAP_STATES.has(record.state)),
    records,
    registry: input.registry,
  };
}

function markdownTable(groups) {
  return Object.entries(groups)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(
      ([name, states]) =>
        `| ${name} | ${states.verified} | ${states.represented_unverified} | ${states.broken} | ${states.gap} |`,
    )
    .join("\n");
}

function countBy(values, keyOf) {
  return [
    ...values
      .reduce((counts, value) => {
        const key = keyOf(value);
        counts.set(key, (counts.get(key) ?? 0) + 1);
        return counts;
      }, new Map())
      .entries(),
  ]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, count]) => `- ${key}: ${count}`)
    .join("\n");
}

function gapLines(gaps) {
  return gaps
    .map(
      (gap) =>
        `- ${gap.id} (${gap.state}; ${gap.uiSurface}; ${gap.executionPath}) — ${gap.userOutcome}. Tools: ${gap.relatedMcpTools.join(", ") || "none"}. Source: ${gap.sourceReference}. Evidence: ${gap.evidenceReason}`,
    )
    .join("\n");
}

function formatGapDataset(gaps) {
  return `${JSON.stringify(gaps, null, 2).replace(
    /"relatedMcpTools": \[\n((?:\s+"[^"]+",?\n)+)\s+\]/g,
    (_match, values) =>
      `"relatedMcpTools": [${values.match(/"[^"]+"/g).join(", ")}]`,
  )}\n`;
}

export function renderParityReport({ summary, gaps }) {
  return [
    "# MCP versus UI parity report",
    "",
    `Godot baseline: ${summary.godotBaseline}`,
    `Canonical UI capability denominator: ${summary.denominator}`,
    `Strict verified parity: ${summary.verifiedParityPercent}% (${summary.states.verified}/${summary.denominator})`,
    `Represented parity: ${summary.representedParityPercent}% (${summary.states.verified + summary.states.represented_unverified}/${summary.denominator})`,
    "",
    "## Totals by UI surface",
    "",
    "| Surface | Verified | Represented-unverified | Broken | Gap |",
    "| --- | ---: | ---: | ---: | ---: |",
    markdownTable(summary.bySurface),
    "",
    "## Totals by execution path",
    "",
    "| Path | Verified | Represented-unverified | Broken | Gap |",
    "| --- | ---: | ---: | ---: | ---: |",
    markdownTable(summary.byPath),
    "",
    "## Registry inconsistencies",
    "",
    `Observed production inconsistencies: ${summary.registry.inconsistencies.length}. README-only claims are deliberately excluded because they cannot affect this audit's production metrics.`,
    "",
    countBy(summary.registry.inconsistencies, (finding) => finding.kind),
    "",
    "## MCP-only extras",
    "",
    summary.mcpOnlyExtras.join(", ") || "None.",
    "",
    "## Evidence limitations",
    "",
    `Non-verified records: ${summary.evidenceLimitations.length}.`,
    "",
    countBy(
      summary.evidenceLimitations,
      (limitation) => limitation.evidenceReason,
    ),
    "",
    "## Broken or missing capabilities",
    "",
    `Total: ${gaps.length}.`,
    "",
    gapLines(gaps),
    "",
    "Gap records are intentionally unprioritized; use audit/parity-gaps.json for the decision-ready dataset.",
    "",
  ].join("\n");
}

export async function createParityArtifacts({
  createAuditReport: getAuditReport = createAuditReport,
} = {}) {
  const [audit, baseline, mappingsFile, editor, headless, runtime, mcpOnly] =
    await Promise.all([
      getAuditReport(),
      readJson("audit/ui-baseline.json"),
      readJson("audit/mappings.json"),
      readJson("audit/editor-evidence.json"),
      readJson("audit/headless-evidence.json"),
      readJson("audit/runtime-evidence.json"),
      readJson("audit/mcp-only-evidence.json"),
    ]);
  const mappings = mappingsFile.mappings;
  const registry = {
    ...audit.registry,
    findings: audit.findings,
    mcpOnlyExtras: mcpOnly.tools,
  };
  assertAuditCoverage({
    canonicalCapabilities: baseline.capabilities.map(
      (capability) => capability.id,
    ),
    mappingCapabilities: mappings.map((mapping) => mapping.capabilityId),
    productionTools: registry.full.tools,
    dispositionTools: dispositionTools({
      mappings,
      editor,
      headless,
      runtime,
      mcpOnlyExtras: registry.mcpOnlyExtras,
    }),
  });
  return buildParityArtifacts({
    baseline,
    mappings,
    editor,
    headless,
    runtime,
    registry,
  });
}

function writeArtifacts(artifacts) {
  writeFileSync(
    join(root, "audit/parity-summary.json"),
    `${JSON.stringify(artifacts.summary, null, 2)}\n`,
  );
  writeFileSync(
    join(root, "audit/parity-gaps.json"),
    formatGapDataset(artifacts.gaps),
  );
  writeFileSync(
    join(root, "audit/parity-report.md"),
    renderParityReport(artifacts),
  );
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  createParityArtifacts()
    .then((artifacts) => {
      if (process.argv.includes("--write")) writeArtifacts(artifacts);
      process.stdout.write(renderParityReport(artifacts));
    })
    .catch((error) => {
      console.error(
        `audit:parity-report failed: ${error instanceof Error ? error.message : String(error)}`,
      );
      process.exitCode = 1;
    });
}
