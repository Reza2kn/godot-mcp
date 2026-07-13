# Security policy

## Supported version

Security fixes are applied to the latest release. Report vulnerabilities
privately through GitHub Security Advisories rather than a public issue.

## Filesystem boundary

Set `GODOT_MCP_ALLOWED_ROOTS` to a platform-delimited list of directories the
server may access. Absolute filesystem arguments outside those roots are
rejected, including paths that resolve through existing symlinks.

Set `GODOT_MCP_CONFIRM_DESTRUCTIVE=true` to require
`confirmDestructive: true` for tools whose names begin with `delete_`,
`remove_`, `clear_`, `erase_`, or `free_`.

The runtime and editor bridges bind only to `127.0.0.1`. Do not expose their
ports through public tunnels or untrusted container networking.

## Operational recommendations

- Commit or checkpoint projects before broad AI-driven edits.
- Use `godot_call` with `dryRun` before a sequence and `rollbackOnError` for
  filesystem-only sequences sharing one project path.
- Use `GODOT_MCP_MAX_RESPONSE_BYTES` to cap large text responses.
- Keep Godot, Node.js, and this package updated.
