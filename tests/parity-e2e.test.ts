import { describe, expect, it } from "vitest";
import { createParityArtifacts } from "../scripts/parity-report.js";

describe("production parity report", () => {
  it("audits_running_production_entrypoint", async () => {
    const artifacts = await createParityArtifacts();

    expect(artifacts.registry.full.observed).toBe(true);
    expect(artifacts.registry.discovery.observed).toBe(true);
    expect(artifacts.summary.registry.full.toolCount).toBe(
      artifacts.registry.full.tools.length,
    );
    expect(artifacts.summary.registry.discovery.toolCount).toBe(
      artifacts.registry.discovery.tools.length,
    );
    expect(artifacts.summary.registry.dispatch.toolCount).toBe(
      artifacts.registry.dispatch.tools.length,
    );
  }, 15000);
});
