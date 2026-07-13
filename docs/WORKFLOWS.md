# Verified workflows

## Safe project construction

1. Preview a `godot_call` sequence with `dryRun: true`.
2. Execute `create_project`, `create_scene`, `add_node`, `create_script`,
   `attach_script`, and `set_main_scene`.
3. Use `rollbackOnError: true` when all filesystem steps share one project.
4. Run `get_project_health_report` and `get_scene_dependency_graph`.

## Runtime control

1. Call `run_project` and wait for `game_get_scene_tree` to succeed.
2. Inspect before mutating with `game_get_property`.
3. Mutate with `game_set_property` or a specialized runtime tool.
4. Check `game_get_errors` and `game_get_logs`.
5. Always call `stop_project`.

## Editor control

1. Call `install_editor_plugin`.
2. Enable **Godot MCP Editor** in Godot project settings.
3. Launch the editor and call `connect_to_godot_editor`.
4. Use editor tools, then disconnect cleanly.

Run `npm run verify:godot` for the automated combined workflow.
