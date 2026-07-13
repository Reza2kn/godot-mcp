# Release procedure

1. Confirm `CHANGELOG.md`, `package.json`, `server.json`, and the README agree on
   the version, package name, and 1,969-tool count.
2. Run:

   ```bash
   npm ci
   npm test
   npm run docs:generate
   npm run verify:godot
   npm run verify:feedback
   npm run benchmark
   npm pack --dry-run
   ```

3. Confirm the GitHub Node, Godot compatibility, and seven-point visual
   feedback jobs pass.
4. Install the produced tarball into a blank directory and verify the installed
   server reports 1,969 unique schemas.
5. Authenticate with `npm adduser`. In supported GitHub Actions OIDC release
   jobs, publish with `npm publish --provenance --access public`. From a local
   authenticated terminal, npm does not support automatic provenance; use
   `npm publish --access public --provenance=false`.
6. Create a signed `v1.0.0` Git tag and GitHub release using the changelog.
7. Install from npm in a fresh Conductor/Codex session and rerun
   the semantic and seven-point feedback workflows against the published
   server.

Publishing is intentionally not automated from an unauthenticated workstation.
