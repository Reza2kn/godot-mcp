# Architecture

Godot MCP has three execution paths:

1. The TypeScript stdio MCP server owns schemas, validation, project/file
   operations, process lifecycle, discovery, and result shaping.
2. `godot_operations.gd` runs one-shot headless operations for scenes and
   resources that require Godot serialization.
3. `mcp_interaction_server.gd` is temporarily installed as an autoload for live
   game control on the runtime port. The optional editor plugin provides editor
   control on a separate port.

Both TCP listeners bind to localhost. `GODOT_MCP_RUNTIME_PORT` and
`GODOT_MCP_EDITOR_PORT` override their ports. In Conductor, defaults derive from
`CONDUCTOR_PORT + 8` and `CONDUCTOR_PORT + 9`, keeping parallel workspaces apart.

Discovery mode exposes 20 entry points. The complete catalog remains available
through `godot_call`, `search_tools`, and category navigation.
