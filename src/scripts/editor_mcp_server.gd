@tool
extends EditorPlugin

## MCP Editor Plugin — real-time Godot editor control via TCP
## Connects to the MCP TypeScript server on port 9091.
## Shows an Agent Control dock with live operation log + interrupt button.

var PORT := int(OS.get_environment("GODOT_MCP_EDITOR_PORT")) if not OS.get_environment("GODOT_MCP_EDITOR_PORT").is_empty() else 9091
const MAX_LOG_LINES := 50

var _server := TCPServer.new()
var _client: StreamPeerTCP = null
var _recv_buf := ""
var _interrupted := false
var _interrupt_message := ""
var _dock: Control = null
var _log_label: RichTextLabel = null
var _status_label: Label = null
var _interrupt_btn: Button = null
var _msg_edit: LineEdit = null
var _op_count := 0


func _enter_tree() -> void:
	_dock = _build_dock()
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)
	var err = _server.listen(PORT, "127.0.0.1")
	if err != OK:
		_log_entry("❌ Failed to bind port %d (err %d)" % [PORT, err])
	else:
		_log_entry("✅ Listening on 127.0.0.1:%d" % PORT)
		_set_status("Waiting for MCP…", Color.YELLOW)


func _exit_tree() -> void:
	_server.stop()
	if _client:
		_client.disconnect_from_host()
		_client = null
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null


func _process(_delta: float) -> void:
	# Accept new connections
	if _server.is_connection_available():
		if _client:
			_client.disconnect_from_host()
		_client = _server.take_connection()
		_set_status("🟢 MCP connected", Color.GREEN)
		_log_entry("MCP client connected")

	if _client == null:
		return

	if _client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_set_status("Waiting for MCP…", Color.YELLOW)
		_log_entry("MCP client disconnected")
		_client = null
		return

	# Read available data
	var available := _client.get_available_bytes()
	if available > 0:
		_recv_buf += _client.get_utf8_string(available)

	# Process complete newline-delimited JSON messages
	while "\n" in _recv_buf:
		var idx := _recv_buf.find("\n")
		var line := _recv_buf.left(idx).strip_edges()
		_recv_buf = _recv_buf.substr(idx + 1)
		if line.length() > 0:
			_dispatch(line)


func _dispatch(raw: String) -> void:
	var parsed = JSON.parse_string(raw)
	if parsed == null or not parsed is Dictionary:
		_send({"error": "Invalid JSON"})
		return

	# DAgger interrupt check — fires BEFORE processing the command
	if _interrupted:
		var msg := _interrupt_message if _interrupt_message.strip_edges() != "" else "User interrupted the agent."
		_interrupted = false
		_interrupt_message = ""
		_interrupt_btn.text = "⏸ Interrupt Agent"
		_interrupt_btn.modulate = Color.WHITE
		_send({"interrupted": true, "message": msg})
		_log_entry("⏸ Interrupt sent to MCP: " + msg)
		return

	var command: String = parsed.get("command", "")
	var params: Dictionary = parsed.get("params", {})
	_op_count += 1
	_log_entry("#%d → %s" % [_op_count, command])

	match command:
		"ping":
			_send({"pong": true, "editor_mode": true})

		"get_scene_info":
			_cmd_get_scene_info(params)
		"get_selected_node":
			_cmd_get_selected_node(params)
		"select_node":
			_cmd_select_node(params)
		"add_node":
			_cmd_add_node(params)
		"delete_node":
			_cmd_delete_node(params)
		"duplicate_node":
			_cmd_duplicate_node(params)
		"move_node":
			_cmd_move_node(params)
		"set_node_property":
			_cmd_set_node_property(params)
		"get_node_property":
			_cmd_get_node_property(params)
		"open_scene":
			_cmd_open_scene(params)
		"save_scene":
			_cmd_save_scene(params)
		"create_scene":
			_cmd_create_scene(params)
		"undo":
			_cmd_undo(params)
		"redo":
			_cmd_redo(params)
		"get_filesystem_files":
			_cmd_get_filesystem_files(params)
		"focus_node":
			_cmd_focus_node(params)
		"get_scene_tree":
			_cmd_get_scene_tree(params)
		"run_scene":
			_cmd_run_scene(params)
		"stop_scene":
			_cmd_stop_scene(params)
		"create_script":
			_cmd_create_script(params)
		"attach_script":
			_cmd_attach_script(params)
		"get_editor_settings":
			_cmd_get_editor_settings(params)
		"set_editor_setting":
			_cmd_set_editor_setting(params)
		"reimport_file":
			_cmd_reimport_file(params)
		"get_project_settings":
			_cmd_get_project_settings(params)
		"set_project_setting":
			_cmd_set_project_setting_editor(params)
		_:
			_send({"error": "Unknown editor command: " + command})
			_log_entry("  ⚠️ unknown command")


# ──────────────────────────────────────────────────────────────
#  Command implementations
# ──────────────────────────────────────────────────────────────

func _cmd_get_scene_info(_params: Dictionary) -> void:
	var root = EditorInterface.get_edited_scene_root()
	if root == null:
		_send({"success": false, "error": "No scene open"})
		return
	_send({
		"success": true,
		"root_name": root.name,
		"root_class": root.get_class(),
		"scene_path": root.scene_file_path,
		"child_count": root.get_child_count()
	})


func _cmd_get_selected_node(_params: Dictionary) -> void:
	var sel := EditorInterface.get_selection().get_selected_nodes()
	if sel.is_empty():
		_send({"success": true, "selected": []})
		return
	var result: Array = []
	for node in sel:
		result.append({"name": node.name, "class": node.get_class(), "path": str(node.get_path())})
	_send({"success": true, "selected": result})


func _cmd_select_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var root = EditorInterface.get_edited_scene_root()
	if root == null:
		_send({"error": "No scene open"})
		return
	var node = root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send({"error": "Node not found: " + node_path})
		return
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(node)
	EditorInterface.edit_node(node)
	_send({"success": true, "selected": node_path})


func _cmd_add_node(params: Dictionary) -> void:
	var node_type: String = params.get("node_type", "Node")
	var node_name: String = params.get("node_name", node_type)
	var parent_path: String = params.get("parent_path", "")
	var root = EditorInterface.get_edited_scene_root()
	if root == null:
		_send({"error": "No scene open"})
		return
	var parent: Node
	if parent_path == "" or parent_path == ".":
		parent = root
	else:
		parent = root.get_node_or_null(NodePath(parent_path))
		if parent == null:
			_send({"error": "Parent not found: " + parent_path})
			return
	if not ClassDB.class_exists(node_type):
		_send({"error": "Unknown node class: " + node_type})
		return
	var new_node: Node = ClassDB.instantiate(node_type)
	new_node.name = node_name
	var undo = get_undo_redo()
	undo.create_action("Add " + node_type)
	undo.add_do_method(parent, "add_child", new_node, true)
	undo.add_do_method(new_node, "set_owner", root)
	undo.add_do_reference(new_node)
	undo.add_undo_method(parent, "remove_child", new_node)
	undo.commit_action()
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(new_node)
	_send({"success": true, "node_name": new_node.name, "node_type": node_type, "parent": str(parent.get_path())})


func _cmd_delete_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var root = EditorInterface.get_edited_scene_root()
	if root == null:
		_send({"error": "No scene open"})
		return
	var node = root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send({"error": "Node not found: " + node_path})
		return
	var parent = node.get_parent()
	var undo = get_undo_redo()
	undo.create_action("Delete " + node.name)
	undo.add_do_method(parent, "remove_child", node)
	undo.add_undo_method(parent, "add_child", node, true)
	undo.add_undo_method(node, "set_owner", root)
	undo.add_undo_reference(node)
	undo.commit_action()
	_send({"success": true, "deleted": node_path})


func _cmd_duplicate_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var new_name: String = params.get("new_name", "")
	var root = EditorInterface.get_edited_scene_root()
	if root == null:
		_send({"error": "No scene open"})
		return
	var node = root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send({"error": "Node not found: " + node_path})
		return
	var dup = node.duplicate()
	if new_name != "":
		dup.name = new_name
	var parent = node.get_parent()
	var undo = get_undo_redo()
	undo.create_action("Duplicate " + node.name)
	undo.add_do_method(parent, "add_child", dup, true)
	undo.add_do_method(dup, "set_owner", root)
	undo.add_do_reference(dup)
	undo.add_undo_method(parent, "remove_child", dup)
	undo.commit_action()
	_send({"success": true, "new_path": str(dup.get_path()), "new_name": dup.name})


func _cmd_move_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var new_parent_path: String = params.get("new_parent_path", "")
	var root = EditorInterface.get_edited_scene_root()
	if root == null:
		_send({"error": "No scene open"})
		return
	var node = root.get_node_or_null(NodePath(node_path))
	var new_parent = root.get_node_or_null(NodePath(new_parent_path))
	if node == null:
		_send({"error": "Node not found: " + node_path})
		return
	if new_parent == null:
		_send({"error": "New parent not found: " + new_parent_path})
		return
	var old_parent = node.get_parent()
	var undo = get_undo_redo()
	undo.create_action("Move " + node.name)
	undo.add_do_method(node, "reparent", new_parent, true)
	undo.add_undo_method(node, "reparent", old_parent, true)
	undo.commit_action()
	_send({"success": true, "new_path": str(node.get_path())})


func _cmd_set_node_property(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property: String = params.get("property", "")
	var value = params.get("value", null)
	var root = EditorInterface.get_edited_scene_root()
	if root == null:
		_send({"error": "No scene open"})
		return
	var node = root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send({"error": "Node not found: " + node_path})
		return
	var old_value = node.get(property)
	var undo = get_undo_redo()
	undo.create_action("Set %s.%s" % [node.name, property])
	undo.add_do_property(node, property, value)
	undo.add_undo_property(node, property, old_value)
	undo.commit_action()
	_send({"success": true, "property": property, "value": value, "old_value": old_value})


func _cmd_get_node_property(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property: String = params.get("property", "")
	var root = EditorInterface.get_edited_scene_root()
	if root == null:
		_send({"error": "No scene open"})
		return
	var node = root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send({"error": "Node not found: " + node_path})
		return
	_send({"success": true, "property": property, "value": node.get(property)})


func _cmd_open_scene(params: Dictionary) -> void:
	var scene_path: String = params.get("scene_path", "")
	EditorInterface.open_scene_from_path(scene_path)
	_send({"success": true, "scene_path": scene_path})


func _cmd_save_scene(_params: Dictionary) -> void:
	EditorInterface.save_scene()
	_send({"success": true})


func _cmd_create_scene(params: Dictionary) -> void:
	var root_type: String = params.get("root_type", "Node2D")
	var scene_path: String = params.get("scene_path", "")
	var root_name: String = params.get("root_name", root_type)
	if not ClassDB.class_exists(root_type):
		_send({"error": "Unknown class: " + root_type})
		return
	var new_root: Node = ClassDB.instantiate(root_type)
	new_root.name = root_name
	var scene = PackedScene.new()
	scene.pack(new_root)
	var err = ResourceSaver.save(scene, scene_path)
	if err != OK:
		_send({"error": "Failed to save scene: " + scene_path})
		new_root.queue_free()
		return
	new_root.queue_free()
	EditorInterface.open_scene_from_path(scene_path)
	_send({"success": true, "scene_path": scene_path, "root_type": root_type})


func _cmd_undo(_params: Dictionary) -> void:
	get_undo_redo().undo()
	_send({"success": true, "action": "undo"})


func _cmd_redo(_params: Dictionary) -> void:
	get_undo_redo().redo()
	_send({"success": true, "action": "redo"})


func _cmd_get_filesystem_files(params: Dictionary) -> void:
	var path: String = params.get("path", "res://")
	var ext_filter: String = params.get("extension", "")
	var fs = EditorInterface.get_resource_filesystem()
	var dir = fs.get_filesystem_path(path)
	if dir == null:
		_send({"error": "Path not found in editor filesystem: " + path})
		return
	var files: Array = []
	_collect_fs_files(dir, ext_filter, files)
	_send({"success": true, "path": path, "count": files.size(), "files": files})


func _collect_fs_files(dir: EditorFileSystemDirectory, ext_filter: String, out: Array) -> void:
	for i in range(dir.get_file_count()):
		var fname = dir.get_file(i)
		if ext_filter == "" or fname.ends_with(ext_filter):
			out.append(dir.get_file_path(i))
	for i in range(dir.get_subdir_count()):
		_collect_fs_files(dir.get_subdir(i), ext_filter, out)


func _cmd_focus_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var root = EditorInterface.get_edited_scene_root()
	if root == null:
		_send({"error": "No scene open"})
		return
	var node = root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send({"error": "Node not found: " + node_path})
		return
	EditorInterface.edit_node(node)
	_send({"success": true, "focused": node_path})


func _cmd_get_scene_tree(_params: Dictionary) -> void:
	var root = EditorInterface.get_edited_scene_root()
	if root == null:
		_send({"success": false, "error": "No scene open"})
		return
	_send({"success": true, "tree": _build_tree(root)})


func _build_tree(node: Node) -> Dictionary:
	var d: Dictionary = {
		"name": node.name,
		"class": node.get_class(),
		"path": str(node.get_path()),
		"script": str(node.get_script()) if node.get_script() != null else null,
		"children": []
	}
	for child in node.get_children():
		d["children"].append(_build_tree(child))
	return d


func _cmd_run_scene(_params: Dictionary) -> void:
	EditorInterface.play_current_scene()
	_send({"success": true, "action": "play_current_scene"})


func _cmd_stop_scene(_params: Dictionary) -> void:
	EditorInterface.stop_playing_scene()
	_send({"success": true, "action": "stop"})


func _cmd_create_script(params: Dictionary) -> void:
	var script_path: String = params.get("script_path", "")
	var extends_class: String = params.get("extends_class", "Node")
	var content: String = params.get("content", "extends %s\n\n\nfunc _ready() -> void:\n\tpass\n" % extends_class)
	var file = FileAccess.open(script_path, FileAccess.WRITE)
	if file == null:
		_send({"error": "Cannot write script: " + script_path})
		return
	file.store_string(content)
	file.close()
	EditorInterface.get_resource_filesystem().scan()
	_send({"success": true, "script_path": script_path})


func _cmd_attach_script(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var script_path: String = params.get("script_path", "")
	var root = EditorInterface.get_edited_scene_root()
	if root == null:
		_send({"error": "No scene open"})
		return
	var node = root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send({"error": "Node not found: " + node_path})
		return
	var script = load(script_path) as GDScript
	if script == null:
		_send({"error": "Cannot load script: " + script_path})
		return
	var old_script = node.get_script()
	var undo = get_undo_redo()
	undo.create_action("Attach Script to " + node.name)
	undo.add_do_property(node, "script", script)
	undo.add_undo_property(node, "script", old_script)
	undo.commit_action()
	_send({"success": true, "node": node_path, "script": script_path})


func _cmd_get_editor_settings(_params: Dictionary) -> void:
	var es = EditorInterface.get_editor_settings()
	# Return a selection of useful settings
	var settings: Dictionary = {}
	for key in ["text_editor/behavior/indent/type", "text_editor/appearance/guidelines/line_length_guideline_soft_column", "docks/filesystem/thumbnail_size"]:
		if es.has_setting(key):
			settings[key] = es.get_setting(key)
	_send({"success": true, "settings": settings})


func _cmd_set_editor_setting(params: Dictionary) -> void:
	var key: String = params.get("key", "")
	var value = params.get("value", null)
	var es = EditorInterface.get_editor_settings()
	if not es.has_setting(key):
		_send({"error": "Unknown editor setting: " + key})
		return
	es.set_setting(key, value)
	_send({"success": true, "key": key, "value": value})


func _cmd_reimport_file(params: Dictionary) -> void:
	var file_path: String = params.get("file_path", "")
	EditorInterface.get_resource_filesystem().reimport_files([file_path])
	_send({"success": true, "file_path": file_path})


func _cmd_get_project_settings(_params: Dictionary) -> void:
	# Return commonly useful project settings
	var keys = [
		"application/run/main_scene",
		"application/config/name",
		"display/window/size/viewport_width",
		"display/window/size/viewport_height",
		"physics/2d/default_gravity",
		"physics/3d/default_gravity",
		"rendering/renderer/rendering_method"
	]
	var result: Dictionary = {}
	for key in keys:
		if ProjectSettings.has_setting(key):
			result[key] = ProjectSettings.get_setting(key)
	_send({"success": true, "settings": result})


func _cmd_set_project_setting_editor(params: Dictionary) -> void:
	var key: String = params.get("key", "")
	var value = params.get("value", null)
	if not ProjectSettings.has_setting(key):
		_send({"error": "Unknown project setting: " + key})
		return
	ProjectSettings.set_setting(key, value)
	ProjectSettings.save()
	_send({"success": true, "key": key, "value": value})


# ──────────────────────────────────────────────────────────────
#  Dock UI
# ──────────────────────────────────────────────────────────────

func _build_dock() -> Control:
	var root_vb := VBoxContainer.new()
	root_vb.name = "GodotMCPEditor"
	root_vb.custom_minimum_size = Vector2(220, 0)

	var title := Label.new()
	title.text = "🤖 MCP Agent Control"
	title.add_theme_font_size_override("font_size", 14)
	root_vb.add_child(title)

	var sep1 := HSeparator.new()
	root_vb.add_child(sep1)

	_status_label = Label.new()
	_status_label.text = "Starting…"
	_status_label.add_theme_color_override("font_color", Color.YELLOW)
	root_vb.add_child(_status_label)

	var sep2 := HSeparator.new()
	root_vb.add_child(sep2)

	var log_title := Label.new()
	log_title.text = "Operations:"
	root_vb.add_child(log_title)

	_log_label = RichTextLabel.new()
	_log_label.custom_minimum_size = Vector2(0, 280)
	_log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_label.scroll_active = true
	_log_label.bbcode_enabled = true
	root_vb.add_child(_log_label)

	var sep3 := HSeparator.new()
	root_vb.add_child(sep3)

	var msg_label := Label.new()
	msg_label.text = "Correction message:"
	root_vb.add_child(msg_label)

	_msg_edit = LineEdit.new()
	_msg_edit.placeholder_text = "Why interrupting? (optional)"
	root_vb.add_child(_msg_edit)

	_interrupt_btn = Button.new()
	_interrupt_btn.text = "⏸ Interrupt Agent"
	_interrupt_btn.pressed.connect(_on_interrupt_pressed)
	root_vb.add_child(_interrupt_btn)

	var clear_btn := Button.new()
	clear_btn.text = "Clear Log"
	clear_btn.pressed.connect(func(): _log_label.clear())
	root_vb.add_child(clear_btn)

	return root_vb


func _on_interrupt_pressed() -> void:
	_interrupted = true
	_interrupt_message = _msg_edit.text if _msg_edit != null else ""
	_msg_edit.text = ""
	_interrupt_btn.text = "⏸ Interrupt ARMED"
	_interrupt_btn.modulate = Color.RED
	_log_entry("[color=red]⏸ INTERRUPT ARMED — will fire on next command[/color]")


func _set_status(text: String, color: Color) -> void:
	if _status_label:
		_status_label.text = text
		_status_label.add_theme_color_override("font_color", color)


func _log_entry(text: String) -> void:
	if _log_label == null:
		return
	_log_label.append_text(text + "\n")
	# Trim old lines to keep dock fast
	var line_count = _log_label.get_line_count()
	if line_count > MAX_LOG_LINES:
		_log_label.clear()
		_log_label.append_text("[dim]…[/dim]\n")


# ──────────────────────────────────────────────────────────────
#  Helpers
# ──────────────────────────────────────────────────────────────

func _send(data: Dictionary) -> void:
	if _client == null or _client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	_client.put_utf8_string(JSON.stringify(data) + "\n")
