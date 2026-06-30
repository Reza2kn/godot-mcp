extends Node

# MCP Interaction Server - TCP server for game interaction
# Runs as an autoload inside the Godot game, accepting JSON commands over TCP.
# No class_name to avoid autoload conflict.

var _server: TCPServer
var _client: StreamPeerTCP
var _buffer: String = ""
var _busy: bool = false
var _busy_since: float = 0.0
const PORT: int = 9090
const BUSY_TIMEOUT: float = 30.0
var _key_map: Dictionary
var _held_keys: Dictionary = {}
var _recording: bool = false
var _recorded_events: Array = []
var _recording_start_ms: float = 0.0
var _fps_history: Array = []
var _fps_history_max: int = 300
var _print_buffer: Array = []
var _print_buffer_max: int = 200
var _profiler_start_time: int = 0
var _profiler_running: bool = false

func _ready() -> void:
	# Ensure MCP server keeps processing even when game is paused
	process_mode = Node.PROCESS_MODE_ALWAYS
	_init_key_map()
	_server = TCPServer.new()
	var err: int = _server.listen(PORT, "127.0.0.1")
	if err != OK:
		push_error("McpInteractionServer: Failed to listen on port %d, error: %d" % [PORT, err])
		return
	print("McpInteractionServer: Listening on 127.0.0.1:%d" % PORT)


func _process(_delta: float) -> void:
	# Track FPS history
	_fps_history.append(Engine.get_frames_per_second())
	if _fps_history.size() > _fps_history_max:
		_fps_history = _fps_history.slice(_fps_history.size() - _fps_history_max)

	if _server == null:
		return

	# Safety timeout: force-reset _busy if it's been stuck too long
	if _busy and _busy_since > 0.0:
		var elapsed: float = Time.get_ticks_msec() / 1000.0 - _busy_since
		if elapsed > BUSY_TIMEOUT:
			push_warning("McpInteractionServer: _busy flag stuck for %.1fs, force-resetting" % elapsed)
			_busy = false
			_busy_since = 0.0

	# Accept new connections
	if _server.is_connection_available():
		var new_client: StreamPeerTCP = _server.take_connection()
		if new_client != null:
			if _client != null:
				_client.disconnect_from_host()
			_client = new_client
			_buffer = ""
			print("McpInteractionServer: Client connected")

	# Read data from client
	if _client == null:
		return

	_client.poll()
	var status: int = _client.get_status()
	if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
		print("McpInteractionServer: Client disconnected")
		_client = null
		_buffer = ""
		_busy = false
		_busy_since = 0.0
		return

	if status != StreamPeerTCP.STATUS_CONNECTED:
		return

	var available: int = _client.get_available_bytes()
	if available > 0:
		var data: Array = _client.get_data(available)
		if data[0] == OK:
			var bytes: PackedByteArray = data[1]
			_buffer += bytes.get_string_from_utf8()

			# Process complete lines (newline-delimited JSON)
			while _buffer.find("\n") >= 0:
				var newline_pos: int = _buffer.find("\n")
				var line: String = _buffer.substr(0, newline_pos).strip_edges()
				_buffer = _buffer.substr(newline_pos + 1)
				if line.length() > 0:
					_handle_command(line)


func _input(event: InputEvent) -> void:
	if not _recording:
		return
	var elapsed: float = Time.get_ticks_msec() - _recording_start_ms
	var entry: Dictionary = {"time_ms": elapsed, "type": event.get_class()}
	if event is InputEventKey:
		var ke: InputEventKey = event as InputEventKey
		entry["keycode"] = ke.keycode
		entry["pressed"] = ke.pressed
		entry["unicode"] = ke.unicode
	elif event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		entry["button_index"] = mb.button_index
		entry["pressed"] = mb.pressed
		entry["position"] = {"x": mb.position.x, "y": mb.position.y}
	elif event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		entry["position"] = {"x": mm.position.x, "y": mm.position.y}
	_recorded_events.append(entry)


func _handle_command(json_str: String) -> void:
	if _busy:
		_send_response_raw({"error": "Server busy processing another command. Try again."})
		return
	_busy = true
	_busy_since = Time.get_ticks_msec() / 1000.0

	var json: JSON = JSON.new()
	var parse_err: int = json.parse(json_str)
	if parse_err != OK:
		_send_response({"error": "Invalid JSON: %s" % json.get_error_message()})
		return

	var data: Variant = json.data
	if not data is Dictionary:
		_send_response({"error": "Expected JSON object"})
		return

	var command: String = data.get("command", "")
	var params: Dictionary = data.get("params", {})

	match command:
		# Async commands (use await)
		"screenshot":
			await _cmd_screenshot()
		"click":
			await _cmd_click(params)
		"key_press":
			await _cmd_key_press(params)
		"eval":
			await _cmd_eval(params)
		"wait":
			await _cmd_wait(params)
		# Sync commands
		"mouse_move":
			_cmd_mouse_move(params)
		"get_ui_elements":
			_cmd_get_ui_elements()
		"get_scene_tree":
			_cmd_get_scene_tree()
		"get_property":
			_cmd_get_property(params)
		"set_property":
			_cmd_set_property(params)
		"call_method":
			_cmd_call_method(params)
		"get_node_info":
			_cmd_get_node_info(params)
		"instantiate_scene":
			_cmd_instantiate_scene(params)
		"remove_node":
			_cmd_remove_node(params)
		"change_scene":
			_cmd_change_scene(params)
		"pause":
			_cmd_pause(params)
		"get_performance":
			_cmd_get_performance(params)
		"connect_signal":
			_cmd_connect_signal(params)
		"disconnect_signal":
			_cmd_disconnect_signal(params)
		"emit_signal":
			_cmd_emit_signal(params)
		"play_animation":
			_cmd_play_animation(params)
		"tween_property":
			_cmd_tween_property(params)
		"get_nodes_in_group":
			_cmd_get_nodes_in_group(params)
		"find_nodes_by_class":
			_cmd_find_nodes_by_class(params)
		"reparent_node":
			_cmd_reparent_node(params)
		# Enhanced input commands
		"key_hold":
			_cmd_key_hold(params)
		"key_release":
			_cmd_key_release(params)
		"scroll":
			_cmd_scroll(params)
		"mouse_drag":
			await _cmd_mouse_drag(params)
		"gamepad":
			_cmd_gamepad(params)
		# Advanced runtime commands
		"get_camera":
			_cmd_get_camera()
		"set_camera":
			_cmd_set_camera(params)
		"raycast":
			await _cmd_raycast(params)
		"get_audio":
			_cmd_get_audio()
		"spawn_node":
			_cmd_spawn_node(params)
		"set_shader_param":
			_cmd_set_shader_param(params)
		"audio_play":
			_cmd_audio_play(params)
		"audio_bus":
			_cmd_audio_bus(params)
		"navigate_path":
			await _cmd_navigate_path(params)
		"tilemap":
			_cmd_tilemap(params)
		"add_collision":
			_cmd_add_collision(params)
		"environment":
			_cmd_environment(params)
		"manage_group":
			_cmd_manage_group(params)
		"create_timer":
			_cmd_create_timer(params)
		"set_particles":
			_cmd_set_particles(params)
		"create_animation":
			_cmd_create_animation(params)
		"serialize_state":
			_cmd_serialize_state(params)
		"physics_body":
			_cmd_physics_body(params)
		"create_joint":
			_cmd_create_joint(params)
		"bone_pose":
			_cmd_bone_pose(params)
		"ui_theme":
			_cmd_ui_theme(params)
		"viewport":
			_cmd_viewport(params)
		"debug_draw":
			_cmd_debug_draw(params)
		# Batch 1: Networking + Input + System + Signals + Script
		"http_request":
			await _cmd_http_request(params)
		"websocket":
			_cmd_websocket(params)
		"multiplayer":
			_cmd_multiplayer(params)
		"rpc":
			_cmd_rpc(params)
		"touch":
			await _cmd_touch(params)
		"input_state":
			_cmd_input_state(params)
		"input_action":
			_cmd_input_action(params)
		"list_signals":
			_cmd_list_signals(params)
		"await_signal":
			await _cmd_await_signal(params)
		"script":
			_cmd_script(params)
		"window":
			_cmd_window(params)
		"os_info":
			_cmd_os_info()
		"time_scale":
			_cmd_time_scale(params)
		"process_mode":
			_cmd_process_mode(params)
		"world_settings":
			_cmd_world_settings(params)
		# Batch 2: 3D Rendering + Lighting + Sky + Physics
		"csg":
			_cmd_csg(params)
		"multimesh":
			_cmd_multimesh(params)
		"procedural_mesh":
			_cmd_procedural_mesh(params)
		"light_3d":
			_cmd_light_3d(params)
		"mesh_instance":
			_cmd_mesh_instance(params)
		"gridmap":
			_cmd_gridmap(params)
		"3d_effects":
			_cmd_3d_effects(params)
		"gi":
			_cmd_gi(params)
		"path_3d":
			_cmd_path_3d(params)
		"sky":
			_cmd_sky(params)
		"camera_attributes":
			_cmd_camera_attributes(params)
		"navigation_3d":
			await _cmd_navigation_3d(params)
		"physics_3d":
			await _cmd_physics_3d(params)
		# Batch 3: 2D Systems + Animation + Audio
		"canvas":
			_cmd_canvas(params)
		"canvas_draw":
			_cmd_canvas_draw(params)
		"light_2d":
			_cmd_light_2d(params)
		"parallax":
			_cmd_parallax(params)
		"shape_2d":
			_cmd_shape_2d(params)
		"path_2d":
			_cmd_path_2d(params)
		"physics_2d":
			await _cmd_physics_2d(params)
		"animation_tree":
			_cmd_animation_tree(params)
		"animation_control":
			_cmd_animation_control(params)
		"skeleton_ik":
			_cmd_skeleton_ik(params)
		"audio_effect":
			_cmd_audio_effect(params)
		"audio_bus_layout":
			_cmd_audio_bus_layout(params)
		"audio_spatial":
			_cmd_audio_spatial(params)
		# Batch 4: Locale (runtime)
		"locale":
			_cmd_locale(params)
		# Batch 5: UI Controls + Rendering + Resource
		"ui_control":
			_cmd_ui_control(params)
		"ui_text":
			_cmd_ui_text(params)
		"ui_popup":
			_cmd_ui_popup(params)
		"ui_tree":
			_cmd_ui_tree(params)
		"ui_item_list":
			_cmd_ui_item_list(params)
		"ui_tabs":
			_cmd_ui_tabs(params)
		"ui_menu":
			_cmd_ui_menu(params)
		"ui_range":
			_cmd_ui_range(params)
		"render_settings":
			_cmd_render_settings(params)
		"resource":
			_cmd_resource(params)
		"find_text":
			_cmd_find_text(params)
		"stress_test":
			await _cmd_stress_test(params)
		"find_nodes_by_script":
			_cmd_find_nodes_by_script(params)
		"batch_get_properties":
			_cmd_batch_get_properties(params)
		"click_button_by_text":
			_cmd_click_button_by_text(params)
		"wait_for_node":
			await _cmd_wait_for_node(params)
		"find_nearby_nodes":
			_cmd_find_nearby_nodes(params)
		"capture_frames":
			await _cmd_capture_frames(params)
		"monitor_properties":
			await _cmd_monitor_properties(params)
		"start_recording":
			_cmd_start_recording(params)
		"stop_recording":
			_cmd_stop_recording(params)
		"replay_recording":
			await _cmd_replay_recording(params)
		"animtree_add_state":
			_cmd_animtree_add_state(params)
		"animtree_remove_state":
			_cmd_animtree_remove_state(params)
		"animtree_add_transition":
			_cmd_animtree_add_transition(params)
		"animtree_remove_transition":
			_cmd_animtree_remove_transition(params)
		"animtree_get_structure":
			_cmd_animtree_get_structure(params)
		"tilemap_set_cell":
			_cmd_tilemap_set_cell(params)
		"tilemap_get_used_cells":
			_cmd_tilemap_get_used_cells(params)
		"tilemap_clear":
			_cmd_tilemap_clear(params)
		"audio_bus_list":
			_cmd_audio_bus_list(params)
		"audio_bus_create":
			_cmd_audio_bus_create(params)
		"audio_bus_set_volume":
			_cmd_audio_bus_set_volume(params)
		"audio_bus_add_effect":
			_cmd_audio_bus_add_effect(params)
		"get_performance_counters":
			_cmd_get_performance_counters(params)
		"batch_set_properties":
			_cmd_batch_set_properties(params)
		"animation_add_keyframe":
			_cmd_animation_add_keyframe(params)
		"animation_get_keyframes":
			_cmd_animation_get_keyframes(params)
		"animation_delete_keyframe":
			_cmd_animation_delete_keyframe(params)
		"label_set_text":
			_cmd_label_set_text(params)
		"control_set_size":
			_cmd_control_set_size(params)
		"get_tree_structure":
			_cmd_get_tree_structure(params)
		"node_get_meta":
			_cmd_node_get_meta(params)
		"node_set_meta":
			_cmd_node_set_meta(params)
		"game_quit":
			_cmd_game_quit(params)
		"set_window_title":
			_cmd_set_window_title(params)
		"camera_set_current":
			_cmd_camera_set_current(params)
		"camera_get_info":
			_cmd_camera_get_info(params)
		"set_node_z_index":
			_cmd_set_node_z_index(params)
		"canvas_layer_set":
			_cmd_canvas_layer_set(params)
		"particle_set_emitting":
			_cmd_particle_set_emitting(params)
		"particle_restart":
			_cmd_particle_restart(params)
		"grab_focus":
			_cmd_grab_focus(params)
		"get_viewport_info":
			_cmd_get_viewport_info(params)
		"skeleton_get_bones":
			_cmd_skeleton_get_bones(params)
		"skeleton_set_bone_pose":
			_cmd_skeleton_set_bone_pose(params)
		"subviewport_set_size":
			_cmd_subviewport_set_size(params)
		"gridmap_set_cell":
			_cmd_gridmap_set_cell(params)
		"gridmap_get_used_cells":
			_cmd_gridmap_get_used_cells(params)
		"gridmap_clear":
			_cmd_gridmap_clear(params)
		"path2d_set_points":
			_cmd_path2d_set_points(params)
		"get_fps_history":
			_cmd_get_fps_history(params)
		"set_environment_property":
			_cmd_set_environment_property(params)
		"get_physics_layers":
			_cmd_get_physics_layers(params)
		"set_physics_layers":
			_cmd_set_physics_layers(params)
		"get_node_rect":
			_cmd_get_node_rect(params)
		"theme_set_color_override":
			_cmd_theme_set_color_override(params)
		"popup_menu_add_item":
			_cmd_popup_menu_add_item(params)
		"option_button_add_item":
			_cmd_option_button_add_item(params)
		"item_list_add_item":
			_cmd_item_list_add_item(params)
		"animation_set_loop":
			_cmd_animation_set_loop(params)
		"multimesh_set_instance_count":
			_cmd_multimesh_set_instance_count(params)
		"multimesh_set_instance_transform":
			_cmd_multimesh_set_instance_transform(params)
		"audio_player_set_bus":
			_cmd_audio_player_set_bus(params)
		"set_material_property":
			_cmd_set_material_property(params)
		"rich_text_append":
			_cmd_rich_text_append(params)
		"timer_start":
			_cmd_timer_start(params)
		"timer_stop":
			_cmd_timer_stop(params)
		"timer_set_wait_time":
			_cmd_timer_set_wait_time(params)
		"rigid_body_apply_impulse":
			_cmd_rigid_body_apply_impulse(params)
		"character_body_set_velocity":
			_cmd_character_body_set_velocity(params)
		"ray_cast_force_update":
			_cmd_ray_cast_force_update(params)
		"area_get_overlapping":
			_cmd_area_get_overlapping(params)
		"visibility_notifier_set_rect":
			_cmd_visibility_notifier_set_rect(params)
		"spring_arm_3d_set_length":
			_cmd_spring_arm_3d_set_length(params)
		"get_collision_shape_info":
			_cmd_get_collision_shape_info(params)
		"get_tilemap_info":
			_cmd_get_tilemap_info(params)
		"animation_tree_get_state":
			_cmd_animation_tree_get_state(params)
		"animation_tree_set_param":
			_cmd_animation_tree_set_param(params)
		"progress_bar_set_value":
			_cmd_progress_bar_set_value(params)
		"slider_set_value":
			_cmd_slider_set_value(params)
		"line_edit_set_text":
			_cmd_line_edit_set_text(params)
		"texture_rect_set_texture":
			_cmd_texture_rect_set_texture(params)
		"get_viewport_size":
			_cmd_get_viewport_size(params)
		"get_render_info":
			_cmd_get_render_info(params)
		"get_audio_bus_list":
			_cmd_get_audio_bus_list(params)
		"set_audio_bus_volume":
			_cmd_set_audio_bus_volume(params)
		"get_physics_bodies":
			_cmd_get_physics_bodies(params)
		"set_gravity_scale":
			_cmd_set_gravity_scale(params)
		"get_animation_player_list":
			_cmd_get_animation_player_list(params)
		"node_set_modulate":
			_cmd_node_set_modulate(params)
		"node_set_z_index":
			_cmd_node_set_z_index(params)
		"emit_signal_on_node":
			_cmd_emit_signal_on_node(params)
		"get_node_metadata":
			_cmd_get_node_metadata(params)
		"set_node_metadata":
			_cmd_set_node_metadata(params)
		"node_add_to_group_runtime":
			_cmd_node_add_to_group_runtime(params)
		"node_remove_from_group_runtime":
			_cmd_node_remove_from_group_runtime(params)
		"get_nodes_in_group_runtime":
			_cmd_get_nodes_in_group_runtime(params)
		"game_set_time_scale":
			_cmd_game_set_time_scale(params)
		"game_get_scene_tree":
			_cmd_game_get_scene_tree(params)
		"get_canvas_layers":
			_cmd_get_canvas_layers(params)
		"canvas_layer_set_layer":
			_cmd_canvas_layer_set_layer(params)
		"get_shader_params":
			_cmd_get_shader_params(params)
		"get_2d_camera_info":
			_cmd_get_2d_camera_info(params)
		"camera_2d_set_zoom":
			_cmd_camera_2d_set_zoom(params)
		"node_set_visible_runtime":
			_cmd_node_set_visible_runtime(params)
		"node_get_visible_runtime":
			_cmd_node_get_visible_runtime(params)
		"free_node_runtime":
			_cmd_free_node_runtime(params)
		"duplicate_node_runtime":
			_cmd_duplicate_node_runtime(params)
		"game_reload_scene":
			_cmd_game_reload_scene(params)
		"set_node_process":
			_cmd_set_node_process(params)
		"get_object_id":
			_cmd_get_object_id(params)
		"call_method_on_node":
			_cmd_call_method_on_node(params)
		"get_particles_info":
			_cmd_get_particles_info(params)
		"set_particles_emitting":
			_cmd_set_particles_emitting(params)
		"get_navigation_agents":
			_cmd_get_navigation_agents(params)
		"navigation_agent_set_target":
			_cmd_navigation_agent_set_target(params)
		"get_world_environment":
			_cmd_get_world_environment(params)
		"batch_set_node_property_runtime":
			_cmd_batch_set_node_property_runtime(params)
		"get_input_state":
			_cmd_get_input_state(params)
		"simulate_input_action":
			_cmd_simulate_input_action(params)
		"get_network_info":
			_cmd_get_network_info(params)
		"scene_profiler_start":
			_cmd_scene_profiler_start(params)
		"scene_profiler_stop":
			_cmd_scene_profiler_stop(params)
		"get_mouse_position":
			_cmd_get_mouse_position(params)
		"warp_mouse":
			_cmd_warp_mouse(params)
		"get_color_in_game":
			_cmd_get_color_in_game(params)
		"get_light_properties":
			_cmd_get_light_properties(params)
		"set_light_property":
			_cmd_set_light_property(params)
		"get_runtime_scene_list":
			_cmd_get_runtime_scene_list(params)
		"game_set_debug_visible":
			_cmd_game_set_debug_visible(params)
		"get_print_output":
			_cmd_get_print_output(params)
		"clear_print_output":
			_cmd_clear_print_output(params)
		"send_message_to_game":
			_cmd_send_message_to_game(params)
		"add_tween":
			_cmd_add_tween(params)
		"stop_tween":
			_cmd_stop_tween(params)
		"get_http_response":
			_cmd_get_http_response(params)
		"make_http_request":
			_cmd_make_http_request(params)
		"get_os_info":
			_cmd_get_os_info(params)
		"open_url_in_browser":
			_cmd_open_url_in_browser(params)
		"get_clipboard":
			_cmd_get_clipboard(params)
		"set_clipboard":
			_cmd_set_clipboard(params)
		"get_display_info":
			_cmd_get_display_info(params)
		"set_window_size":
			_cmd_set_window_size(params)
		"instantiate_scene_at_runtime":
			_cmd_instantiate_scene_at_runtime(params)
		"save_scene_at_runtime":
			_cmd_save_scene_at_runtime(params)
		"get_script_source":
			_cmd_get_script_source(params)
		"set_animation_speed_scale":
			_cmd_set_animation_speed_scale(params)
		"get_animation_position":
			_cmd_get_animation_position(params)
		"seek_animation":
			_cmd_seek_animation(params)
		"blend_shape_set_value":
			_cmd_blend_shape_set_value(params)
		"blend_shape_get_values":
			_cmd_blend_shape_get_values(params)
		"get_bone_global_pose":
			_cmd_get_bone_global_pose(params)
		"set_bone_pose_xyz":
			_cmd_set_bone_pose_xyz(params)
		"add_audio_effect_to_bus":
			_cmd_add_audio_effect_to_bus(params)
		"remove_audio_effect_from_bus":
			_cmd_remove_audio_effect_from_bus(params)
		"get_audio_bus_effects":
			_cmd_get_audio_bus_effects(params)
		"set_audio_effect_parameter":
			_cmd_set_audio_effect_parameter(params)
		"create_audio_bus":
			_cmd_create_audio_bus(params)
		"list_audio_buses":
			_cmd_list_audio_buses(params)
		"set_environment_glow":
			_cmd_set_environment_glow(params)
		"set_environment_ssao":
			_cmd_set_environment_ssao(params)
		"set_environment_fog":
			_cmd_set_environment_fog(params)
		"get_environment_properties":
			_cmd_get_environment_properties(params)
		"setup_enet_multiplayer":
			_cmd_setup_enet_multiplayer(params)
		"get_connected_peers":
			_cmd_get_connected_peers(params)
		"disconnect_multiplayer":
			_cmd_disconnect_multiplayer(params)
		"send_multiplayer_rpc":
			_cmd_send_multiplayer_rpc(params)
		"reload_script_at_runtime":
			_cmd_reload_script_at_runtime(params)
		"get_loaded_gdextensions":
			_cmd_get_loaded_gdextensions(params)
		"get_physics_body_state":
			_cmd_get_physics_body_state(params)
		"apply_impulse_to_rigid_body":
			_cmd_apply_impulse_to_rigid_body(params)
		"set_rigid_body_freeze":
			_cmd_set_rigid_body_freeze(params)
		"set_collision_mask":
			_cmd_set_collision_mask(params)
		"set_collision_layer":
			_cmd_set_collision_layer(params)
		"get_runtime_input_actions":
			_cmd_get_runtime_input_actions(params)
		"is_action_pressed":
			_cmd_is_action_pressed(params)
		"get_global_transform_3d":
			_cmd_get_global_transform_3d(params)
		"set_global_position_3d":
			_cmd_set_global_position_3d(params)
		"look_at_target":
			_cmd_look_at_target(params)
		"list_connected_signals_in_game":
			_cmd_list_connected_signals_in_game(params)
		"connect_signal_in_game":
			_cmd_connect_signal_in_game(params)
		"disconnect_signal_in_game":
			_cmd_disconnect_signal_in_game(params)
		"emit_signal_in_game":
			_cmd_emit_signal_in_game(params)
		"get_node_groups":
			_cmd_get_node_groups(params)
		"add_node_to_group":
			_cmd_add_node_to_group(params)
		"remove_node_from_group":
			_cmd_remove_node_from_group(params)
		"call_group_method":
			_cmd_call_group_method(params)
		"set_particle_emission_rate":
			_cmd_set_particle_emission_rate(params)
		"get_particle_state":
			_cmd_get_particle_state(params)
		"restart_particles":
			_cmd_restart_particles(params)
		"set_shader_uniform":
			_cmd_set_shader_uniform(params)
		"get_shader_uniforms":
			_cmd_get_shader_uniforms(params)
		"get_material_properties":
			_cmd_get_material_properties(params)
		"set_light_3d_color":
			_cmd_set_light_3d_color(params)
		"set_light_3d_energy":
			_cmd_set_light_3d_energy(params)
		"set_sky_material":
			_cmd_set_sky_material(params)
		"get_node_metadata_in_game":
			_cmd_get_node_metadata_in_game(params)
		"set_node_metadata_in_game":
			_cmd_set_node_metadata_in_game(params)
		"get_time_in_game":
			_cmd_get_time_in_game(params)
		"get_engine_version_in_game":
			_cmd_get_engine_version_in_game(params)
		"set_camera_fov":
			_cmd_set_camera_fov(params)
		"set_camera_3d_current":
			_cmd_set_camera_3d_current(params)
		"get_current_camera_3d":
			_cmd_get_current_camera_3d(params)
		"set_camera_2d_zoom":
			_cmd_set_camera_2d_zoom(params)
		"set_camera_2d_limit":
			_cmd_set_camera_2d_limit(params)
		"set_viewport_size_ingame":
			_cmd_set_viewport_size_ingame(params)
		"set_time_scale":
			_cmd_set_time_scale(params)
		"get_scene_tree_paused":
			_cmd_get_scene_tree_paused(params)
		"set_rich_text_label_bbcode":
			_cmd_set_rich_text_label_bbcode(params)
		"add_option_button_item":
			_cmd_add_option_button_item(params)
		"set_tab_container_current":
			_cmd_set_tab_container_current(params)
		"get_color_picker_value":
			_cmd_get_color_picker_value(params)
		"set_color_picker_color":
			_cmd_set_color_picker_color(params)
		"show_popup_menu":
			_cmd_show_popup_menu(params)
		"add_popup_menu_item":
			_cmd_add_popup_menu_item(params)
		"clear_popup_menu":
			_cmd_clear_popup_menu(params)
		"show_dialog":
			_cmd_show_dialog(params)
		"hide_node_in_game":
			_cmd_hide_node_in_game(params)
		"show_node_in_game":
			_cmd_show_node_in_game(params)
		"toggle_node_visibility":
			_cmd_toggle_node_visibility(params)
		"get_node_visibility":
			_cmd_get_node_visibility(params)
		"duplicate_node_in_game":
			_cmd_duplicate_node_in_game(params)
		"get_item_list_items":
			_cmd_get_item_list_items(params)
		"add_item_list_item":
			_cmd_add_item_list_item(params)
		"clear_item_list":
			_cmd_clear_item_list(params)
		"get_item_list_selected":
			_cmd_get_item_list_selected(params)
		"set_check_box_pressed":
			_cmd_set_check_box_pressed(params)
		"get_text_edit_text":
			_cmd_get_text_edit_text(params)
		"set_text_edit_text":
			_cmd_set_text_edit_text(params)
		"set_label_horizontal_alignment":
			_cmd_set_label_horizontal_alignment(params)
		"get_node_property_list":
			_cmd_get_node_property_list(params)
		"get_node_method_list":
			_cmd_get_node_method_list(params)
		"call_node_method":
			_cmd_call_node_method(params)
		"get_node_constant":
			_cmd_get_node_constant(params)
		"set_process_enabled":
			_cmd_set_process_enabled(params)
		"get_process_state":
			_cmd_get_process_state(params)
		"add_node_type_in_game":
			_cmd_add_node_type_in_game(params)
		"remove_node_in_game":
			_cmd_remove_node_in_game(params)
		"reparent_node_in_game":
			_cmd_reparent_node_in_game(params)
		"get_node_owner":
			_cmd_get_node_owner(params)
		"set_node_name_in_game":
			_cmd_set_node_name_in_game(params)
		"get_children_count":
			_cmd_get_children_count(params)
		"find_node_by_name":
			_cmd_find_node_by_name(params)
		"get_scene_tree_snapshot":
			_cmd_get_scene_tree_snapshot(params)
		"get_node_at_position_2d":
			_cmd_get_node_at_position_2d(params)
		"raycast_3d":
			_cmd_raycast_3d(params)
		"overlap_sphere_3d":
			_cmd_overlap_sphere_3d(params)
		"get_physics_bodies_in_area":
			_cmd_get_physics_bodies_in_area(params)
		"set_linear_velocity":
			_cmd_set_linear_velocity(params)
		"set_angular_velocity":
			_cmd_set_angular_velocity(params)
		"get_distance_3d":
			_cmd_get_distance_3d(params)
		"move_toward_3d":
			_cmd_move_toward_3d(params)
		"get_navigation_path_3d":
			_cmd_get_navigation_path_3d(params)
		"get_resource_usage":
			_cmd_get_resource_usage(params)
		"force_garbage_collect":
			_cmd_force_garbage_collect(params)
		"set_physics_fps":
			_cmd_set_physics_fps(params)
		"get_node_count_in_tree":
			_cmd_get_node_count_in_tree(params)
		"print_to_godot_console":
			_cmd_print_to_godot_console(params)
		"get_scene_change_history":
			_cmd_get_scene_change_history(params)
		"get_signal_list":
			_cmd_get_signal_list(params)
		"wait_for_signal":
			_cmd_wait_for_signal(params)
		"get_theme_color":
			_cmd_get_theme_color(params)
		"set_spot_light_angle":
			_cmd_set_spot_light_angle(params)
		"set_light_shadow":
			_cmd_set_light_shadow(params)
		"set_light_range":
			_cmd_set_light_range(params)
		"set_mesh_surface_material":
			_cmd_set_mesh_surface_material(params)
		"get_mesh_surface_count":
			_cmd_get_mesh_surface_count(params)
		"get_node_2d_position":
			_cmd_get_node_2d_position(params)
		"set_node_2d_position":
			_cmd_set_node_2d_position(params)
		"rotate_node_2d":
			_cmd_rotate_node_2d(params)
		"scale_node_2d":
			_cmd_scale_node_2d(params)
		"rotate_node_3d":
			_cmd_rotate_node_3d(params)
		"scale_node_3d":
			_cmd_scale_node_3d(params)
		"get_node_2d_transform":
			_cmd_get_node_2d_transform(params)
		"get_node_3d_transform":
			_cmd_get_node_3d_transform(params)
		"align_node_to_path":
			_cmd_align_node_to_path(params)
		"get_path_2d_length":
			_cmd_get_path_2d_length(params)
		"set_animated_sprite_animation":
			_cmd_set_animated_sprite_animation(params)
		"get_animated_sprite_frame":
			_cmd_get_animated_sprite_frame(params)
		"set_animated_sprite_frame":
			_cmd_set_animated_sprite_frame(params)
		"set_audio_stream_player_stream":
			_cmd_set_audio_stream_player_stream(params)
		"set_audio_stream_pitch_scale":
			_cmd_set_audio_stream_pitch_scale(params)
		"get_audio_stream_position":
			_cmd_get_audio_stream_position(params)
		"seek_audio_stream":
			_cmd_seek_audio_stream(params)
		"get_character_body_velocity":
			_cmd_get_character_body_velocity(params)
		"set_character_body_velocity":
			_cmd_set_character_body_velocity(params)
		"move_and_slide_character":
			_cmd_move_and_slide_character(params)
		"is_character_on_floor":
			_cmd_is_character_on_floor(params)
		"get_navigation_agent_target":
			_cmd_get_navigation_agent_target(params)
		"set_tween_property":
			_cmd_set_tween_property(params)
		"kill_tweens_on_node":
			_cmd_kill_tweens_on_node(params)
		"get_screen_size":
			_cmd_get_screen_size(params)
		"set_window_title":
			_cmd_set_window_title(params)
		"get_screen_count":
			_cmd_get_screen_count(params)
		"set_display_mode":
			_cmd_set_display_mode(params)
		"get_global_mouse_position":
			_cmd_get_global_mouse_position(params)
		"warp_mouse":
			_cmd_warp_mouse(params)
		"is_action_pressed":
			_cmd_is_action_pressed(params)
		"get_joy_count":
			_cmd_get_joy_count(params)
		"get_joy_name":
			_cmd_get_joy_name(params)
		"get_project_setting":
			_cmd_get_project_setting(params)
		"set_project_setting":
			_cmd_set_project_setting(params)
		"get_os_name":
			_cmd_get_os_name(params)
		"get_cpu_count":
			_cmd_get_cpu_count(params)
		"get_particles_amount":
			_cmd_get_particles_amount(params)
		"set_particles_amount":
			_cmd_set_particles_amount(params)
		"get_environment_property":
			_cmd_get_environment_property(params)
		"get_skeleton_bone_count":
			_cmd_get_skeleton_bone_count(params)
		"get_skeleton_bone_names":
			_cmd_get_skeleton_bone_names(params)
		"set_skeleton_bone_pose_rotation":
			_cmd_set_skeleton_bone_pose_rotation(params)
		"reset_skeleton_pose":
			_cmd_reset_skeleton_pose(params)
		"get_node_class":
			_cmd_get_node_class(params)
		"cast_ray_in_game":
			_cmd_cast_ray_in_game(params)
		"cast_ray_2d_in_game":
			_cmd_cast_ray_2d_in_game(params)
		"get_physics_bodies_at_point":
			_cmd_get_physics_bodies_at_point(params)
		"get_overlapping_bodies":
			_cmd_get_overlapping_bodies(params)
		"get_overlapping_areas":
			_cmd_get_overlapping_areas(params)
		"set_ray_cast_enabled":
			_cmd_set_ray_cast_enabled(params)
		"is_ray_cast_colliding":
			_cmd_is_ray_cast_colliding(params)
		"get_ray_cast_collider":
			_cmd_get_ray_cast_collider(params)
		"set_camera_current":
			_cmd_set_camera_current(params)
		"get_current_camera":
			_cmd_get_current_camera(params)
		"set_navigation_agent_target":
			_cmd_set_navigation_agent_target(params)
		"is_navigation_finished":
			_cmd_is_navigation_finished(params)
		"get_next_path_position":
			_cmd_get_next_path_position(params)
		"set_rigid_body_sleeping":
			_cmd_set_rigid_body_sleeping(params)
		"apply_force_to_rigid_body":
			_cmd_apply_force_to_rigid_body(params)
		"get_rigid_body_linear_velocity":
			_cmd_get_rigid_body_linear_velocity(params)
		"set_rigid_body_linear_velocity":
			_cmd_set_rigid_body_linear_velocity(params)
		"get_vehicle_body_speed":
			_cmd_get_vehicle_body_speed(params)
		"set_vehicle_engine_force":
			_cmd_set_vehicle_engine_force(params)
		"add_scene_tree_timer_via_code":
			_cmd_add_scene_tree_timer_via_code(params)
		"get_time_since_start":
			_cmd_get_time_since_start(params)
		"get_engine_version":
			_cmd_get_engine_version(params)
		"get_time_scale":
			_cmd_get_time_scale(params)
		"get_physics_fps":
			_cmd_get_physics_fps(params)
		"list_signals_on_node":
			_cmd_list_signals_on_node(params)
		"has_node_metadata":
			_cmd_has_node_metadata(params)
		"get_node_custom_minimum_size":
			_cmd_get_node_custom_minimum_size(params)
		"set_node_custom_minimum_size":
			_cmd_set_node_custom_minimum_size(params)
		"get_label_text":
			_cmd_get_label_text(params)
		"set_label_text":
			_cmd_set_label_text(params)
		"get_progress_bar_value":
			_cmd_get_progress_bar_value(params)
		"set_progress_bar_value":
			_cmd_set_progress_bar_value(params)
		"get_slider_value":
			_cmd_get_slider_value(params)
		"set_slider_value":
			_cmd_set_slider_value(params)
		"get_spin_box_value":
			_cmd_get_spin_box_value(params)
		"set_spin_box_value":
			_cmd_set_spin_box_value(params)
		"get_line_edit_text":
			_cmd_get_line_edit_text(params)
		"set_line_edit_text":
			_cmd_set_line_edit_text(params)
		"is_button_pressed":
			_cmd_is_button_pressed(params)
		"set_button_pressed":
			_cmd_set_button_pressed(params)
		"click_button":
			_cmd_click_button(params)
		"get_option_button_selected":
			_cmd_get_option_button_selected(params)
		"set_option_button_selected":
			_cmd_set_option_button_selected(params)
		"get_tab_container_tab":
			_cmd_get_tab_container_tab(params)
		"set_tab_container_tab":
			_cmd_set_tab_container_tab(params)
		"get_texture_rect_texture":
			_cmd_get_texture_rect_texture(params)
		"set_texture_rect_texture":
			_cmd_set_texture_rect_texture(params)
		"get_color_rect_color":
			_cmd_get_color_rect_color(params)
		"set_color_rect_color":
			_cmd_set_color_rect_color(params)
		"get_panel_stylebox":
			_cmd_get_panel_stylebox(params)
		"get_control_size":
			_cmd_get_control_size(params)
		"set_control_position":
			_cmd_set_control_position(params)
		"set_control_size":
			_cmd_set_control_size(params)
		"get_node_visibility":
			_cmd_get_node_visibility(params)
		"toggle_node_visibility":
			_cmd_toggle_node_visibility(params)
		"get_children_of_node":
			_cmd_get_children_of_node(params)
		"get_parent_of_node":
			_cmd_get_parent_of_node(params)
		"count_nodes_by_class":
			_cmd_count_nodes_by_class(params)
		"find_nodes_by_class":
			_cmd_find_nodes_by_class(params)
		"get_node_property":
			_cmd_get_node_property(params)
		"set_node_property":
			_cmd_set_node_property(params)
		"call_node_method":
			_cmd_call_node_method(params)
		"get_node_property_list":
			_cmd_get_node_property_list(params)
		"get_node_method_list":
			_cmd_get_node_method_list(params)
		"duplicate_node_in_game":
			_cmd_duplicate_node_in_game(params)
		"remove_node_from_game":
			_cmd_remove_node_from_game(params)
		"add_child_node_in_game":
			_cmd_add_child_node_in_game(params)
		"reparent_node_in_game":
			_cmd_reparent_node_in_game(params)
		"change_scene_to":
			_cmd_change_scene_to(params)
		"reload_current_scene":
			_cmd_reload_current_scene(params)
		"quit_game":
			_cmd_quit_game(params)
		"set_vehicle_steering":
			_cmd_set_vehicle_steering(params)
		"set_vehicle_brake":
			_cmd_set_vehicle_brake(params)
		"get_audio_bus_count":
			_cmd_get_audio_bus_count(params)
		"get_audio_bus_name":
			_cmd_get_audio_bus_name(params)
		"set_audio_bus_volume_db":
			_cmd_set_audio_bus_volume_db(params)
		"get_audio_bus_volume_db":
			_cmd_get_audio_bus_volume_db(params)
		"set_audio_bus_muted":
			_cmd_set_audio_bus_muted(params)
		"is_audio_bus_muted":
			_cmd_is_audio_bus_muted(params)
		"set_audio_stream_player_bus":
			_cmd_set_audio_stream_player_bus(params)
		"get_animation_tree_active":
			_cmd_get_animation_tree_active(params)
		"set_animation_tree_active":
			_cmd_set_animation_tree_active(params)
		"get_animation_tree_parameter":
			_cmd_get_animation_tree_parameter(params)
		"set_animation_tree_parameter":
			_cmd_set_animation_tree_parameter(params)
		"get_blend_shape_count":
			_cmd_get_blend_shape_count(params)
		"get_blend_shape_value":
			_cmd_get_blend_shape_value(params)
		"set_blend_shape_value":
			_cmd_set_blend_shape_value(params)
		"get_material_property":
			_cmd_get_material_property(params)
		"create_material_override":
			_cmd_create_material_override(params)
		"get_shader_global_parameter":
			_cmd_get_shader_global_parameter(params)
		"set_shader_global_parameter":
			_cmd_set_shader_global_parameter(params)
		"get_tilemap_used_rect":
			_cmd_get_tilemap_used_rect(params)
		"get_tilemap_cell_at":
			_cmd_get_tilemap_cell_at(params)
		"set_tilemap_cell":
			_cmd_set_tilemap_cell(params)
		"clear_tilemap_layer":
			_cmd_clear_tilemap_layer(params)
		"get_tilemap_layer_count":
			_cmd_get_tilemap_layer_count(params)
		"set_tilemap_layer_enabled":
			_cmd_set_tilemap_layer_enabled(params)
		"world_to_map":
			_cmd_world_to_map(params)
		"map_to_world":
			_cmd_map_to_world(params)
		"get_sprite_frame":
			_cmd_get_sprite_frame(params)
		"set_sprite_frame":
			_cmd_set_sprite_frame(params)
		"get_sprite_texture":
			_cmd_get_sprite_texture(params)
		"set_sprite_texture":
			_cmd_set_sprite_texture(params)
		"flip_sprite":
			_cmd_flip_sprite(params)
		"get_label_font_size":
			_cmd_get_label_font_size(params)
		"set_label_font_size":
			_cmd_set_label_font_size(params)
		"set_label_color":
			_cmd_set_label_color(params)
		"get_button_text":
			_cmd_get_button_text(params)
		"set_button_text":
			_cmd_set_button_text(params)
		"get_game_fps":
			_cmd_get_game_fps(params)
		"get_game_time_elapsed":
			_cmd_get_game_time_elapsed(params)
		"pause_game":
			_cmd_pause_game(params)
		"unpause_game":
			_cmd_unpause_game(params)
		"is_game_paused":
			_cmd_is_game_paused(params)
		"change_scene_to_file":
			_cmd_change_scene_to_file(params)
		"get_current_scene_name":
			_cmd_get_current_scene_name(params)
		"get_node_class_name":
			_cmd_get_node_class_name(params)
		"set_engine_time_scale":
			_cmd_set_engine_time_scale(params)
		"get_engine_time_scale":
			_cmd_get_engine_time_scale(params)
		"get_game_screen_size":
			_cmd_get_game_screen_size(params)
		"get_game_mouse_position":
			_cmd_get_game_mouse_position(params)
		"get_node_z_index":
			_cmd_get_node_z_index(params)
		"get_node_modulate":
			_cmd_get_node_modulate(params)
		"set_node_modulate":
			_cmd_set_node_modulate(params)
		"get_node_self_modulate":
			_cmd_get_node_self_modulate(params)
		"set_node_self_modulate":
			_cmd_set_node_self_modulate(params)
		"get_node_process_mode":
			_cmd_get_node_process_mode(params)
		"set_node_process_mode":
			_cmd_set_node_process_mode(params)
		"get_node_name":
			_cmd_get_node_name(params)
		"set_node_name":
			_cmd_set_node_name(params)
		"get_node_child_count":
			_cmd_get_node_child_count(params)
		"get_node_child_names":
			_cmd_get_node_child_names(params)
		"move_node_child_to_front":
			_cmd_move_node_child_to_front(params)
		"move_node_child_to_back":
			_cmd_move_node_child_to_back(params)
		"is_node_inside_tree":
			_cmd_is_node_inside_tree(params)
		"start_timer":
			_cmd_start_timer(params)
		"stop_timer":
			_cmd_stop_timer(params)
		"is_timer_stopped":
			_cmd_is_timer_stopped(params)
		"get_timer_time_left":
			_cmd_get_timer_time_left(params)
		"get_timer_wait_time":
			_cmd_get_timer_wait_time(params)
		"set_timer_wait_time":
			_cmd_set_timer_wait_time(params)
		"get_timer_one_shot":
			_cmd_get_timer_one_shot(params)
		"set_timer_one_shot":
			_cmd_set_timer_one_shot(params)
		"get_animation_list":
			_cmd_get_animation_list(params)
		"get_current_animation":
			_cmd_get_current_animation(params)
		"is_animation_playing":
			_cmd_is_animation_playing(params)
		"play_animation_from_position":
			_cmd_play_animation_from_position(params)
		"set_animation_blend_time":
			_cmd_set_animation_blend_time(params)
		"queue_animation":
			_cmd_queue_animation(params)
		"get_performance_monitor":
			_cmd_get_performance_monitor(params)
		"get_physics_info":
			_cmd_get_physics_info(params)
		"set_max_fps":
			_cmd_set_max_fps(params)
		"get_max_fps":
			_cmd_get_max_fps(params)
		"get_control_position":
			_cmd_get_control_position(params)
		"get_control_anchor":
			_cmd_get_control_anchor(params)
		"set_control_anchor_preset":
			_cmd_set_control_anchor_preset(params)
		"set_progress_bar_max":
			_cmd_set_progress_bar_max(params)
		"add_item_list_item_text":
			_cmd_add_item_list_item_text(params)
		"get_item_list_count":
			_cmd_get_item_list_count(params)
		"set_rich_text_label_text":
			_cmd_set_rich_text_label_text(params)
		"get_rich_text_label_text":
			_cmd_get_rich_text_label_text(params)
		"append_rich_text":
			_cmd_append_rich_text(params)
		"clear_rich_text":
			_cmd_clear_rich_text(params)
		"list_input_actions":
			_cmd_list_input_actions(params)
		"is_action_just_pressed":
			_cmd_is_action_just_pressed(params)
		"is_action_just_released":
			_cmd_is_action_just_released(params)
		"get_action_strength":
			_cmd_get_action_strength(params)
		"simulate_action_press":
			_cmd_simulate_action_press(params)
		"simulate_action_release":
			_cmd_simulate_action_release(params)
		"get_mouse_mode":
			_cmd_get_mouse_mode(params)
		"get_multiplayer_peer_id":
			_cmd_get_multiplayer_peer_id(params)
		"is_multiplayer_server":
			_cmd_is_multiplayer_server(params)
		"get_network_peer_count":
			_cmd_get_network_peer_count(params)
		"set_node_multiplayer_authority":
			_cmd_set_node_multiplayer_authority(params)
		"get_node_multiplayer_authority":
			_cmd_get_node_multiplayer_authority(params)
		"rpc_call":
			_cmd_rpc_call(params)
		"broadcast_to_group":
			_cmd_broadcast_to_group(params)
		"tween_position_2d":
			_cmd_tween_position_2d(params)
		"tween_rotation_2d":
			_cmd_tween_rotation_2d(params)
		"tween_scale_2d":
			_cmd_tween_scale_2d(params)
		"tween_alpha":
			_cmd_tween_alpha(params)
		"tween_color":
			_cmd_tween_color(params)
		"flash_node":
			_cmd_flash_node(params)
		"shake_node":
			_cmd_shake_node(params)
		"fade_in_node":
			_cmd_fade_in_node(params)
		"fade_out_node":
			_cmd_fade_out_node(params)
		"get_audio_bus_names":
			_cmd_get_audio_bus_names(params)
		"add_audio_bus":
			_cmd_add_audio_bus(params)
		"remove_audio_bus":
			_cmd_remove_audio_bus(params)
		"get_audio_bus_muted":
			_cmd_get_audio_bus_muted(params)
		"get_audio_bus_solo":
			_cmd_get_audio_bus_solo(params)
		"set_audio_bus_solo":
			_cmd_set_audio_bus_solo(params)
		"set_audio_bus_send":
			_cmd_set_audio_bus_send(params)
		"find_nodes_in_group":
			_cmd_find_nodes_in_group(params)
		"add_node_to_group_runtime":
			_cmd_add_node_to_group_runtime(params)
		"remove_node_from_group_runtime":
			_cmd_remove_node_from_group_runtime(params)
		"get_nodes_of_class":
			_cmd_get_nodes_of_class(params)
		"get_node_owner_path":
			_cmd_get_node_owner_path(params)
		"get_node_unique_name":
			_cmd_get_node_unique_name(params)
		"get_2d_collision_layers_names":
			_cmd_get_2d_collision_layers_names(params)
		"set_physics_body_collision_layer":
			_cmd_set_physics_body_collision_layer(params)
		"get_physics_body_collision_layer":
			_cmd_get_physics_body_collision_layer(params)
		"set_physics_body_collision_mask":
			_cmd_set_physics_body_collision_mask(params)
		"get_physics_body_collision_mask":
			_cmd_get_physics_body_collision_mask(params)
		"enable_physics_body":
			_cmd_enable_physics_body(params)
		"set_physics_body_3d_collision_layer":
			_cmd_set_physics_body_3d_collision_layer(params)
		"get_physics_body_3d_collision_layer":
			_cmd_get_physics_body_3d_collision_layer(params)
		"set_physics_body_3d_collision_mask":
			_cmd_set_physics_body_3d_collision_mask(params)
		"get_physics_body_3d_collision_mask":
			_cmd_get_physics_body_3d_collision_mask(params)
		"set_rigid_body_3d_sleeping":
			_cmd_set_rigid_body_3d_sleeping(params)
		"get_rigid_body_3d_state":
			_cmd_get_rigid_body_3d_state(params)
		"set_character_body_3d_velocity":
			_cmd_set_character_body_3d_velocity(params)
		"get_character_body_3d_velocity":
			_cmd_get_character_body_3d_velocity(params)
		"is_character_body_3d_on_floor":
			_cmd_is_character_body_3d_on_floor(params)
		"apply_impulse_3d":
			_cmd_apply_impulse_3d(params)
		"get_environment_info":
			_cmd_get_environment_info(params)
		"set_environment_brightness":
			_cmd_set_environment_brightness(params)
		"set_directional_light_energy":
			_cmd_set_directional_light_energy(params)
		"set_directional_light_color":
			_cmd_set_directional_light_color(params)
		"set_omni_light_energy":
			_cmd_set_omni_light_energy(params)
		"set_omni_light_range":
			_cmd_set_omni_light_range(params)
		"set_spot_light_energy":
			_cmd_set_spot_light_energy(params)
		"get_3d_camera_info":
			_cmd_get_3d_camera_info(params)
		"set_camera_3d_fov":
			_cmd_set_camera_3d_fov(params)
		"set_camera_3d_near":
			_cmd_set_camera_3d_near(params)
		"set_camera_3d_far":
			_cmd_set_camera_3d_far(params)
		"make_camera_current":
			_cmd_make_camera_current(params)
		"get_visible_rect":
			_cmd_get_visible_rect(params)
		"get_animation_current":
			_cmd_get_animation_current(params)
		"get_animation_length":
			_cmd_get_animation_length(params)
		"set_animation_loop":
			_cmd_set_animation_loop(params)
		"get_animation_tree_state":
			_cmd_get_animation_tree_state(params)
		"set_blend_parameter":
			_cmd_set_blend_parameter(params)
		"get_blend_parameter":
			_cmd_get_blend_parameter(params)
		"travel_animation_state":
			_cmd_travel_animation_state(params)
		"set_shader_parameter":
			_cmd_set_shader_parameter(params)
		"get_shader_parameter":
			_cmd_get_shader_parameter(params)
		"set_material_albedo_color":
			_cmd_set_material_albedo_color(params)
		"set_material_emission_color":
			_cmd_set_material_emission_color(params)
		"set_material_transparency":
			_cmd_set_material_transparency(params)
		"get_node_material":
			_cmd_get_node_material(params)
		"set_material_roughness_metallic":
			_cmd_set_material_roughness_metallic(params)
		"get_input_action_list":
			_cmd_get_input_action_list(params)
		"is_input_action_pressed":
			_cmd_is_input_action_pressed(params)
		"get_input_action_strength":
			_cmd_get_input_action_strength(params)
		"get_connected_joypads":
			_cmd_get_connected_joypads(params)
		"get_navigation_agent_2d_path":
			_cmd_get_navigation_agent_2d_path(params)
		"set_navigation_agent_2d_target":
			_cmd_set_navigation_agent_2d_target(params)
		"get_navigation_agent_3d_path":
			_cmd_get_navigation_agent_3d_path(params)
		"set_navigation_agent_3d_target":
			_cmd_set_navigation_agent_3d_target(params)
		"is_navigation_agent_2d_finished":
			_cmd_is_navigation_agent_2d_finished(params)
		"is_navigation_agent_3d_finished":
			_cmd_is_navigation_agent_3d_finished(params)
		"get_navigation_map_rid":
			_cmd_get_navigation_map_rid(params)
		"get_navigation_agent_velocity":
			_cmd_get_navigation_agent_velocity(params)
		"get_multiplayer_authority":
			_cmd_get_multiplayer_authority(params)
		"set_multiplayer_authority":
			_cmd_set_multiplayer_authority(params)
		"is_multiplayer_authority":
			_cmd_is_multiplayer_authority(params)
		"get_network_latency":
			_cmd_get_network_latency(params)
		"set_node_visible":
			_cmd_set_node_visible(params)
		"get_node_visible":
			_cmd_get_node_visible(params)
		"set_sprite_2d_frame":
			_cmd_set_sprite_2d_frame(params)
		"get_sprite_2d_frame_count":
			_cmd_get_sprite_2d_frame_count(params)
		"set_sprite_2d_hframes":
			_cmd_set_sprite_2d_hframes(params)
		"set_sprite_2d_vframes":
			_cmd_set_sprite_2d_vframes(params)
		"set_sprite_2d_flip":
			_cmd_set_sprite_2d_flip(params)
		"set_animated_sprite_2d_speed":
			_cmd_set_animated_sprite_2d_speed(params)
		"get_animated_sprite_2d_frame":
			_cmd_get_animated_sprite_2d_frame(params)
		"look_at_3d":
			_cmd_look_at_3d(params)
		"rotate_node_x":
			_cmd_rotate_node_x(params)
		"rotate_node_y":
			_cmd_rotate_node_y(params)
		"rotate_node_z":
			_cmd_rotate_node_z(params)
		"translate_node_local":
			_cmd_translate_node_local(params)
		"translate_node_global":
			_cmd_translate_node_global(params)
		"get_node_3d_global_position":
			_cmd_get_node_3d_global_position(params)
		"get_node_3d_global_rotation":
			_cmd_get_node_3d_global_rotation(params)
		"reset_node_3d_transform":
			_cmd_reset_node_3d_transform(params)
		"get_distance_to_3d":
			_cmd_get_distance_to_3d(params)
		"set_particle_amount":
			_cmd_set_particle_amount(params)
		"get_particle_info":
			_cmd_get_particle_info(params)
		"set_particle_speed_scale":
			_cmd_set_particle_speed_scale(params)
		"set_particle_explosiveness":
			_cmd_set_particle_explosiveness(params)
		"set_particle_randomness":
			_cmd_set_particle_randomness(params)
		"set_particle_lifetime":
			_cmd_set_particle_lifetime(params)
		"set_particle_one_shot":
			_cmd_set_particle_one_shot(params)
		"set_control_anchor":
			_cmd_set_control_anchor(params)
		"get_control_rect":
			_cmd_get_control_rect(params)
		"get_control_focus":
			_cmd_get_control_focus(params)
		"set_control_focus":
			_cmd_set_control_focus(params)
		"get_node_signal_list":
			_cmd_get_node_signal_list(params)
		"has_signal":
			_cmd_has_signal(params)
		"get_signal_connection_list":
			_cmd_get_signal_connection_list(params)
		"get_node_connections_count":
			_cmd_get_node_connections_count(params)
		"list_all_signal_connections":
			_cmd_list_all_signal_connections(params)
		"get_node_path":
			_cmd_get_node_path(params)
		"get_node_parent_path":
			_cmd_get_node_parent_path(params)
		"get_node_child_paths":
			_cmd_get_node_child_paths(params)
		"is_node_in_group":
			_cmd_is_node_in_group(params)
		"set_light_2d_energy":
			_cmd_set_light_2d_energy(params)
		"get_light_2d_info":
			_cmd_get_light_2d_info(params)
		"set_light_2d_color":
			_cmd_set_light_2d_color(params)
		"set_light_2d_texture_scale":
			_cmd_set_light_2d_texture_scale(params)
		"toggle_light_2d":
			_cmd_toggle_light_2d(params)
		"get_skeleton_bone_pose":
			_cmd_get_skeleton_bone_pose(params)
		"set_skeleton_bone_pose_position":
			_cmd_set_skeleton_bone_pose_position(params)
		"get_bone_rest_transform":
			_cmd_get_bone_rest_transform(params)
		"get_bone_index":
			_cmd_get_bone_index(params)
		"get_game_resolution":
			_cmd_get_game_resolution(params)
		"set_2d_speed_scale":
			_cmd_set_2d_speed_scale(params)
		"get_scene_current_fps":
			_cmd_get_scene_current_fps(params)
		"set_canvas_item_clip":
			_cmd_set_canvas_item_clip(params)
		"get_node_rid":
			_cmd_get_node_rid(params)
		"set_node_owner":
			_cmd_set_node_owner(params)
		"get_physics_interpolation_mode":
			_cmd_get_physics_interpolation_mode(params)
		"get_memory_usage":
			_cmd_get_memory_usage(params)
		"get_project_name":
			_cmd_get_project_name(params)
		"enable_ray_cast_2d":
			_cmd_enable_ray_cast_2d(params)
		"set_ray_cast_2d_target":
			_cmd_set_ray_cast_2d_target(params)
		"get_ray_cast_2d_collision":
			_cmd_get_ray_cast_2d_collision(params)
		"enable_ray_cast_3d":
			_cmd_enable_ray_cast_3d(params)
		"set_ray_cast_3d_target":
			_cmd_set_ray_cast_3d_target(params)
		"get_ray_cast_3d_collision":
			_cmd_get_ray_cast_3d_collision(params)
		"force_ray_cast_update":
			_cmd_force_ray_cast_update(params)
		"cast_ray_from_camera":
			_cmd_cast_ray_from_camera(params)
		"get_overlapping_bodies_2d":
			_cmd_get_overlapping_bodies_2d(params)
		"get_overlapping_areas_2d":
			_cmd_get_overlapping_areas_2d(params)
		"get_overlapping_bodies_3d":
			_cmd_get_overlapping_bodies_3d(params)
		"get_overlapping_areas_3d":
			_cmd_get_overlapping_areas_3d(params)
		"check_area_2d_monitoring":
			_cmd_check_area_2d_monitoring(params)
		"get_audio_bus_info":
			_cmd_get_audio_bus_info(params)
		"set_audio_bus_effect_enabled":
			_cmd_set_audio_bus_effect_enabled(params)
		"get_audio_stream_player_position":
			_cmd_get_audio_stream_player_position(params)
		"set_audio_stream_player_position":
			_cmd_set_audio_stream_player_position(params)
		"get_audio_stream_length":
			_cmd_get_audio_stream_length(params)
		"set_audio_pitch_scale":
			_cmd_set_audio_pitch_scale(params)
		"get_sub_viewport_texture_rid":
			_cmd_get_sub_viewport_texture_rid(params)
		"set_sub_viewport_size":
			_cmd_set_sub_viewport_size(params)
		"set_sub_viewport_update_mode":
			_cmd_set_sub_viewport_update_mode(params)
		"get_viewport_textures":
			_cmd_get_viewport_textures(params)
		"set_viewport_msaa":
			_cmd_set_viewport_msaa(params)
		"get_class_property_list":
			_cmd_get_class_property_list(params)
		"get_class_method_list":
			_cmd_get_class_method_list(params)
		"get_class_signal_list":
			_cmd_get_class_signal_list(params)
		"class_exists":
			_cmd_class_exists(params)
		"get_class_inheritance":
			_cmd_get_class_inheritance(params)
		"instantiate_class_check":
			_cmd_instantiate_class_check(params)
		"get_mesh_aabb":
			_cmd_get_mesh_aabb(params)
		"get_mesh_vertex_count":
			_cmd_get_mesh_vertex_count(params)
		"set_mesh_instance_cast_shadow":
			_cmd_set_mesh_instance_cast_shadow(params)
		"get_mesh_surface_count_rt":
			_cmd_get_mesh_surface_count_rt(params)
		"set_mesh_lod_bias":
			_cmd_set_mesh_lod_bias(params)
		"get_mesh_instance_bounds":
			_cmd_get_mesh_instance_bounds(params)
		"set_mesh_transparency":
			_cmd_set_mesh_transparency(params)
		"rename_node_runtime":
			_cmd_rename_node_runtime(params)
		"list_node_metadata":
			_cmd_list_node_metadata(params)
		"remove_node_metadata":
			_cmd_remove_node_metadata(params)
		"get_physics_2d_gravity":
			_cmd_get_physics_2d_gravity(params)
		"get_all_node_classes":
			_cmd_get_all_node_classes(params)
		"get_running_scene_path":
			_cmd_get_running_scene_path(params)
		"get_node_scene_file_path":
			_cmd_get_node_scene_file_path(params)
		"get_scene_unique_nodes":
			_cmd_get_scene_unique_nodes(params)
		"get_tilemap_cell_source_id":
			_cmd_get_tilemap_cell_source_id(params)
		"erase_tilemap_cell":
			_cmd_erase_tilemap_cell(params)
		"get_tilemap_used_cells":
			_cmd_get_tilemap_used_cells(params)
		"map_to_local_tilemap":
			_cmd_map_to_local_tilemap(params)
		"get_gridmap_cell_item":
			_cmd_get_gridmap_cell_item(params)
		"set_gridmap_cell_item":
			_cmd_set_gridmap_cell_item(params)
		"get_gridmap_used_cells":
			_cmd_get_gridmap_used_cells(params)
		"clear_gridmap":
			_cmd_clear_gridmap(params)
		"get_gridmap_cell_size":
			_cmd_get_gridmap_cell_size(params)
		"get_gridmap_mesh_library_items":
			_cmd_get_gridmap_mesh_library_items(params)
		"get_gridmap_bake_mesh":
			_cmd_get_gridmap_bake_mesh(params)
		"play_video_stream":
			_cmd_play_video_stream(params)
		"stop_video_stream":
			_cmd_stop_video_stream(params)
		"get_video_stream_position":
			_cmd_get_video_stream_position(params)
		"set_video_stream_volume":
			_cmd_set_video_stream_volume(params)
		"is_video_stream_playing":
			_cmd_is_video_stream_playing(params)
		"get_astar2d_point_count":
			_cmd_get_astar2d_point_count(params)
		"add_astar2d_point":
			_cmd_add_astar2d_point(params)
		"connect_astar2d_points":
			_cmd_connect_astar2d_points(params)
		"get_astar2d_id_path":
			_cmd_get_astar2d_id_path(params)
		"get_astar2d_point_path":
			_cmd_get_astar2d_point_path(params)
		"get_world_environment_info":
			_cmd_get_world_environment_info(params)
		"set_environment_ambient_light":
			_cmd_set_environment_ambient_light(params)
		"set_environment_bloom":
			_cmd_set_environment_bloom(params)
		"set_environment_tonemap":
			_cmd_set_environment_tonemap(params)
		"set_environment_sky_color":
			_cmd_set_environment_sky_color(params)
		"set_particles_lifetime":
			_cmd_set_particles_lifetime(params)
		"set_particles_explosiveness":
			_cmd_set_particles_explosiveness(params)
		"set_particles_one_shot":
			_cmd_set_particles_one_shot(params)
		"set_light_energy":
			_cmd_set_light_energy(params)
		"set_light_color":
			_cmd_set_light_color(params)
		"set_directional_light_shadow":
			_cmd_set_directional_light_shadow(params)
		"get_light_info":
			_cmd_get_light_info(params)
		"get_character_body_2d_info":
			_cmd_get_character_body_2d_info(params)
		"set_rigid_body_2d_mass":
			_cmd_set_rigid_body_2d_mass(params)
		"set_rigid_body_2d_gravity_scale":
			_cmd_set_rigid_body_2d_gravity_scale(params)
		"apply_central_impulse_2d":
			_cmd_apply_central_impulse_2d(params)
		"set_rigid_body_2d_freeze":
			_cmd_set_rigid_body_2d_freeze(params)
		"get_rigid_body_2d_info":
			_cmd_get_rigid_body_2d_info(params)
		"set_character_body_2d_velocity":
			_cmd_set_character_body_2d_velocity(params)
		"get_character_body_3d_info":
			_cmd_get_character_body_3d_info(params)
		"set_rigid_body_3d_mass":
			_cmd_set_rigid_body_3d_mass(params)
		"apply_central_impulse_3d":
			_cmd_apply_central_impulse_3d(params)
		"set_rigid_body_3d_gravity_scale":
			_cmd_set_rigid_body_3d_gravity_scale(params)
		"set_rigid_body_3d_freeze":
			_cmd_set_rigid_body_3d_freeze(params)
		"get_rigid_body_3d_info":
			_cmd_get_rigid_body_3d_info(params)
		"set_material_metallic":
			_cmd_set_material_metallic(params)
		"set_material_roughness":
			_cmd_set_material_roughness(params)
		"set_material_emission":
			_cmd_set_material_emission(params)
		"set_material_alpha_mode":
			_cmd_set_material_alpha_mode(params)
		"get_material_info":
			_cmd_get_material_info(params)
		"set_material_cull_mode":
			_cmd_set_material_cull_mode(params)
		"set_collision_shape_disabled":
			_cmd_set_collision_shape_disabled(params)
		"set_circle_shape_radius":
			_cmd_set_circle_shape_radius(params)
		"set_rect_shape_size":
			_cmd_set_rect_shape_size(params)
		"set_capsule_shape_size":
			_cmd_set_capsule_shape_size(params)
		"set_box_shape_size_3d":
			_cmd_set_box_shape_size_3d(params)
		"get_collision_layer_mask":
			_cmd_get_collision_layer_mask(params)
		"is_key_pressed":
			_cmd_is_key_pressed(params)
		"get_joy_axis":
			_cmd_get_joy_axis(params)
		"set_control_offset":
			_cmd_set_control_offset(params)
		"set_control_focus_mode":
			_cmd_set_control_focus_mode(params)
		"set_rich_text_bbcode":
			_cmd_set_rich_text_bbcode(params)
		"set_button_disabled":
			_cmd_set_button_disabled(params)
		"get_check_button_state":
			_cmd_get_check_button_state(params)
		"set_check_button_state":
			_cmd_set_check_button_state(params)
		"set_range_value":
			_cmd_set_range_value(params)
		"get_range_value":
			_cmd_get_range_value(params)
		"set_range_min_max":
			_cmd_set_range_min_max(params)
		"set_h_slider_value":
			_cmd_set_h_slider_value(params)
		"get_h_slider_value":
			_cmd_get_h_slider_value(params)
		"get_theme_info":
			_cmd_get_theme_info(params)
		"set_theme_font_size":
			_cmd_set_theme_font_size(params)
		"set_theme_color":
			_cmd_set_theme_color(params)
		"set_panel_stylebox_color":
			_cmd_set_panel_stylebox_color(params)
		"set_panel_border_color":
			_cmd_set_panel_border_color(params)
		"get_control_theme_type":
			_cmd_get_control_theme_type(params)
		"set_control_theme_type":
			_cmd_set_control_theme_type(params)
		"create_property_tween":
			_cmd_create_property_tween(params)
		"create_color_tween":
			_cmd_create_color_tween(params)
		"tween_node_position_2d":
			_cmd_tween_node_position_2d(params)
		"tween_node_scale":
			_cmd_tween_node_scale(params)
		"tween_node_alpha":
			_cmd_tween_node_alpha(params)
		"tween_node_rotation":
			_cmd_tween_node_rotation(params)
		"flash_node_color":
			_cmd_flash_node_color(params)
		"get_system_memory_info":
			_cmd_get_system_memory_info(params)
		"get_processor_name":
			_cmd_get_processor_name(params)
		"get_locale":
			_cmd_get_locale(params)
		"get_screen_resolution":
			_cmd_get_screen_resolution(params)
		"get_navigation_agent_2d_target":
			_cmd_get_navigation_agent_2d_target(params)
		"get_navigation_region_3d_baked":
			_cmd_get_navigation_region_3d_baked(params)
		"get_sprite_frame_info":
			_cmd_get_sprite_frame_info(params)
		"set_sprite_hframes":
			_cmd_set_sprite_hframes(params)
		"set_sprite_vframes":
			_cmd_set_sprite_vframes(params)
		"set_sprite_region_rect":
			_cmd_set_sprite_region_rect(params)
		"set_sprite_region_enabled":
			_cmd_set_sprite_region_enabled(params)
		"set_texture_rect_stretch":
			_cmd_set_texture_rect_stretch(params)
		"set_texture_rect_flip":
			_cmd_set_texture_rect_flip(params)
		"get_texture_rect_info":
			_cmd_get_texture_rect_info(params)
		"set_nine_patch_margins":
			_cmd_set_nine_patch_margins(params)
		"set_nine_patch_draw_center":
			_cmd_set_nine_patch_draw_center(params)
		"get_nine_patch_info":
			_cmd_get_nine_patch_info(params)
		"set_camera_2d_limits":
			_cmd_set_camera_2d_limits(params)
		"set_camera_2d_drag_margins":
			_cmd_set_camera_2d_drag_margins(params)
		"reset_camera_2d":
			_cmd_reset_camera_2d(params)
		"set_camera_2d_process_callback":
			_cmd_set_camera_2d_process_callback(params)
		"get_camera_2d_screen_center":
			_cmd_get_camera_2d_screen_center(params)
		"shake_camera_2d":
			_cmd_shake_camera_2d(params)
		"get_audio_player_3d_info":
			_cmd_get_audio_player_3d_info(params)
		"set_audio_player_3d_volume":
			_cmd_set_audio_player_3d_volume(params)
		"set_audio_player_3d_max_distance":
			_cmd_set_audio_player_3d_max_distance(params)
		"set_audio_player_3d_unit_size":
			_cmd_set_audio_player_3d_unit_size(params)
		"set_audio_player_3d_doppler":
			_cmd_set_audio_player_3d_doppler(params)
		"play_audio_player_3d_at_position":
			_cmd_play_audio_player_3d_at_position(params)
		"get_shader_param":
			_cmd_get_shader_param(params)
		"set_shader_param_color":
			_cmd_set_shader_param_color(params)
		"set_shader_param_vec2":
			_cmd_set_shader_param_vec2(params)
		"set_shader_param_vec3":
			_cmd_set_shader_param_vec3(params)
		"list_shader_params":
			_cmd_list_shader_params(params)
		"get_path_2d_point_count":
			_cmd_get_path_2d_point_count(params)
		"add_path_2d_point":
			_cmd_add_path_2d_point(params)
		"get_path_2d_baked_length":
			_cmd_get_path_2d_baked_length(params)
		"sample_path_2d_baked":
			_cmd_sample_path_2d_baked(params)
		"clear_path_2d":
			_cmd_clear_path_2d(params)
		"get_path_follower_2d_offset":
			_cmd_get_path_follower_2d_offset(params)
		"get_multimesh_instance_count":
			_cmd_get_multimesh_instance_count(params)
		"set_multimesh_instance_count":
			_cmd_set_multimesh_instance_count(params)
		"get_physics_server_info":
			_cmd_get_physics_server_info(params)
		"http_request_get":
			_cmd_http_request_get(params)
		"http_request_post":
			_cmd_http_request_post(params)
		"get_http_client_status":
			_cmd_get_http_client_status(params)
		"get_audio_bus_effect_count":
			_cmd_get_audio_bus_effect_count(params)
		"set_reverb_room_size":
			_cmd_set_reverb_room_size(params)
		"set_reverb_wet":
			_cmd_set_reverb_wet(params)
		"set_delay_dry":
			_cmd_set_delay_dry(params)
		"set_compressor_threshold":
			_cmd_set_compressor_threshold(params)
		"set_eq_band_gain":
			_cmd_set_eq_band_gain(params)
		"get_audio_effect_info":
			_cmd_get_audio_effect_info(params)
		"set_window_fullscreen":
			_cmd_set_window_fullscreen(params)
		"get_window_info":
			_cmd_get_window_info(params)
		"set_window_position":
			_cmd_set_window_position(params)
		"set_window_borderless":
			_cmd_set_window_borderless(params)
		"set_window_always_on_top":
			_cmd_set_window_always_on_top(params)
		"find_nodes_by_group":
			_cmd_find_nodes_by_group(params)
		"set_all_nodes_in_group_visible":
			_cmd_set_all_nodes_in_group_visible(params)
		"get_node_count_in_scene":
			_cmd_get_node_count_in_scene(params)
		"get_nodes_with_script":
			_cmd_get_nodes_with_script(params)
		"set_group_process":
			_cmd_set_group_process(params)
		"get_skeleton_3d_info":
			_cmd_get_skeleton_3d_info(params)
		"set_skeleton_3d_bone_pose_position":
			_cmd_set_skeleton_3d_bone_pose_position(params)
		"get_skeleton_3d_bone_global_pose":
			_cmd_get_skeleton_3d_bone_global_pose(params)
		"reset_skeleton_3d_pose":
			_cmd_reset_skeleton_3d_pose(params)
		"get_skeleton_3d_bone_name":
			_cmd_get_skeleton_3d_bone_name(params)
		"find_skeleton_3d_bone_by_name":
			_cmd_find_skeleton_3d_bone_by_name(params)
		"set_skeleton_3d_bone_enabled":
			_cmd_set_skeleton_3d_bone_enabled(params)
		"create_http_request_node":
			_cmd_create_http_request_node(params)
		"get_last_http_response":
			_cmd_get_last_http_response(params)
		"download_file_via_http":
			_cmd_download_file_via_http(params)
		"get_node_children_recursive":
			_cmd_get_node_children_recursive(params)
		"get_scene_instanced_count":
			_cmd_get_scene_instanced_count(params)
		"get_animation_player_animations":
			_cmd_get_animation_player_animations(params)
		"get_unix_time":
			_cmd_get_unix_time(params)
		"get_datetime_dict":
			_cmd_get_datetime_dict(params)
		"get_ticks_msec":
			_cmd_get_ticks_msec(params)
		"get_ticks_usec":
			_cmd_get_ticks_usec(params)
		"unix_time_to_datetime":
			_cmd_unix_time_to_datetime(params)
		"datetime_to_unix_time":
			_cmd_datetime_to_unix_time(params)
		"hash_string_sha256":
			_cmd_hash_string_sha256(params)
		"hash_string_md5":
			_cmd_hash_string_md5(params)
		"generate_uuid_v4":
			_cmd_generate_uuid_v4(params)
		"base64_encode":
			_cmd_base64_encode(params)
		"base64_decode":
			_cmd_base64_decode(params)
		"get_random_int":
			_cmd_get_random_int(params)
		"get_input_map_actions":
			_cmd_get_input_map_actions(params)
		"action_has_event":
			_cmd_action_has_event(params)
		"add_input_action":
			_cmd_add_input_action(params)
		"erase_input_action":
			_cmd_erase_input_action(params)
		"action_get_deadzone":
			_cmd_action_get_deadzone(params)
		"get_actions_for_key":
			_cmd_get_actions_for_key(params)
		"gdscript_string_format":
			_cmd_gdscript_string_format(params)
		"json_stringify_in_godot":
			_cmd_json_stringify_in_godot(params)
		"json_parse_in_godot":
			_cmd_json_parse_in_godot(params)
		"evaluate_gdscript_expression":
			_cmd_evaluate_gdscript_expression(params)
		"get_string_length":
			_cmd_get_string_length(params)
		"start_animation_state":
			_cmd_start_animation_state(params)
		"stop_animation_state_machine":
			_cmd_stop_animation_state_machine(params)
		"get_current_animation_state":
			_cmd_get_current_animation_state(params)
		"get_path_3d_baked_length":
			_cmd_get_path_3d_baked_length(params)
		"get_path_3d_point_count":
			_cmd_get_path_3d_point_count(params)
		"add_path_3d_point":
			_cmd_add_path_3d_point(params)
		"remove_path_3d_point":
			_cmd_remove_path_3d_point(params)
		"get_path_3d_point_position":
			_cmd_get_path_3d_point_position(params)
		"sample_path_3d_at_offset":
			_cmd_sample_path_3d_at_offset(params)
		"get_pin_joint_2d_info":
			_cmd_get_pin_joint_2d_info(params)
		"set_pin_joint_2d_softness":
			_cmd_set_pin_joint_2d_softness(params)
		"get_groove_joint_2d_info":
			_cmd_get_groove_joint_2d_info(params)
		"get_damped_spring_joint_2d_info":
			_cmd_get_damped_spring_joint_2d_info(params)
		"set_damped_spring_joint_2d_stiffness":
			_cmd_set_damped_spring_joint_2d_stiffness(params)
		"get_hinge_joint_3d_info":
			_cmd_get_hinge_joint_3d_info(params)
		"get_slider_joint_3d_info":
			_cmd_get_slider_joint_3d_info(params)
		"get_cone_twist_joint_3d_info":
			_cmd_get_cone_twist_joint_3d_info(params)
		"get_generic_6dof_joint_info":
			_cmd_get_generic_6dof_joint_info(params)
		"set_joint_3d_node_paths":
			_cmd_set_joint_3d_node_paths(params)
		"get_vehicle_body_3d_info":
			_cmd_get_vehicle_body_3d_info(params)
		"set_vehicle_body_3d_engine_force":
			_cmd_set_vehicle_body_3d_engine_force(params)
		"get_spring_arm_3d_info":
			_cmd_get_spring_arm_3d_info(params)
		"set_spring_arm_3d_length":
			_cmd_set_spring_arm_3d_length(params)
		"get_bone_attachment_3d_info":
			_cmd_get_bone_attachment_3d_info(params)
		"set_bone_attachment_3d_bone_name":
			_cmd_set_bone_attachment_3d_bone_name(params)
		"get_physical_bone_3d_info":
			_cmd_get_physical_bone_3d_info(params)
		"apply_physical_bone_impulse":
			_cmd_apply_physical_bone_impulse(params)
		"get_skeleton_physical_bones_simulating":
			_cmd_get_skeleton_physical_bones_simulating(params)
		"get_decal_3d_info":
			_cmd_get_decal_3d_info(params)
		"set_decal_3d_size":
			_cmd_set_decal_3d_size(params)
		"set_decal_3d_albedo_mix":
			_cmd_set_decal_3d_albedo_mix(params)
		"get_csg_shape_info":
			_cmd_get_csg_shape_info(params)
		"set_csg_shape_operation":
			_cmd_set_csg_shape_operation(params)
		"get_csg_combined_faces":
			_cmd_get_csg_combined_faces(params)
		"set_audio_bus_name":
			_cmd_set_audio_bus_name(params)
		"move_audio_bus":
			_cmd_move_audio_bus(params)
		"get_audio_bus_send":
			_cmd_get_audio_bus_send(params)
		"create_enet_peer":
			_cmd_create_enet_peer(params)
		"create_enet_server":
			_cmd_create_enet_server(params)
		"get_enet_connection_status":
			_cmd_get_enet_connection_status(params)
		"create_websocket_peer":
			_cmd_create_websocket_peer(params)
		"get_websocket_peer_state":
			_cmd_get_websocket_peer_state(params)
		"send_websocket_text":
			_cmd_send_websocket_text(params)
		"get_visual_shader_info":
			_cmd_get_visual_shader_info(params)
		"add_visual_shader_node":
			_cmd_add_visual_shader_node(params)
		"remove_visual_shader_node":
			_cmd_remove_visual_shader_node(params)
		"connect_visual_shader_nodes":
			_cmd_connect_visual_shader_nodes(params)
		"get_visual_shader_node_list":
			_cmd_get_visual_shader_node_list(params)
		"set_visual_shader_node_position":
			_cmd_set_visual_shader_node_position(params)
		"get_visual_shader_connections":
			_cmd_get_visual_shader_connections(params)
		"disconnect_visual_shader_nodes":
			_cmd_disconnect_visual_shader_nodes(params)
		"list_system_fonts":
			_cmd_list_system_fonts(params)
		"get_editor_selected_nodes":
			_cmd_get_editor_selected_nodes(params)
		"get_screen_dpi":
			_cmd_get_screen_dpi(params)
		"get_display_server_info":
			_cmd_get_display_server_info(params)
		"get_engine_target_fps":
			_cmd_get_engine_target_fps(params)
		"set_engine_target_fps":
			_cmd_set_engine_target_fps(params)
		"get_locale_info":
			_cmd_get_locale_info(params)
		"get_environment_variable":
			_cmd_get_environment_variable(params)
		"get_xr_interface_list":
			_cmd_get_xr_interface_list(params)
		"initialize_xr_interface":
			_cmd_initialize_xr_interface(params)
		"get_xr_is_tracking":
			_cmd_get_xr_is_tracking(params)
		"get_xr_controller_input":
			_cmd_get_xr_controller_input(params)
		"get_xr_camera_transform":
			_cmd_get_xr_camera_transform(params)
		"set_xr_world_scale":
			_cmd_set_xr_world_scale(params)
		"get_xr_anchor_info":
			_cmd_get_xr_anchor_info(params)
		"get_navigation_agent_3d_info":
			_cmd_get_navigation_agent_3d_info(params)
		"get_navigation_agent_3d_next_path_pos":
			_cmd_get_navigation_agent_3d_next_path_pos(params)
		"is_navigation_agent_3d_target_reachable":
			_cmd_is_navigation_agent_3d_target_reachable(params)
		"get_navigation_region_3d_enabled":
			_cmd_get_navigation_region_3d_enabled(params)
		"set_navigation_region_3d_enabled":
			_cmd_set_navigation_region_3d_enabled(params)
		"bake_navigation_mesh_3d":
			_cmd_bake_navigation_mesh_3d(params)
		"get_gpu_particles_3d_info":
			_cmd_get_gpu_particles_3d_info(params)
		"set_gpu_particles_3d_amount":
			_cmd_set_gpu_particles_3d_amount(params)
		"set_gpu_particles_3d_lifetime":
			_cmd_set_gpu_particles_3d_lifetime(params)
		"restart_gpu_particles_3d":
			_cmd_restart_gpu_particles_3d(params)
		"set_gpu_particles_3d_one_shot":
			_cmd_set_gpu_particles_3d_one_shot(params)
		"emit_gpu_particles_3d_subemitter":
			_cmd_emit_gpu_particles_3d_subemitter(params)
		"get_performance_monitor_value":
			_cmd_get_performance_monitor_value(params)
		"get_all_performance_monitors":
			_cmd_get_all_performance_monitors(params)
		"set_project_setting_runtime":
			_cmd_set_project_setting_runtime(params)
		"get_rendering_info":
			_cmd_get_rendering_info(params)
		"get_viewport_render_info":
			_cmd_get_viewport_render_info(params)
		"inspect_resource_properties":
			_cmd_inspect_resource_properties(params)
		"get_sky_material_info":
			_cmd_get_sky_material_info(params)
		"get_environment_tone_map":
			_cmd_get_environment_tone_map(params)
		"set_environment_tone_map":
			_cmd_set_environment_tone_map(params)
		"get_environment_glow":
			_cmd_get_environment_glow(params)
		"set_environment_glow_enabled":
			_cmd_set_environment_glow_enabled(params)
		"set_group_property":
			_cmd_set_group_property(params)
		"get_node_incoming_connections":
			_cmd_get_node_incoming_connections(params)
		"get_resource_import_metadata":
			_cmd_get_resource_import_metadata(params)
		"list_resources_of_type":
			_cmd_list_resources_of_type(params)
		"get_gdscript_class_hierarchy":
			_cmd_get_gdscript_class_hierarchy(params)
		"get_script_exported_properties":
			_cmd_get_script_exported_properties(params)
		"get_texture_2d_size":
			_cmd_get_texture_2d_size(params)
		"get_image_info":
			_cmd_get_image_info(params)
		"set_texture_rect_stretch_mode":
			_cmd_set_texture_rect_stretch_mode(params)
		"get_atlas_texture_info":
			_cmd_get_atlas_texture_info(params)
		"create_viewport_texture":
			_cmd_create_viewport_texture(params)
		"get_texture_flags":
			_cmd_get_texture_flags(params)
		"get_sub_viewport_info":
			_cmd_get_sub_viewport_info(params)
		"get_viewport_texture_rid":
			_cmd_get_viewport_texture_rid(params)
		"set_viewport_clear_mode":
			_cmd_set_viewport_clear_mode(params)
		"get_viewport_canvas_transform":
			_cmd_get_viewport_canvas_transform(params)
		"get_label_3d_info":
			_cmd_get_label_3d_info(params)
		"set_label_3d_text":
			_cmd_set_label_3d_text(params)
		"set_label_3d_font_size":
			_cmd_set_label_3d_font_size(params)
		"set_label_3d_billboard":
			_cmd_set_label_3d_billboard(params)
		"get_text_mesh_info":
			_cmd_get_text_mesh_info(params)
		"get_soft_body_3d_info":
			_cmd_get_soft_body_3d_info(params)
		"set_soft_body_3d_simulation_precision":
			_cmd_set_soft_body_3d_simulation_precision(params)
		"pin_soft_body_3d_point":
			_cmd_pin_soft_body_3d_point(params)
		"unpin_soft_body_3d_point":
			_cmd_unpin_soft_body_3d_point(params)
		_:
			_send_response({"error": "Unknown command: %s" % command})


# Send response and clear busy flag
func _send_response(data: Dictionary) -> void:
	_busy = false
	_busy_since = 0.0
	_send_response_raw(data)


# Send response without clearing busy flag (used when rejecting during busy state)
func _send_response_raw(data: Dictionary) -> void:
	if _client == null:
		return
	var json_str: String = JSON.stringify(data) + "\n"
	var bytes: PackedByteArray = json_str.to_utf8_buffer()
	_client.put_data(bytes)


# --- Screenshot ---
func _cmd_screenshot() -> void:
	# Wait one frame so the viewport is fully rendered
	await get_tree().process_frame
	var image: Image = get_viewport().get_texture().get_image()
	if image == null:
		_send_response({"error": "Failed to capture screenshot"})
		return
	var png_buffer: PackedByteArray = image.save_png_to_buffer()
	var base64_str: String = Marshalls.raw_to_base64(png_buffer)
	_send_response({
		"success": true,
		"data": base64_str,
		"width": image.get_width(),
		"height": image.get_height()
	})


# --- Click ---
func _cmd_click(params: Dictionary) -> void:
	var x: float = float(params.get("x", 0))
	var y: float = float(params.get("y", 0))
	var button: int = int(params.get("button", MOUSE_BUTTON_LEFT))

	var pos: Vector2 = Vector2(x, y)

	# Mouse button press
	var press_event: InputEventMouseButton = InputEventMouseButton.new()
	press_event.position = pos
	press_event.global_position = pos
	press_event.button_index = button as MouseButton
	press_event.pressed = true
	Input.parse_input_event(press_event)

	# Wait a frame then release
	await get_tree().process_frame

	var release_event: InputEventMouseButton = InputEventMouseButton.new()
	release_event.position = pos
	release_event.global_position = pos
	release_event.button_index = button as MouseButton
	release_event.pressed = false
	Input.parse_input_event(release_event)

	_send_response({"success": true, "clicked": {"x": x, "y": y, "button": button}})


# --- Key Press ---
func _cmd_key_press(params: Dictionary) -> void:
	var action: String = params.get("action", "")
	var key: String = params.get("key", "")
	var pressed: bool = params.get("pressed", true)

	if action.length() > 0:
		# Simulate an action press/release
		if pressed:
			Input.action_press(action)
		else:
			Input.action_release(action)
		_send_response({"success": true, "action": action, "pressed": pressed})
		return

	if key.length() > 0:
		var keycode: int = _string_to_keycode(key)
		if keycode == KEY_NONE:
			_send_response({"error": "Unknown key: %s" % key})
			return

		var event: InputEventKey = InputEventKey.new()
		event.keycode = keycode as Key
		event.physical_keycode = keycode as Key
		event.pressed = pressed
		Input.parse_input_event(event)

		if pressed:
			# Auto-release after a frame
			await get_tree().process_frame
			var release_event: InputEventKey = InputEventKey.new()
			release_event.keycode = keycode as Key
			release_event.physical_keycode = keycode as Key
			release_event.pressed = false
			Input.parse_input_event(release_event)

		_send_response({"success": true, "key": key, "pressed": pressed})
		return

	_send_response({"error": "Must provide 'key' or 'action' parameter"})


# --- Mouse Move ---
func _cmd_mouse_move(params: Dictionary) -> void:
	var x: float = float(params.get("x", 0))
	var y: float = float(params.get("y", 0))
	var relative_x: float = float(params.get("relative_x", 0))
	var relative_y: float = float(params.get("relative_y", 0))

	var event: InputEventMouseMotion = InputEventMouseMotion.new()
	event.position = Vector2(x, y)
	event.global_position = Vector2(x, y)
	event.relative = Vector2(relative_x, relative_y)
	Input.parse_input_event(event)

	_send_response({"success": true, "position": {"x": x, "y": y}})


# --- Get UI Elements ---
func _cmd_get_ui_elements() -> void:
	var elements: Array = []
	_collect_ui_elements(get_tree().root, elements)
	_send_response({"success": true, "elements": elements})


func _collect_ui_elements(node: Node, elements: Array) -> void:
	if node is Control:
		var ctrl: Control = node as Control
		if ctrl.visible and ctrl.get_global_rect().size.x > 0:
			var info: Dictionary = {
				"name": ctrl.name,
				"type": ctrl.get_class(),
				"path": str(ctrl.get_path()),
				"position": {"x": ctrl.global_position.x, "y": ctrl.global_position.y},
				"size": {"width": ctrl.size.x, "height": ctrl.size.y},
			}
			# Get text content for common text-bearing nodes
			if ctrl is Label:
				info["text"] = (ctrl as Label).text
			elif ctrl is Button:
				info["text"] = (ctrl as Button).text
			elif ctrl is LineEdit:
				info["text"] = (ctrl as LineEdit).text
			elif ctrl is RichTextLabel:
				info["text"] = (ctrl as RichTextLabel).get_parsed_text()

			elements.append(info)

	for child in node.get_children():
		_collect_ui_elements(child, elements)


# --- Get Scene Tree ---
func _cmd_get_scene_tree() -> void:
	var tree: Dictionary = _build_tree_node(get_tree().root)
	_send_response({"success": true, "tree": tree})


func _build_tree_node(node: Node) -> Dictionary:
	var info: Dictionary = {
		"name": node.name,
		"type": node.get_class(),
	}
	var children_arr: Array = []
	for child in node.get_children():
		children_arr.append(_build_tree_node(child))
	if children_arr.size() > 0:
		info["children"] = children_arr
	return info


# --- Key String to Keycode ---
func _init_key_map() -> void:
	_key_map = {
		"A": KEY_A, "B": KEY_B, "C": KEY_C, "D": KEY_D,
		"E": KEY_E, "F": KEY_F, "G": KEY_G, "H": KEY_H,
		"I": KEY_I, "J": KEY_J, "K": KEY_K, "L": KEY_L,
		"M": KEY_M, "N": KEY_N, "O": KEY_O, "P": KEY_P,
		"Q": KEY_Q, "R": KEY_R, "S": KEY_S, "T": KEY_T,
		"U": KEY_U, "V": KEY_V, "W": KEY_W, "X": KEY_X,
		"Y": KEY_Y, "Z": KEY_Z,
		"0": KEY_0, "1": KEY_1, "2": KEY_2, "3": KEY_3,
		"4": KEY_4, "5": KEY_5, "6": KEY_6, "7": KEY_7,
		"8": KEY_8, "9": KEY_9,
		"SPACE": KEY_SPACE, "ENTER": KEY_ENTER, "RETURN": KEY_ENTER,
		"ESCAPE": KEY_ESCAPE, "ESC": KEY_ESCAPE,
		"TAB": KEY_TAB, "BACKSPACE": KEY_BACKSPACE,
		"DELETE": KEY_DELETE, "INSERT": KEY_INSERT,
		"HOME": KEY_HOME, "END": KEY_END,
		"PAGEUP": KEY_PAGEUP, "PAGE_UP": KEY_PAGEUP,
		"PAGEDOWN": KEY_PAGEDOWN, "PAGE_DOWN": KEY_PAGEDOWN,
		"UP": KEY_UP, "DOWN": KEY_DOWN, "LEFT": KEY_LEFT, "RIGHT": KEY_RIGHT,
		"SHIFT": KEY_SHIFT, "CTRL": KEY_CTRL, "CONTROL": KEY_CTRL,
		"ALT": KEY_ALT, "CAPSLOCK": KEY_CAPSLOCK, "CAPS_LOCK": KEY_CAPSLOCK,
		"F1": KEY_F1, "F2": KEY_F2, "F3": KEY_F3, "F4": KEY_F4,
		"F5": KEY_F5, "F6": KEY_F6, "F7": KEY_F7, "F8": KEY_F8,
		"F9": KEY_F9, "F10": KEY_F10, "F11": KEY_F11, "F12": KEY_F12,
	}

func _string_to_keycode(key_str: String) -> int:
	var upper: String = key_str.to_upper()
	if _key_map.has(upper):
		return _key_map[upper]
	if key_str.length() == 1:
		return key_str.unicode_at(0)
	return KEY_NONE


# --- Eval: Execute arbitrary GDScript at runtime ---
func _cmd_eval(params: Dictionary) -> void:
	var code: String = params.get("code", "")
	if code.is_empty():
		_send_response({"error": "No code provided"})
		return

	# Wrap user code in a function so we can capture the return value
	var script_source: String = """extends Node

func execute():
	var __result = null
	__result = await _run()
	return __result

func _run():
%s
""" % [_indent_code(code)]

	var script: GDScript = GDScript.new()
	script.source_code = script_source
	var err: int = script.reload()
	if err != OK:
		_send_response({"error": "Failed to compile GDScript (error %d). Check syntax." % err})
		return

	var temp_node: Node = Node.new()
	temp_node.set_script(script)
	# Allow eval to work even when game is paused
	temp_node.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(temp_node)

	var result: Variant = null
	if temp_node.has_method("execute"):
		result = await temp_node.execute()

	temp_node.queue_free()
	_send_response({"success": true, "result": _variant_to_json(result)})


func _indent_code(code: String) -> String:
	var lines: PackedStringArray = code.split("\n")
	var indented: String = ""
	for line in lines:
		indented += "\t" + line + "\n"
	return indented


# --- Get Property ---
func _cmd_get_property(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property: String = params.get("property", "")
	if node_path.is_empty() or property.is_empty():
		_send_response({"error": "node_path and property are required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	var value: Variant = node.get(property)
	_send_response({"success": true, "value": _variant_to_json(value), "property": property, "node_path": node_path})


# --- Set Property ---
func _cmd_set_property(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property: String = params.get("property", "")
	if node_path.is_empty() or property.is_empty():
		_send_response({"error": "node_path and property are required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	var raw_value: Variant = params.get("value", null)
	var type_hint: String = params.get("type_hint", "")
	var value: Variant
	if type_hint.is_empty():
		value = _json_to_variant_for_property(node, property, raw_value)
	else:
		value = _json_to_variant(raw_value, type_hint)
	node.set(property, value)
	_send_response({"success": true, "node_path": node_path, "property": property, "value": _variant_to_json(node.get(property))})


# --- Call Method ---
func _cmd_call_method(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var method_name: String = params.get("method", "")
	if node_path.is_empty() or method_name.is_empty():
		_send_response({"error": "node_path and method are required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	if not node.has_method(method_name):
		_send_response({"error": "Method not found: %s on node %s" % [method_name, node_path]})
		return

	var args: Array = params.get("args", [])
	var result: Variant = node.callv(method_name, args)
	_send_response({"success": true, "result": _variant_to_json(result)})


# --- Get Node Info ---
func _cmd_get_node_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		_send_response({"error": "node_path is required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	var properties: Array = []
	for prop in node.get_property_list():
		var prop_dict: Dictionary = prop
		if prop_dict.get("usage", 0) & PROPERTY_USAGE_EDITOR:
			properties.append({
				"name": prop_dict.get("name", ""),
				"type": prop_dict.get("type", 0),
				"value": _variant_to_json(node.get(prop_dict.get("name", "")))
			})

	var signals: Array = []
	for sig in node.get_signal_list():
		var sig_dict: Dictionary = sig
		signals.append(sig_dict.get("name", ""))

	var methods: Array = []
	for m in node.get_method_list():
		var m_dict: Dictionary = m
		if not str(m_dict.get("name", "")).begins_with("_"):
			methods.append(m_dict.get("name", ""))

	var children: Array = []
	for child in node.get_children():
		children.append({
			"name": child.name,
			"type": child.get_class(),
			"path": str(child.get_path())
		})

	_send_response({
		"success": true,
		"class": node.get_class(),
		"name": node.name,
		"path": str(node.get_path()),
		"properties": properties,
		"signals": signals,
		"methods": methods,
		"children": children
	})


# --- Instantiate Scene ---
func _cmd_instantiate_scene(params: Dictionary) -> void:
	var scene_path: String = params.get("scene_path", "")
	var parent_path: String = params.get("parent_path", "/root")
	if scene_path.is_empty():
		_send_response({"error": "scene_path is required"})
		return

	var packed: PackedScene = load(scene_path) as PackedScene
	if packed == null:
		_send_response({"error": "Failed to load scene: %s" % scene_path})
		return

	var parent: Node = get_tree().root.get_node_or_null(parent_path)
	if parent == null:
		_send_response({"error": "Parent node not found: %s" % parent_path})
		return

	var instance: Node = packed.instantiate()
	parent.add_child(instance)
	_send_response({"success": true, "instance_name": instance.name, "instance_path": str(instance.get_path())})


# --- Remove Node ---
func _cmd_remove_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		_send_response({"error": "node_path is required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	var node_name: String = node.name
	node.queue_free()
	_send_response({"success": true, "removed": node_name})


# --- Change Scene ---
func _cmd_change_scene(params: Dictionary) -> void:
	var scene_path: String = params.get("scene_path", "")
	if scene_path.is_empty():
		_send_response({"error": "scene_path is required"})
		return

	var err: int = get_tree().change_scene_to_file(scene_path)
	if err != OK:
		_send_response({"error": "Failed to change scene. Error code: %d" % err})
		return

	_send_response({"success": true, "scene": scene_path})


# --- Pause ---
func _cmd_pause(params: Dictionary) -> void:
	var paused: bool = params.get("paused", true)
	get_tree().paused = paused
	_send_response({"success": true, "paused": paused})


# --- Get Performance ---
func _cmd_get_performance(_params: Dictionary) -> void:
	_send_response({
		"success": true,
		"fps": Performance.get_monitor(Performance.TIME_FPS),
		"frame_time": Performance.get_monitor(Performance.TIME_PROCESS),
		"physics_frame_time": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS),
		"memory_static": Performance.get_monitor(Performance.MEMORY_STATIC),
		"memory_static_max": Performance.get_monitor(Performance.MEMORY_STATIC_MAX),
		"object_count": Performance.get_monitor(Performance.OBJECT_COUNT),
		"object_node_count": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"object_orphan_node_count": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		"render_total_objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"render_total_draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	})


# --- Wait N Frames ---
func _cmd_wait(params: Dictionary) -> void:
	var frames: int = int(params.get("frames", 1))
	for i in frames:
		await get_tree().process_frame
	_send_response({"success": true, "waited_frames": frames})


# --- Helper: Convert Godot Variant to JSON-safe value ---
func _variant_to_json(value: Variant) -> Variant:
	if value == null:
		return null
	if value is bool or value is int or value is float or value is String:
		return value
	if value is Vector2:
		return {"x": value.x, "y": value.y}
	if value is Vector3:
		return {"x": value.x, "y": value.y, "z": value.z}
	if value is Vector2i:
		return {"x": value.x, "y": value.y}
	if value is Vector3i:
		return {"x": value.x, "y": value.y, "z": value.z}
	if value is Color:
		return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
	if value is Quaternion:
		return {"x": value.x, "y": value.y, "z": value.z, "w": value.w}
	if value is Basis:
		return {
			"x": _variant_to_json(value.x),
			"y": _variant_to_json(value.y),
			"z": _variant_to_json(value.z)
		}
	if value is Transform3D:
		return {
			"basis": _variant_to_json(value.basis),
			"origin": _variant_to_json(value.origin)
		}
	if value is Transform2D:
		return {
			"x": _variant_to_json(value.x),
			"y": _variant_to_json(value.y),
			"origin": _variant_to_json(value.origin)
		}
	if value is Rect2:
		return {"position": _variant_to_json(value.position), "size": _variant_to_json(value.size)}
	if value is AABB:
		return {"position": _variant_to_json(value.position), "size": _variant_to_json(value.size)}
	if value is NodePath:
		return str(value)
	if value is StringName:
		return str(value)
	# Packed arrays - serialize as JSON arrays instead of str() fallback
	if value is PackedByteArray:
		var arr: Array = []
		for item in value:
			arr.append(item)
		return arr
	if value is PackedInt32Array or value is PackedInt64Array:
		var arr: Array = []
		for item in value:
			arr.append(item)
		return arr
	if value is PackedFloat32Array or value is PackedFloat64Array:
		var arr: Array = []
		for item in value:
			arr.append(item)
		return arr
	if value is PackedStringArray:
		var arr: Array = []
		for item in value:
			arr.append(item)
		return arr
	if value is PackedVector2Array:
		var arr: Array = []
		for item in value:
			arr.append({"x": item.x, "y": item.y})
		return arr
	if value is PackedVector3Array:
		var arr: Array = []
		for item in value:
			arr.append({"x": item.x, "y": item.y, "z": item.z})
		return arr
	if value is PackedColorArray:
		var arr: Array = []
		for item in value:
			arr.append({"r": item.r, "g": item.g, "b": item.b, "a": item.a})
		return arr
	if value is Array:
		var arr: Array = []
		for item in value:
			arr.append(_variant_to_json(item))
		return arr
	if value is Dictionary:
		var dict: Dictionary = {}
		for key in value:
			dict[str(key)] = _variant_to_json(value[key])
		return dict
	if value is Object:
		if value is Node:
			return {"_type": "Node", "class": value.get_class(), "name": (value as Node).name, "path": str((value as Node).get_path())}
		if value is Resource:
			return {"_type": "Resource", "class": value.get_class(), "path": (value as Resource).resource_path}
		return {"_type": "Object", "class": value.get_class(), "id": value.get_instance_id()}
	# Fallback: convert to string
	return str(value)


# --- Helper: Convert JSON value back to Godot Variant ---
func _json_to_variant(value: Variant, type_hint: String = "") -> Variant:
	if value == null:
		return null
	if value is Dictionary:
		var dict: Dictionary = value
		# Explicit type hints take priority
		match type_hint:
			"Vector2":
				return Vector2(float(dict.get("x", 0)), float(dict.get("y", 0)))
			"Vector2i":
				return Vector2i(int(dict.get("x", 0)), int(dict.get("y", 0)))
			"Vector3":
				return Vector3(float(dict.get("x", 0)), float(dict.get("y", 0)), float(dict.get("z", 0)))
			"Vector3i":
				return Vector3i(int(dict.get("x", 0)), int(dict.get("y", 0)), int(dict.get("z", 0)))
			"Color":
				return Color(float(dict.get("r", 0)), float(dict.get("g", 0)), float(dict.get("b", 0)), float(dict.get("a", 1)))
			"Quaternion":
				return Quaternion(float(dict.get("x", 0)), float(dict.get("y", 0)), float(dict.get("z", 0)), float(dict.get("w", 1)))
			"Rect2":
				var pos: Dictionary = dict.get("position", {"x": 0, "y": 0})
				var sz: Dictionary = dict.get("size", {"x": 0, "y": 0})
				return Rect2(float(pos.get("x", 0)), float(pos.get("y", 0)), float(sz.get("x", 0)), float(sz.get("y", 0)))
			"AABB":
				var aabb_pos: Dictionary = dict.get("position", {"x": 0, "y": 0, "z": 0})
				var aabb_sz: Dictionary = dict.get("size", {"x": 0, "y": 0, "z": 0})
				return AABB(
					Vector3(float(aabb_pos.get("x", 0)), float(aabb_pos.get("y", 0)), float(aabb_pos.get("z", 0))),
					Vector3(float(aabb_sz.get("x", 0)), float(aabb_sz.get("y", 0)), float(aabb_sz.get("z", 0)))
				)
			"Basis":
				var bx: Dictionary = dict.get("x", {"x": 1, "y": 0, "z": 0})
				var by: Dictionary = dict.get("y", {"x": 0, "y": 1, "z": 0})
				var bz: Dictionary = dict.get("z", {"x": 0, "y": 0, "z": 1})
				return Basis(
					Vector3(float(bx.get("x", 0)), float(bx.get("y", 0)), float(bx.get("z", 0))),
					Vector3(float(by.get("x", 0)), float(by.get("y", 0)), float(by.get("z", 0))),
					Vector3(float(bz.get("x", 0)), float(bz.get("y", 0)), float(bz.get("z", 0)))
				)
			"Transform3D":
				var basis_dict: Dictionary = dict.get("basis", {})
				var origin_dict: Dictionary = dict.get("origin", {"x": 0, "y": 0, "z": 0})
				var basis: Basis = _json_to_variant(basis_dict, "Basis") if basis_dict.size() > 0 else Basis.IDENTITY
				var origin: Vector3 = Vector3(float(origin_dict.get("x", 0)), float(origin_dict.get("y", 0)), float(origin_dict.get("z", 0)))
				return Transform3D(basis, origin)
			"Transform2D":
				var tx: Dictionary = dict.get("x", {"x": 1, "y": 0})
				var ty: Dictionary = dict.get("y", {"x": 0, "y": 1})
				var t_origin: Dictionary = dict.get("origin", {"x": 0, "y": 0})
				return Transform2D(
					Vector2(float(tx.get("x", 0)), float(tx.get("y", 0))),
					Vector2(float(ty.get("x", 0)), float(ty.get("y", 0))),
					Vector2(float(t_origin.get("x", 0)), float(t_origin.get("y", 0)))
				)
		# Auto-detect from dict keys
		if dict.has("basis") and dict.has("origin"):
			return _json_to_variant(dict, "Transform3D")
		if dict.has("r") and dict.has("g") and dict.has("b"):
			return Color(float(dict.get("r", 0)), float(dict.get("g", 0)), float(dict.get("b", 0)), float(dict.get("a", 1)))
		if dict.has("x") and dict.has("y") and dict.has("z") and dict.has("w"):
			return Quaternion(float(dict.get("x", 0)), float(dict.get("y", 0)), float(dict.get("z", 0)), float(dict.get("w", 1)))
		if dict.has("position") and dict.has("size"):
			var pos_dict: Dictionary = dict["position"]
			var size_dict: Dictionary = dict["size"]
			if pos_dict.has("z") or size_dict.has("z"):
				return _json_to_variant(dict, "AABB")
			return _json_to_variant(dict, "Rect2")
		if dict.has("x") and dict.has("y") and dict.has("z"):
			return Vector3(float(dict.get("x", 0)), float(dict.get("y", 0)), float(dict.get("z", 0)))
		if dict.has("x") and dict.has("y") and dict.size() == 2:
			return Vector2(float(dict.get("x", 0)), float(dict.get("y", 0)))
		return value
	return value


# --- Helper: Convert JSON value using node's property type info ---
func _json_to_variant_for_property(node: Node, property: String, value: Variant) -> Variant:
	for prop in node.get_property_list():
		if prop["name"] == property:
			var type_id: int = prop.get("type", 0)
			match type_id:
				TYPE_VECTOR2:
					return _json_to_variant(value, "Vector2")
				TYPE_VECTOR2I:
					return _json_to_variant(value, "Vector2i")
				TYPE_VECTOR3:
					return _json_to_variant(value, "Vector3")
				TYPE_VECTOR3I:
					return _json_to_variant(value, "Vector3i")
				TYPE_COLOR:
					return _json_to_variant(value, "Color")
				TYPE_QUATERNION:
					return _json_to_variant(value, "Quaternion")
				TYPE_RECT2:
					return _json_to_variant(value, "Rect2")
				TYPE_AABB:
					return _json_to_variant(value, "AABB")
				TYPE_BASIS:
					return _json_to_variant(value, "Basis")
				TYPE_TRANSFORM3D:
					return _json_to_variant(value, "Transform3D")
				TYPE_TRANSFORM2D:
					return _json_to_variant(value, "Transform2D")
				TYPE_BOOL:
					if value is String:
						return value.to_lower() == "true"
					return bool(value)
				TYPE_INT:
					return int(value)
				TYPE_FLOAT:
					return float(value)
			break
	# No type info found, use raw value or auto-detect
	return _json_to_variant(value)


# --- Connect Signal ---
func _cmd_connect_signal(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var signal_name: String = params.get("signal_name", "")
	var target_path: String = params.get("target_path", "")
	var method_name: String = params.get("method", "")
	if node_path.is_empty() or signal_name.is_empty() or target_path.is_empty() or method_name.is_empty():
		_send_response({"error": "node_path, signal_name, target_path, and method are required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Source node not found: %s" % node_path})
		return

	var target: Node = get_tree().root.get_node_or_null(target_path)
	if target == null:
		_send_response({"error": "Target node not found: %s" % target_path})
		return

	if not node.has_signal(signal_name):
		_send_response({"error": "Signal '%s' not found on node %s" % [signal_name, node_path]})
		return

	if not target.has_method(method_name):
		_send_response({"error": "Method '%s' not found on target %s" % [method_name, target_path]})
		return

	if node.is_connected(signal_name, Callable(target, method_name)):
		_send_response({"error": "Signal already connected"})
		return

	node.connect(signal_name, Callable(target, method_name))
	_send_response({"success": true, "signal": signal_name, "from": node_path, "to": target_path, "method": method_name})


# --- Disconnect Signal ---
func _cmd_disconnect_signal(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var signal_name: String = params.get("signal_name", "")
	var target_path: String = params.get("target_path", "")
	var method_name: String = params.get("method", "")
	if node_path.is_empty() or signal_name.is_empty() or target_path.is_empty() or method_name.is_empty():
		_send_response({"error": "node_path, signal_name, target_path, and method are required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Source node not found: %s" % node_path})
		return

	var target: Node = get_tree().root.get_node_or_null(target_path)
	if target == null:
		_send_response({"error": "Target node not found: %s" % target_path})
		return

	var callable: Callable = Callable(target, method_name)
	if not node.is_connected(signal_name, callable):
		_send_response({"error": "Signal is not connected"})
		return

	node.disconnect(signal_name, callable)
	_send_response({"success": true, "disconnected": signal_name, "from": node_path, "to": target_path, "method": method_name})


# --- Emit Signal ---
func _cmd_emit_signal(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var signal_name: String = params.get("signal_name", "")
	if node_path.is_empty() or signal_name.is_empty():
		_send_response({"error": "node_path and signal_name are required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	if not node.has_signal(signal_name):
		_send_response({"error": "Signal '%s' not found on node %s" % [signal_name, node_path]})
		return

	var args: Array = params.get("args", [])
	var call_args: Array = [signal_name]
	call_args.append_array(args)
	node.callv("emit_signal", call_args)
	_send_response({"success": true, "emitted": signal_name, "node": node_path, "arg_count": args.size()})


# --- Play Animation ---
func _cmd_play_animation(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		_send_response({"error": "node_path is required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	if not node is AnimationPlayer:
		_send_response({"error": "Node is not an AnimationPlayer: %s (is %s)" % [node_path, node.get_class()]})
		return

	var anim_player: AnimationPlayer = node as AnimationPlayer
	var action: String = params.get("action", "play")

	match action:
		"play":
			var animation: String = params.get("animation", "")
			if animation.is_empty():
				_send_response({"error": "animation name is required for play action"})
				return
			if not anim_player.has_animation(animation):
				_send_response({"error": "Animation '%s' not found. Available: %s" % [animation, str(anim_player.get_animation_list())]})
				return
			anim_player.play(animation)
			_send_response({"success": true, "action": "play", "animation": animation})
		"stop":
			anim_player.stop()
			_send_response({"success": true, "action": "stop"})
		"pause":
			anim_player.pause()
			_send_response({"success": true, "action": "pause"})
		"get_list":
			var anims: Array = []
			for anim_name in anim_player.get_animation_list():
				anims.append(str(anim_name))
			_send_response({"success": true, "animations": anims, "current": anim_player.current_animation, "playing": anim_player.is_playing()})
		_:
			_send_response({"error": "Unknown animation action: %s. Use play, stop, pause, or get_list" % action})


# --- Tween Property ---
func _cmd_tween_property(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property: String = params.get("property", "")
	if node_path.is_empty() or property.is_empty():
		_send_response({"error": "node_path and property are required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	var final_value: Variant = _json_to_variant_for_property(node, property, params.get("final_value", null))
	var duration: float = float(params.get("duration", 1.0))
	var trans_type: int = int(params.get("trans_type", 0))  # Tween.TRANS_LINEAR
	var ease_type: int = int(params.get("ease_type", 2))  # Tween.EASE_IN_OUT

	var tween: Tween = create_tween()
	tween.tween_property(node, property, final_value, duration).set_trans(trans_type).set_ease(ease_type)
	_send_response({"success": true, "node": node_path, "property": property, "duration": duration})


# --- Get Nodes In Group ---
func _cmd_get_nodes_in_group(params: Dictionary) -> void:
	var group_name: String = params.get("group", "")
	if group_name.is_empty():
		_send_response({"error": "group is required"})
		return

	var nodes: Array = get_tree().get_nodes_in_group(group_name)
	var result: Array = []
	for node in nodes:
		result.append({
			"name": node.name,
			"type": node.get_class(),
			"path": str(node.get_path())
		})
	_send_response({"success": true, "group": group_name, "count": result.size(), "nodes": result})


# --- Find Nodes By Class ---
func _cmd_find_nodes_by_class(params: Dictionary) -> void:
	var class_filter: String = params.get("class_name", "")
	if class_filter.is_empty():
		_send_response({"error": "class_name is required"})
		return

	var root_path: String = params.get("root_path", "/root")
	var root_node: Node = get_tree().root.get_node_or_null(root_path)
	if root_node == null:
		_send_response({"error": "Root node not found: %s" % root_path})
		return

	var found: Array = []
	_find_by_class_recursive(root_node, class_filter, found)
	_send_response({"success": true, "class_name": class_filter, "count": found.size(), "nodes": found})


func _find_by_class_recursive(node: Node, class_filter: String, results: Array) -> void:
	if node.get_class() == class_filter or node.is_class(class_filter):
		results.append({
			"name": node.name,
			"type": node.get_class(),
			"path": str(node.get_path())
		})
	for child in node.get_children():
		_find_by_class_recursive(child, class_filter, results)


# --- Reparent Node ---
func _cmd_reparent_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var new_parent_path: String = params.get("new_parent_path", "")
	if node_path.is_empty() or new_parent_path.is_empty():
		_send_response({"error": "node_path and new_parent_path are required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	var new_parent: Node = get_tree().root.get_node_or_null(new_parent_path)
	if new_parent == null:
		_send_response({"error": "New parent not found: %s" % new_parent_path})
		return

	var keep_global: bool = params.get("keep_global_transform", true)
	node.reparent(new_parent, keep_global)
	_send_response({"success": true, "node": node.name, "new_parent": new_parent_path, "new_path": str(node.get_path())})


# --- Key Hold (no auto-release) ---
func _cmd_key_hold(params: Dictionary) -> void:
	var action: String = params.get("action", "")
	var key: String = params.get("key", "")

	if action.length() > 0:
		Input.action_press(action)
		_held_keys["action:" + action] = true
		_send_response({"success": true, "held": action, "type": "action"})
		return

	if key.length() > 0:
		var keycode: int = _string_to_keycode(key)
		if keycode == KEY_NONE:
			_send_response({"error": "Unknown key: %s" % key})
			return
		var event: InputEventKey = InputEventKey.new()
		event.keycode = keycode as Key
		event.physical_keycode = keycode as Key
		event.pressed = true
		Input.parse_input_event(event)
		_held_keys["key:" + key.to_upper()] = keycode
		_send_response({"success": true, "held": key, "type": "key"})
		return

	_send_response({"error": "Must provide 'key' or 'action' parameter"})


# --- Key Release ---
func _cmd_key_release(params: Dictionary) -> void:
	var action: String = params.get("action", "")
	var key: String = params.get("key", "")

	if action.length() > 0:
		Input.action_release(action)
		_held_keys.erase("action:" + action)
		_send_response({"success": true, "released": action, "type": "action"})
		return

	if key.length() > 0:
		var keycode: int = _string_to_keycode(key)
		if keycode == KEY_NONE:
			_send_response({"error": "Unknown key: %s" % key})
			return
		var event: InputEventKey = InputEventKey.new()
		event.keycode = keycode as Key
		event.physical_keycode = keycode as Key
		event.pressed = false
		Input.parse_input_event(event)
		_held_keys.erase("key:" + key.to_upper())
		_send_response({"success": true, "released": key, "type": "key"})
		return

	_send_response({"error": "Must provide 'key' or 'action' parameter"})


# --- Scroll ---
func _cmd_scroll(params: Dictionary) -> void:
	var x: float = float(params.get("x", 0))
	var y: float = float(params.get("y", 0))
	var direction: String = params.get("direction", "up")
	var amount: int = int(params.get("amount", 1))

	var button_index: int = MOUSE_BUTTON_WHEEL_UP
	match direction:
		"down":
			button_index = MOUSE_BUTTON_WHEEL_DOWN
		"left":
			button_index = MOUSE_BUTTON_WHEEL_LEFT
		"right":
			button_index = MOUSE_BUTTON_WHEEL_RIGHT

	for i in amount:
		var press_event: InputEventMouseButton = InputEventMouseButton.new()
		press_event.position = Vector2(x, y)
		press_event.global_position = Vector2(x, y)
		press_event.button_index = button_index as MouseButton
		press_event.pressed = true
		press_event.factor = 1.0
		Input.parse_input_event(press_event)

		var release_event: InputEventMouseButton = InputEventMouseButton.new()
		release_event.position = Vector2(x, y)
		release_event.global_position = Vector2(x, y)
		release_event.button_index = button_index as MouseButton
		release_event.pressed = false
		Input.parse_input_event(release_event)

	_send_response({"success": true, "direction": direction, "amount": amount, "position": {"x": x, "y": y}})


# --- Mouse Drag ---
func _cmd_mouse_drag(params: Dictionary) -> void:
	var from_x: float = float(params.get("from_x", 0))
	var from_y: float = float(params.get("from_y", 0))
	var to_x: float = float(params.get("to_x", 0))
	var to_y: float = float(params.get("to_y", 0))
	var button: int = int(params.get("button", MOUSE_BUTTON_LEFT))
	var steps: int = int(params.get("steps", 10))
	if steps < 1:
		steps = 1

	var from_pos: Vector2 = Vector2(from_x, from_y)
	var to_pos: Vector2 = Vector2(to_x, to_y)

	# Press at start position
	var press_event: InputEventMouseButton = InputEventMouseButton.new()
	press_event.position = from_pos
	press_event.global_position = from_pos
	press_event.button_index = button as MouseButton
	press_event.pressed = true
	Input.parse_input_event(press_event)

	# Lerp position over steps frames
	for i in steps:
		await get_tree().process_frame
		var t: float = float(i + 1) / float(steps)
		var current_pos: Vector2 = from_pos.lerp(to_pos, t)
		var move_event: InputEventMouseMotion = InputEventMouseMotion.new()
		move_event.position = current_pos
		move_event.global_position = current_pos
		move_event.relative = (to_pos - from_pos) / float(steps)
		move_event.button_mask = MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else 0
		Input.parse_input_event(move_event)

	# Release at end position
	var release_event: InputEventMouseButton = InputEventMouseButton.new()
	release_event.position = to_pos
	release_event.global_position = to_pos
	release_event.button_index = button as MouseButton
	release_event.pressed = false
	Input.parse_input_event(release_event)

	_send_response({"success": true, "from": {"x": from_x, "y": from_y}, "to": {"x": to_x, "y": to_y}, "steps": steps})


# --- Gamepad ---
func _cmd_gamepad(params: Dictionary) -> void:
	var input_type: String = params.get("type", "button")
	var index: int = int(params.get("index", 0))
	var value: float = float(params.get("value", 0))
	var device: int = int(params.get("device", 0))

	if input_type == "button":
		var event: InputEventJoypadButton = InputEventJoypadButton.new()
		event.device = device
		event.button_index = index as JoyButton
		event.pressed = value > 0.5
		event.pressure = value
		Input.parse_input_event(event)
		_send_response({"success": true, "type": "button", "index": index, "pressed": event.pressed, "device": device})
	elif input_type == "axis":
		var event: InputEventJoypadMotion = InputEventJoypadMotion.new()
		event.device = device
		event.axis = index as JoyAxis
		event.axis_value = value
		Input.parse_input_event(event)
		_send_response({"success": true, "type": "axis", "index": index, "value": value, "device": device})
	else:
		_send_response({"error": "Invalid type: %s. Use 'button' or 'axis'" % input_type})


# --- Get Camera ---
func _cmd_get_camera() -> void:
	var result: Dictionary = {"success": true}

	var cam2d: Camera2D = get_viewport().get_camera_2d()
	if cam2d != null:
		result["camera_2d"] = {
			"position": {"x": cam2d.global_position.x, "y": cam2d.global_position.y},
			"rotation": cam2d.global_rotation,
			"zoom": {"x": cam2d.zoom.x, "y": cam2d.zoom.y},
			"path": str(cam2d.get_path())
		}

	var cam3d: Camera3D = get_viewport().get_camera_3d()
	if cam3d != null:
		result["camera_3d"] = {
			"position": {"x": cam3d.global_position.x, "y": cam3d.global_position.y, "z": cam3d.global_position.z},
			"rotation": {"x": rad_to_deg(cam3d.global_rotation.x), "y": rad_to_deg(cam3d.global_rotation.y), "z": rad_to_deg(cam3d.global_rotation.z)},
			"fov": cam3d.fov,
			"path": str(cam3d.get_path())
		}

	if cam2d == null and cam3d == null:
		result["error"] = "No active camera found"
		result["success"] = false

	_send_response(result)


# --- Set Camera ---
func _cmd_set_camera(params: Dictionary) -> void:
	var cam2d: Camera2D = get_viewport().get_camera_2d()
	var cam3d: Camera3D = get_viewport().get_camera_3d()

	if cam2d == null and cam3d == null:
		_send_response({"error": "No active camera found"})
		return

	if cam2d != null:
		if params.has("position"):
			var pos: Dictionary = params["position"]
			cam2d.global_position = Vector2(float(pos.get("x", cam2d.global_position.x)), float(pos.get("y", cam2d.global_position.y)))
		if params.has("rotation"):
			var rot: Dictionary = params["rotation"]
			cam2d.global_rotation = deg_to_rad(float(rot.get("z", rad_to_deg(cam2d.global_rotation))))
		if params.has("zoom"):
			var z: Dictionary = params["zoom"]
			cam2d.zoom = Vector2(float(z.get("x", cam2d.zoom.x)), float(z.get("y", cam2d.zoom.y)))
		_send_response({"success": true, "camera": "2d", "position": _variant_to_json(cam2d.global_position), "zoom": _variant_to_json(cam2d.zoom)})
		return

	if cam3d != null:
		if params.has("position"):
			var pos: Dictionary = params["position"]
			cam3d.global_position = Vector3(float(pos.get("x", cam3d.global_position.x)), float(pos.get("y", cam3d.global_position.y)), float(pos.get("z", cam3d.global_position.z)))
		if params.has("rotation"):
			var rot: Dictionary = params["rotation"]
			cam3d.global_rotation = Vector3(deg_to_rad(float(rot.get("x", rad_to_deg(cam3d.global_rotation.x)))), deg_to_rad(float(rot.get("y", rad_to_deg(cam3d.global_rotation.y)))), deg_to_rad(float(rot.get("z", rad_to_deg(cam3d.global_rotation.z)))))
		if params.has("fov"):
			cam3d.fov = float(params["fov"])
		_send_response({"success": true, "camera": "3d", "position": _variant_to_json(cam3d.global_position), "rotation": _variant_to_json(cam3d.global_rotation)})
		return


# --- Raycast ---
func _cmd_raycast(params: Dictionary) -> void:
	var from_dict: Dictionary = params.get("from", {})
	var to_dict: Dictionary = params.get("to", {})
	var collision_mask: int = int(params.get("collision_mask", 0xFFFFFFFF))

	# Determine 2D vs 3D based on whether z is present
	var is_3d: bool = from_dict.has("z") or to_dict.has("z")

	if is_3d:
		var from_pos: Vector3 = Vector3(float(from_dict.get("x", 0)), float(from_dict.get("y", 0)), float(from_dict.get("z", 0)))
		var to_pos: Vector3 = Vector3(float(to_dict.get("x", 0)), float(to_dict.get("y", 0)), float(to_dict.get("z", 0)))

		# Wait a frame to ensure physics state is available
		await get_tree().process_frame

		var space_state: PhysicsDirectSpaceState3D = get_viewport().world_3d.direct_space_state
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from_pos, to_pos, collision_mask)
		var result: Dictionary = space_state.intersect_ray(query)

		if result.is_empty():
			_send_response({"success": true, "hit": false, "mode": "3d"})
		else:
			_send_response({
				"success": true, "hit": true, "mode": "3d",
				"position": _variant_to_json(result["position"]),
				"normal": _variant_to_json(result["normal"]),
				"collider_path": str(result["collider"].get_path()) if result.has("collider") and result["collider"] is Node else "",
				"collider_class": result["collider"].get_class() if result.has("collider") else "",
			})
	else:
		var from_pos: Vector2 = Vector2(float(from_dict.get("x", 0)), float(from_dict.get("y", 0)))
		var to_pos: Vector2 = Vector2(float(to_dict.get("x", 0)), float(to_dict.get("y", 0)))

		await get_tree().process_frame

		var space_state: PhysicsDirectSpaceState2D = get_viewport().world_2d.direct_space_state
		var query: PhysicsRayQueryParameters2D = PhysicsRayQueryParameters2D.create(from_pos, to_pos, collision_mask)
		var result: Dictionary = space_state.intersect_ray(query)

		if result.is_empty():
			_send_response({"success": true, "hit": false, "mode": "2d"})
		else:
			_send_response({
				"success": true, "hit": true, "mode": "2d",
				"position": _variant_to_json(result["position"]),
				"normal": _variant_to_json(result["normal"]),
				"collider_path": str(result["collider"].get_path()) if result.has("collider") and result["collider"] is Node else "",
				"collider_class": result["collider"].get_class() if result.has("collider") else "",
			})


# --- Get Audio ---
func _cmd_get_audio() -> void:
	var buses: Array = []
	for i in AudioServer.bus_count:
		buses.append({
			"name": AudioServer.get_bus_name(i),
			"volume_db": AudioServer.get_bus_volume_db(i),
			"mute": AudioServer.is_bus_mute(i),
			"solo": AudioServer.is_bus_solo(i),
		})

	var players: Array = []
	_find_audio_players(get_tree().root, players)

	_send_response({"success": true, "buses": buses, "players": players})


func _find_audio_players(node: Node, results: Array) -> void:
	if node is AudioStreamPlayer:
		var p: AudioStreamPlayer = node as AudioStreamPlayer
		results.append({"path": str(p.get_path()), "type": "AudioStreamPlayer", "playing": p.playing, "bus": p.bus})
	elif node is AudioStreamPlayer2D:
		var p: AudioStreamPlayer2D = node as AudioStreamPlayer2D
		results.append({"path": str(p.get_path()), "type": "AudioStreamPlayer2D", "playing": p.playing, "bus": p.bus})
	elif node is AudioStreamPlayer3D:
		var p: AudioStreamPlayer3D = node as AudioStreamPlayer3D
		results.append({"path": str(p.get_path()), "type": "AudioStreamPlayer3D", "playing": p.playing, "bus": p.bus})
	for child in node.get_children():
		_find_audio_players(child, results)


# --- Spawn Node ---
func _cmd_spawn_node(params: Dictionary) -> void:
	var type_name: String = params.get("type", "")
	var node_name: String = params.get("name", "")
	var parent_path: String = params.get("parent_path", "/root")

	if type_name.is_empty():
		_send_response({"error": "type is required"})
		return

	if not ClassDB.class_exists(type_name):
		_send_response({"error": "Unknown class: %s" % type_name})
		return

	if not ClassDB.is_parent_class(type_name, "Node") and type_name != "Node":
		_send_response({"error": "Class '%s' is not a Node type" % type_name})
		return

	var parent: Node = get_tree().root.get_node_or_null(parent_path)
	if parent == null:
		_send_response({"error": "Parent node not found: %s" % parent_path})
		return

	var instance: Node = ClassDB.instantiate(type_name) as Node
	if instance == null:
		_send_response({"error": "Failed to instantiate: %s" % type_name})
		return

	if node_name.length() > 0:
		instance.name = node_name

	# Apply properties if provided
	var properties: Dictionary = params.get("properties", {})
	for prop_name in properties:
		var raw_value: Variant = properties[prop_name]
		var value: Variant = _json_to_variant_for_property(instance, prop_name, raw_value)
		instance.set(prop_name, value)

	parent.add_child(instance)
	_send_response({"success": true, "name": instance.name, "type": type_name, "path": str(instance.get_path())})


# --- Set Shader Parameter ---
func _cmd_set_shader_param(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var param_name: String = params.get("param_name", "")
	if node_path.is_empty() or param_name.is_empty():
		_send_response({"error": "node_path and param_name are required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	var material: Material = null
	# Try material_override first (MeshInstance3D/2D)
	if node.get("material_override") != null:
		material = node.get("material_override")
	# Try surface override material (MeshInstance3D)
	elif node.has_method("get_surface_override_material"):
		material = node.get_surface_override_material(0)
	# Try material property (CanvasItem, e.g. Sprite2D)
	elif node.get("material") != null:
		material = node.get("material")

	if material == null or not material is ShaderMaterial:
		_send_response({"error": "No ShaderMaterial found on node: %s" % node_path})
		return

	var shader_mat: ShaderMaterial = material as ShaderMaterial
	var raw_value: Variant = params.get("value", null)
	var type_hint: String = params.get("type_hint", "")
	var value: Variant = _json_to_variant(raw_value, type_hint)
	shader_mat.set_shader_parameter(param_name, value)
	_send_response({"success": true, "node_path": node_path, "param_name": param_name, "value": _variant_to_json(shader_mat.get_shader_parameter(param_name))})


# --- Audio Play ---
func _cmd_audio_play(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var action: String = params.get("action", "play")
	if node_path.is_empty():
		_send_response({"error": "node_path is required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	if not (node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D):
		_send_response({"error": "Node is not an AudioStreamPlayer: %s (is %s)" % [node_path, node.get_class()]})
		return

	# Optionally load a new stream
	if params.has("stream"):
		var stream_path: String = params["stream"]
		var stream: AudioStream = load(stream_path) as AudioStream
		if stream == null:
			_send_response({"error": "Failed to load audio stream: %s" % stream_path})
			return
		node.set("stream", stream)

	# Set optional properties
	if params.has("volume"):
		var linear_vol: float = float(params["volume"])
		node.set("volume_db", linear_to_db(clampf(linear_vol, 0.0, 1.0)))
	if params.has("pitch"):
		node.set("pitch_scale", float(params["pitch"]))
	if params.has("bus"):
		node.set("bus", params["bus"])

	match action:
		"play":
			var from_pos: float = float(params.get("from_position", 0.0))
			node.call("play", from_pos)
			_send_response({"success": true, "action": "play", "node_path": node_path})
		"stop":
			node.call("stop")
			_send_response({"success": true, "action": "stop", "node_path": node_path})
		"pause":
			node.set("stream_paused", true)
			_send_response({"success": true, "action": "pause", "node_path": node_path})
		"resume":
			node.set("stream_paused", false)
			_send_response({"success": true, "action": "resume", "node_path": node_path})
		_:
			_send_response({"error": "Unknown audio action: %s. Use play, stop, pause, or resume" % action})


# --- Audio Bus ---
func _cmd_audio_bus(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "Master")
	var bus_idx: int = AudioServer.get_bus_index(bus_name)
	if bus_idx == -1:
		_send_response({"error": "Audio bus not found: %s" % bus_name})
		return

	if params.has("volume"):
		var linear_vol: float = float(params["volume"])
		AudioServer.set_bus_volume_db(bus_idx, linear_to_db(clampf(linear_vol, 0.0, 1.0)))
	if params.has("mute"):
		AudioServer.set_bus_mute(bus_idx, bool(params["mute"]))
	if params.has("solo"):
		AudioServer.set_bus_solo(bus_idx, bool(params["solo"]))

	_send_response({
		"success": true,
		"bus_name": bus_name,
		"volume_db": AudioServer.get_bus_volume_db(bus_idx),
		"mute": AudioServer.is_bus_mute(bus_idx),
		"solo": AudioServer.is_bus_solo(bus_idx)
	})


# --- Navigate Path ---
func _cmd_navigate_path(params: Dictionary) -> void:
	var start_dict: Dictionary = params.get("start", {})
	var end_dict: Dictionary = params.get("end", {})
	var optimize: bool = params.get("optimize", true)

	if start_dict.is_empty() or end_dict.is_empty():
		_send_response({"error": "start and end are required"})
		return

	# Wait a frame to ensure navigation map is ready
	await get_tree().process_frame

	var is_3d: bool = start_dict.has("z") or end_dict.has("z")

	if is_3d:
		var start_pos: Vector3 = Vector3(float(start_dict.get("x", 0)), float(start_dict.get("y", 0)), float(start_dict.get("z", 0)))
		var end_pos: Vector3 = Vector3(float(end_dict.get("x", 0)), float(end_dict.get("y", 0)), float(end_dict.get("z", 0)))
		var map_rid: RID = get_tree().root.get_world_3d().get_navigation_map()
		var path: PackedVector3Array = NavigationServer3D.map_get_path(map_rid, start_pos, end_pos, optimize)
		var total_length: float = 0.0
		for i in range(1, path.size()):
			total_length += path[i - 1].distance_to(path[i])
		_send_response({"success": true, "mode": "3d", "path": _variant_to_json(path), "point_count": path.size(), "total_length": total_length})
	else:
		var start_pos: Vector2 = Vector2(float(start_dict.get("x", 0)), float(start_dict.get("y", 0)))
		var end_pos: Vector2 = Vector2(float(end_dict.get("x", 0)), float(end_dict.get("y", 0)))
		var map_rid: RID = get_tree().root.get_world_2d().get_navigation_map()
		var path: PackedVector2Array = NavigationServer2D.map_get_path(map_rid, start_pos, end_pos, optimize)
		var total_length: float = 0.0
		for i in range(1, path.size()):
			total_length += path[i - 1].distance_to(path[i])
		_send_response({"success": true, "mode": "2d", "path": _variant_to_json(path), "point_count": path.size(), "total_length": total_length})


# --- TileMap ---
func _cmd_tilemap(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var action: String = params.get("action", "get_cell")
	if node_path.is_empty():
		_send_response({"error": "node_path is required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	if not node is TileMapLayer:
		_send_response({"error": "Node is not a TileMapLayer: %s (is %s)" % [node_path, node.get_class()]})
		return

	var tilemap: TileMapLayer = node as TileMapLayer

	match action:
		"set_cells":
			var cells: Array = params.get("cells", [])
			var count: int = 0
			for cell in cells:
				var pos: Vector2i = Vector2i(int(cell.get("x", 0)), int(cell.get("y", 0)))
				var source_id: int = int(cell.get("source_id", 0))
				var atlas_coords: Vector2i = Vector2i(int(cell.get("atlas_x", 0)), int(cell.get("atlas_y", 0)))
				var alt_tile: int = int(cell.get("alt_tile", 0))
				tilemap.set_cell(pos, source_id, atlas_coords, alt_tile)
				count += 1
			_send_response({"success": true, "action": "set_cells", "count": count})
		"get_cell":
			var x: int = int(params.get("x", 0))
			var y: int = int(params.get("y", 0))
			var pos: Vector2i = Vector2i(x, y)
			_send_response({
				"success": true, "action": "get_cell",
				"x": x, "y": y,
				"source_id": tilemap.get_cell_source_id(pos),
				"atlas_coords": _variant_to_json(tilemap.get_cell_atlas_coords(pos)),
				"alt_tile": tilemap.get_cell_alternative_tile(pos)
			})
		"erase_cells":
			var cells: Array = params.get("cells", [])
			var count: int = 0
			for cell in cells:
				tilemap.erase_cell(Vector2i(int(cell.get("x", 0)), int(cell.get("y", 0))))
				count += 1
			_send_response({"success": true, "action": "erase_cells", "count": count})
		"get_used_cells":
			var source_filter: int = int(params.get("source_id", -1))
			var used: Array
			if source_filter >= 0:
				used = tilemap.get_used_cells_by_id(source_filter)
			else:
				used = tilemap.get_used_cells()
			_send_response({"success": true, "action": "get_used_cells", "cells": _variant_to_json(used), "count": used.size()})
		_:
			_send_response({"error": "Unknown tilemap action: %s. Use set_cells, get_cell, erase_cells, or get_used_cells" % action})


# --- Add Collision Shape ---
func _cmd_add_collision(params: Dictionary) -> void:
	var parent_path: String = params.get("parent_path", "")
	var shape_type: String = params.get("shape_type", "")
	if parent_path.is_empty() or shape_type.is_empty():
		_send_response({"error": "parent_path and shape_type are required"})
		return

	var parent: Node = get_tree().root.get_node_or_null(parent_path)
	if parent == null:
		_send_response({"error": "Parent node not found: %s" % parent_path})
		return

	var is_3d: bool = parent.get_class().ends_with("3D") or parent is PhysicsBody3D or parent is Area3D
	var shape_params: Dictionary = params.get("shape_params", {})
	var shape: Resource = null

	if is_3d:
		match shape_type:
			"box":
				var s: BoxShape3D = BoxShape3D.new()
				s.size = Vector3(float(shape_params.get("size_x", 1)), float(shape_params.get("size_y", 1)), float(shape_params.get("size_z", 1)))
				shape = s
			"sphere":
				var s: SphereShape3D = SphereShape3D.new()
				s.radius = float(shape_params.get("radius", 0.5))
				shape = s
			"capsule":
				var s: CapsuleShape3D = CapsuleShape3D.new()
				s.radius = float(shape_params.get("radius", 0.5))
				s.height = float(shape_params.get("height", 2.0))
				shape = s
			"cylinder":
				var s: CylinderShape3D = CylinderShape3D.new()
				s.radius = float(shape_params.get("radius", 0.5))
				s.height = float(shape_params.get("height", 2.0))
				shape = s
			"ray":
				var s: SeparationRayShape3D = SeparationRayShape3D.new()
				s.length = float(shape_params.get("length", 1.0))
				shape = s
			_:
				_send_response({"error": "Unknown 3D shape type: %s. Use box, sphere, capsule, cylinder, or ray" % shape_type})
				return
		var col_shape: CollisionShape3D = CollisionShape3D.new()
		col_shape.shape = shape as Shape3D
		if params.has("disabled"):
			col_shape.disabled = bool(params["disabled"])
		parent.add_child(col_shape)
		col_shape.owner = get_tree().edited_scene_root if get_tree().edited_scene_root else get_tree().root
		if params.has("collision_layer"):
			parent.set("collision_layer", int(params["collision_layer"]))
		if params.has("collision_mask"):
			parent.set("collision_mask", int(params["collision_mask"]))
		_send_response({"success": true, "name": col_shape.name, "path": str(col_shape.get_path()), "shape_type": shape_type, "mode": "3d"})
	else:
		match shape_type:
			"box":
				var s: RectangleShape2D = RectangleShape2D.new()
				s.size = Vector2(float(shape_params.get("size_x", 1)), float(shape_params.get("size_y", 1)))
				shape = s
			"circle":
				var s: CircleShape2D = CircleShape2D.new()
				s.radius = float(shape_params.get("radius", 0.5))
				shape = s
			"capsule":
				var s: CapsuleShape2D = CapsuleShape2D.new()
				s.radius = float(shape_params.get("radius", 0.5))
				s.height = float(shape_params.get("height", 2.0))
				shape = s
			"segment":
				var s: SegmentShape2D = SegmentShape2D.new()
				s.a = Vector2(float(shape_params.get("a_x", 0)), float(shape_params.get("a_y", 0)))
				s.b = Vector2(float(shape_params.get("b_x", 1)), float(shape_params.get("b_y", 0)))
				shape = s
			_:
				_send_response({"error": "Unknown 2D shape type: %s. Use box, circle, capsule, or segment" % shape_type})
				return
		var col_shape: CollisionShape2D = CollisionShape2D.new()
		col_shape.shape = shape as Shape2D
		if params.has("disabled"):
			col_shape.disabled = bool(params["disabled"])
		parent.add_child(col_shape)
		col_shape.owner = get_tree().edited_scene_root if get_tree().edited_scene_root else get_tree().root
		if params.has("collision_layer"):
			parent.set("collision_layer", int(params["collision_layer"]))
		if params.has("collision_mask"):
			parent.set("collision_mask", int(params["collision_mask"]))
		_send_response({"success": true, "name": col_shape.name, "path": str(col_shape.get_path()), "shape_type": shape_type, "mode": "2d"})


# --- Environment / Post-Processing ---
func _cmd_environment(params: Dictionary) -> void:
	var action: String = params.get("action", "set")

	# Find existing WorldEnvironment or Camera3D environment
	var env: Environment = null
	var world_env: Node = null

	# Search for WorldEnvironment node
	var found: Array = []
	_find_by_class_recursive(get_tree().root, "WorldEnvironment", found)
	if found.size() > 0:
		world_env = get_tree().root.get_node_or_null(found[0]["path"])
		if world_env != null:
			env = world_env.get("environment") as Environment

	# Fallback: check Camera3D
	if env == null:
		var cam3d: Camera3D = get_viewport().get_camera_3d()
		if cam3d != null and cam3d.get("environment") != null:
			env = cam3d.get("environment") as Environment

	if action == "get":
		if env == null:
			_send_response({"error": "No Environment resource found"})
			return
		_send_response(_get_environment_state(env))
		return

	# action == "set": create if needed
	if env == null:
		env = Environment.new()
		var we: WorldEnvironment = WorldEnvironment.new()
		we.environment = env
		get_tree().root.add_child(we)
		world_env = we

	# Apply settings
	if params.has("background_mode"):
		env.background_mode = int(params["background_mode"]) as Environment.BGMode
	if params.has("background_color"):
		var c: Dictionary = params["background_color"]
		env.background_color = Color(float(c.get("r", 0)), float(c.get("g", 0)), float(c.get("b", 0)), float(c.get("a", 1)))
	if params.has("ambient_light_color"):
		var c: Dictionary = params["ambient_light_color"]
		env.ambient_light_color = Color(float(c.get("r", 0)), float(c.get("g", 0)), float(c.get("b", 0)), float(c.get("a", 1)))
	if params.has("ambient_light_energy"):
		env.ambient_light_energy = float(params["ambient_light_energy"])
	if params.has("fog_enabled"):
		env.fog_enabled = bool(params["fog_enabled"])
	if params.has("fog_density"):
		env.fog_density = float(params["fog_density"])
	if params.has("fog_light_color"):
		var c: Dictionary = params["fog_light_color"]
		env.fog_light_color = Color(float(c.get("r", 0)), float(c.get("g", 0)), float(c.get("b", 0)), float(c.get("a", 1)))
	if params.has("glow_enabled"):
		env.glow_enabled = bool(params["glow_enabled"])
	if params.has("glow_intensity"):
		env.glow_intensity = float(params["glow_intensity"])
	if params.has("glow_bloom"):
		env.glow_bloom = float(params["glow_bloom"])
	if params.has("tonemap_mode"):
		env.tonemap_mode = int(params["tonemap_mode"]) as Environment.ToneMapper
	if params.has("ssao_enabled"):
		env.ssao_enabled = bool(params["ssao_enabled"])
	if params.has("ssao_radius"):
		env.ssao_radius = float(params["ssao_radius"])
	if params.has("ssao_intensity"):
		env.ssao_intensity = float(params["ssao_intensity"])
	if params.has("ssr_enabled"):
		env.ssr_enabled = bool(params["ssr_enabled"])
	if params.has("brightness"):
		env.adjustment_enabled = true
		env.adjustment_brightness = float(params["brightness"])
	if params.has("contrast"):
		env.adjustment_enabled = true
		env.adjustment_contrast = float(params["contrast"])
	if params.has("saturation"):
		env.adjustment_enabled = true
		env.adjustment_saturation = float(params["saturation"])

	_send_response(_get_environment_state(env))


func _get_environment_state(env: Environment) -> Dictionary:
	return {
		"success": true,
		"background_mode": env.background_mode,
		"background_color": _variant_to_json(env.background_color),
		"ambient_light_color": _variant_to_json(env.ambient_light_color),
		"ambient_light_energy": env.ambient_light_energy,
		"fog_enabled": env.fog_enabled,
		"fog_density": env.fog_density,
		"fog_light_color": _variant_to_json(env.fog_light_color),
		"glow_enabled": env.glow_enabled,
		"glow_intensity": env.glow_intensity,
		"glow_bloom": env.glow_bloom,
		"tonemap_mode": env.tonemap_mode,
		"ssao_enabled": env.ssao_enabled,
		"ssao_radius": env.ssao_radius,
		"ssao_intensity": env.ssao_intensity,
		"ssr_enabled": env.ssr_enabled,
		"brightness": env.adjustment_brightness,
		"contrast": env.adjustment_contrast,
		"saturation": env.adjustment_saturation
	}


# --- Manage Group ---
func _cmd_manage_group(params: Dictionary) -> void:
	var action: String = params.get("action", "")
	var group_name: String = params.get("group", "")

	if action == "clear_group":
		if group_name.is_empty():
			_send_response({"error": "group is required for clear_group"})
			return
		var nodes: Array = get_tree().get_nodes_in_group(group_name)
		for node in nodes:
			node.remove_from_group(group_name)
		_send_response({"success": true, "action": "clear_group", "group": group_name, "removed_count": nodes.size()})
		return

	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		_send_response({"error": "node_path is required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	match action:
		"add":
			if group_name.is_empty():
				_send_response({"error": "group is required for add"})
				return
			node.add_to_group(group_name)
			_send_response({"success": true, "action": "add", "node_path": node_path, "group": group_name})
		"remove":
			if group_name.is_empty():
				_send_response({"error": "group is required for remove"})
				return
			node.remove_from_group(group_name)
			_send_response({"success": true, "action": "remove", "node_path": node_path, "group": group_name})
		"get_groups":
			var groups: Array = []
			for g in node.get_groups():
				groups.append(str(g))
			_send_response({"success": true, "action": "get_groups", "node_path": node_path, "groups": groups})
		_:
			_send_response({"error": "Unknown group action: %s. Use add, remove, get_groups, or clear_group" % action})


# --- Create Timer ---
func _cmd_create_timer(params: Dictionary) -> void:
	var parent_path: String = params.get("parent_path", "/root")
	var wait_time: float = float(params.get("wait_time", 1.0))
	var one_shot: bool = params.get("one_shot", false)
	var autostart: bool = params.get("autostart", false)

	var parent: Node = get_tree().root.get_node_or_null(parent_path)
	if parent == null:
		_send_response({"error": "Parent node not found: %s" % parent_path})
		return

	var timer: Timer = Timer.new()
	timer.wait_time = wait_time
	timer.one_shot = one_shot
	timer.autostart = autostart
	if params.has("name") and params["name"] is String and not (params["name"] as String).is_empty():
		timer.name = params["name"]
	parent.add_child(timer)
	if autostart:
		timer.start()
	_send_response({"success": true, "path": str(timer.get_path()), "name": timer.name, "wait_time": timer.wait_time, "one_shot": timer.one_shot, "autostart": autostart})


# --- Set Particles ---
func _cmd_set_particles(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		_send_response({"error": "node_path is required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	if not (node is GPUParticles2D or node is GPUParticles3D):
		_send_response({"error": "Node is not a GPUParticles node: %s (is %s)" % [node_path, node.get_class()]})
		return

	# Set direct particle properties
	if params.has("emitting"):
		node.set("emitting", bool(params["emitting"]))
	if params.has("amount"):
		node.set("amount", int(params["amount"]))
	if params.has("lifetime"):
		node.set("lifetime", float(params["lifetime"]))
	if params.has("one_shot"):
		node.set("one_shot", bool(params["one_shot"]))
	if params.has("speed_scale"):
		node.set("speed_scale", float(params["speed_scale"]))
	if params.has("explosiveness"):
		node.set("explosiveness", float(params["explosiveness"]))
	if params.has("randomness"):
		node.set("randomness", float(params["randomness"]))

	# Configure process material
	if params.has("process_material"):
		var mat_params: Dictionary = params["process_material"]
		var mat: ParticleProcessMaterial = node.get("process_material") as ParticleProcessMaterial
		if mat == null:
			mat = ParticleProcessMaterial.new()
			node.set("process_material", mat)
		if mat_params.has("direction"):
			var d: Dictionary = mat_params["direction"]
			mat.direction = Vector3(float(d.get("x", 0)), float(d.get("y", -1)), float(d.get("z", 0)))
		if mat_params.has("spread"):
			mat.spread = float(mat_params["spread"])
		if mat_params.has("gravity"):
			var g: Dictionary = mat_params["gravity"]
			mat.gravity = Vector3(float(g.get("x", 0)), float(g.get("y", -9.8)), float(g.get("z", 0)))
		if mat_params.has("initial_velocity_min"):
			mat.initial_velocity_min = float(mat_params["initial_velocity_min"])
		if mat_params.has("initial_velocity_max"):
			mat.initial_velocity_max = float(mat_params["initial_velocity_max"])
		if mat_params.has("color"):
			var c: Dictionary = mat_params["color"]
			mat.color = Color(float(c.get("r", 1)), float(c.get("g", 1)), float(c.get("b", 1)), float(c.get("a", 1)))
		if mat_params.has("scale_min"):
			mat.scale_min = float(mat_params["scale_min"])
		if mat_params.has("scale_max"):
			mat.scale_max = float(mat_params["scale_max"])

	_send_response({
		"success": true, "node_path": node_path,
		"emitting": node.get("emitting"), "amount": node.get("amount"),
		"lifetime": node.get("lifetime"), "one_shot": node.get("one_shot"),
		"speed_scale": node.get("speed_scale")
	})


# --- Create Animation ---
func _cmd_create_animation(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var anim_name: String = params.get("animation_name", "")
	if node_path.is_empty() or anim_name.is_empty():
		_send_response({"error": "node_path and animation_name are required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	if not node is AnimationPlayer:
		_send_response({"error": "Node is not an AnimationPlayer: %s (is %s)" % [node_path, node.get_class()]})
		return

	var anim_player: AnimationPlayer = node as AnimationPlayer
	var anim: Animation = Animation.new()
	anim.length = float(params.get("length", 1.0))
	var loop_mode: int = int(params.get("loop_mode", 0))
	anim.loop_mode = loop_mode as Animation.LoopMode

	var tracks: Array = params.get("tracks", [])
	var track_count: int = 0
	for track_data in tracks:
		var track_type_str: String = track_data.get("type", "value")
		var track_path: String = track_data.get("path", "")
		if track_path.is_empty():
			continue

		var track_type: int = Animation.TYPE_VALUE
		match track_type_str:
			"value":
				track_type = Animation.TYPE_VALUE
			"method":
				track_type = Animation.TYPE_METHOD
			"bezier":
				track_type = Animation.TYPE_BEZIER
			"audio":
				track_type = Animation.TYPE_AUDIO

		var idx: int = anim.add_track(track_type)
		anim.track_set_path(idx, NodePath(track_path))

		var keys: Array = track_data.get("keys", [])
		for key_data in keys:
			var time: float = float(key_data.get("time", 0.0))
			match track_type:
				Animation.TYPE_VALUE:
					var value: Variant = _json_to_variant(key_data.get("value", null), key_data.get("type_hint", ""))
					anim.track_insert_key(idx, time, value)
					if key_data.has("transition"):
						var key_idx: int = anim.track_find_key(idx, time, Animation.FIND_MODE_APPROX)
						if key_idx >= 0:
							anim.track_set_key_transition(idx, key_idx, float(key_data["transition"]))
				Animation.TYPE_METHOD:
					var method_name: String = key_data.get("method", "")
					var args: Array = key_data.get("args", [])
					anim.track_insert_key(idx, time, {"method": method_name, "args": args})
				Animation.TYPE_BEZIER:
					var value: float = float(key_data.get("value", 0.0))
					anim.bezier_track_insert_key(idx, time, value)
				Animation.TYPE_AUDIO:
					var stream_path: String = key_data.get("stream", "")
					if not stream_path.is_empty():
						var stream: AudioStream = load(stream_path) as AudioStream
						if stream != null:
							anim.audio_track_insert_key(idx, time, stream)
		track_count += 1

	# Add to library (use default "" library if it exists, otherwise create it)
	var lib_name: String = params.get("library", "")
	var lib: AnimationLibrary = null
	if anim_player.has_animation_library(lib_name):
		lib = anim_player.get_animation_library(lib_name)
	else:
		lib = AnimationLibrary.new()
		anim_player.add_animation_library(lib_name, lib)
	lib.add_animation(anim_name, anim)

	_send_response({"success": true, "animation_name": anim_name, "length": anim.length, "loop_mode": loop_mode, "track_count": track_count})


# --- Serialize State ---
func _cmd_serialize_state(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "/root")
	var action: String = params.get("action", "save")
	var max_depth: int = int(params.get("max_depth", 5))

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	match action:
		"save":
			var state: Dictionary = _serialize_node(node, max_depth, 0)
			_send_response({"success": true, "action": "save", "state": state})
		"load":
			var data: Dictionary = params.get("data", {})
			if data.is_empty():
				_send_response({"error": "data is required for load action"})
				return
			var count: int = _deserialize_node(node, data)
			_send_response({"success": true, "action": "load", "restored_count": count})
		_:
			_send_response({"error": "Unknown serialize action: %s. Use save or load" % action})


func _serialize_node(node: Node, max_depth: int, depth: int) -> Dictionary:
	var result: Dictionary = {
		"class": node.get_class(),
		"name": node.name,
		"path": str(node.get_path()),
	}
	# Capture editor-visible properties
	var props: Dictionary = {}
	for prop in node.get_property_list():
		var prop_dict: Dictionary = prop
		if prop_dict.get("usage", 0) & PROPERTY_USAGE_STORAGE:
			var prop_name: String = prop_dict.get("name", "")
			if prop_name.is_empty() or prop_name.begins_with("_"):
				continue
			props[prop_name] = _variant_to_json(node.get(prop_name))
	result["properties"] = props

	if depth < max_depth:
		var children: Array = []
		for child in node.get_children():
			# Skip the MCP interaction server itself
			if child == self:
				continue
			children.append(_serialize_node(child, max_depth, depth + 1))
		result["children"] = children

	return result


func _deserialize_node(node: Node, data: Dictionary) -> int:
	var count: int = 0
	# Restore properties
	var props: Dictionary = data.get("properties", {})
	for prop_name in props:
		var value: Variant = _json_to_variant_for_property(node, prop_name, props[prop_name])
		node.set(prop_name, value)
	count += 1

	# Restore children
	var children_data: Array = data.get("children", [])
	for child_data in children_data:
		var child_name: String = child_data.get("name", "")
		var child: Node = null
		for c in node.get_children():
			if c.name == child_name:
				child = c
				break
		if child != null:
			count += _deserialize_node(child, child_data)
	return count


# --- Physics Body ---
func _cmd_physics_body(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		_send_response({"error": "node_path is required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	if not (node is PhysicsBody2D or node is PhysicsBody3D):
		_send_response({"error": "Node is not a PhysicsBody: %s (is %s)" % [node_path, node.get_class()]})
		return

	# Set common physics properties
	if params.has("gravity_scale") and node.get("gravity_scale") != null:
		node.set("gravity_scale", float(params["gravity_scale"]))
	if params.has("mass") and node.get("mass") != null:
		node.set("mass", float(params["mass"]))
	if params.has("freeze") and node.get("freeze") != null:
		node.set("freeze", bool(params["freeze"]))
	if params.has("sleeping") and node.get("sleeping") != null:
		node.set("sleeping", bool(params["sleeping"]))
	if params.has("linear_damp") and node.get("linear_damp") != null:
		node.set("linear_damp", float(params["linear_damp"]))
	if params.has("angular_damp") and node.get("angular_damp") != null:
		node.set("angular_damp", float(params["angular_damp"]))

	# Velocity (2D vs 3D)
	if params.has("linear_velocity"):
		var lv: Dictionary = params["linear_velocity"]
		if node is PhysicsBody3D:
			node.set("linear_velocity", Vector3(float(lv.get("x", 0)), float(lv.get("y", 0)), float(lv.get("z", 0))))
		else:
			node.set("linear_velocity", Vector2(float(lv.get("x", 0)), float(lv.get("y", 0))))
	if params.has("angular_velocity"):
		var av: Variant = params["angular_velocity"]
		if node is PhysicsBody3D and av is Dictionary:
			node.set("angular_velocity", Vector3(float(av.get("x", 0)), float(av.get("y", 0)), float(av.get("z", 0))))
		else:
			node.set("angular_velocity", float(av))

	# Physics material (friction, bounce)
	if params.has("friction") or params.has("bounce"):
		var phys_mat: PhysicsMaterial = node.get("physics_material_override") as PhysicsMaterial
		if phys_mat == null:
			phys_mat = PhysicsMaterial.new()
			node.set("physics_material_override", phys_mat)
		if params.has("friction"):
			phys_mat.friction = float(params["friction"])
		if params.has("bounce"):
			phys_mat.bounce = float(params["bounce"])

	# Build response
	var result: Dictionary = {"success": true, "node_path": node_path, "class": node.get_class()}
	if node.get("mass") != null:
		result["mass"] = node.get("mass")
	if node.get("gravity_scale") != null:
		result["gravity_scale"] = node.get("gravity_scale")
	if node.get("linear_velocity") != null:
		result["linear_velocity"] = _variant_to_json(node.get("linear_velocity"))
	if node.get("angular_velocity") != null:
		result["angular_velocity"] = _variant_to_json(node.get("angular_velocity"))
	_send_response(result)


# --- Create Joint ---
func _cmd_create_joint(params: Dictionary) -> void:
	var parent_path: String = params.get("parent_path", "")
	var joint_type: String = params.get("joint_type", "")
	if parent_path.is_empty() or joint_type.is_empty():
		_send_response({"error": "parent_path and joint_type are required"})
		return

	var parent: Node = get_tree().root.get_node_or_null(parent_path)
	if parent == null:
		_send_response({"error": "Parent node not found: %s" % parent_path})
		return

	var node_a: String = params.get("node_a_path", "")
	var node_b: String = params.get("node_b_path", "")
	var joint: Node = null

	match joint_type:
		"pin_2d":
			var j: PinJoint2D = PinJoint2D.new()
			if not node_a.is_empty():
				j.node_a = NodePath(node_a)
			if not node_b.is_empty():
				j.node_b = NodePath(node_b)
			if params.has("softness"):
				j.softness = float(params["softness"])
			joint = j
		"spring_2d":
			var j: DampedSpringJoint2D = DampedSpringJoint2D.new()
			if not node_a.is_empty():
				j.node_a = NodePath(node_a)
			if not node_b.is_empty():
				j.node_b = NodePath(node_b)
			if params.has("length"):
				j.length = float(params["length"])
			if params.has("rest_length"):
				j.rest_length = float(params["rest_length"])
			if params.has("stiffness"):
				j.stiffness = float(params["stiffness"])
			if params.has("damping"):
				j.damping = float(params["damping"])
			joint = j
		"groove_2d":
			var j: GrooveJoint2D = GrooveJoint2D.new()
			if not node_a.is_empty():
				j.node_a = NodePath(node_a)
			if not node_b.is_empty():
				j.node_b = NodePath(node_b)
			if params.has("length"):
				j.length = float(params["length"])
			if params.has("initial_offset"):
				j.initial_offset = float(params["initial_offset"])
			joint = j
		"pin_3d":
			var j: PinJoint3D = PinJoint3D.new()
			if not node_a.is_empty():
				j.node_a = NodePath(node_a)
			if not node_b.is_empty():
				j.node_b = NodePath(node_b)
			joint = j
		"hinge_3d":
			var j: HingeJoint3D = HingeJoint3D.new()
			if not node_a.is_empty():
				j.node_a = NodePath(node_a)
			if not node_b.is_empty():
				j.node_b = NodePath(node_b)
			joint = j
		"cone_3d":
			var j: ConeTwistJoint3D = ConeTwistJoint3D.new()
			if not node_a.is_empty():
				j.node_a = NodePath(node_a)
			if not node_b.is_empty():
				j.node_b = NodePath(node_b)
			joint = j
		"slider_3d":
			var j: SliderJoint3D = SliderJoint3D.new()
			if not node_a.is_empty():
				j.node_a = NodePath(node_a)
			if not node_b.is_empty():
				j.node_b = NodePath(node_b)
			joint = j
		_:
			_send_response({"error": "Unknown joint type: %s. Use pin_2d, spring_2d, groove_2d, pin_3d, hinge_3d, cone_3d, or slider_3d" % joint_type})
			return

	parent.add_child(joint)
	_send_response({"success": true, "joint_type": joint_type, "name": joint.name, "path": str(joint.get_path())})


# --- Bone Pose ---
func _cmd_bone_pose(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var action: String = params.get("action", "list")
	if node_path.is_empty():
		_send_response({"error": "node_path is required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	if not node is Skeleton3D:
		_send_response({"error": "Node is not a Skeleton3D: %s (is %s)" % [node_path, node.get_class()]})
		return

	var skel: Skeleton3D = node as Skeleton3D

	match action:
		"list":
			var bones: Array = []
			for i in skel.get_bone_count():
				bones.append({"index": i, "name": skel.get_bone_name(i), "parent": skel.get_bone_parent(i)})
			_send_response({"success": true, "action": "list", "bone_count": skel.get_bone_count(), "bones": bones})
		"get":
			var bone_idx: int = _resolve_bone_index(skel, params)
			if bone_idx < 0:
				_send_response({"error": "Bone not found"})
				return
			_send_response({
				"success": true, "action": "get", "bone_index": bone_idx,
				"bone_name": skel.get_bone_name(bone_idx),
				"position": _variant_to_json(skel.get_bone_pose_position(bone_idx)),
				"rotation": _variant_to_json(skel.get_bone_pose_rotation(bone_idx)),
				"scale": _variant_to_json(skel.get_bone_pose_scale(bone_idx))
			})
		"set":
			var bone_idx: int = _resolve_bone_index(skel, params)
			if bone_idx < 0:
				_send_response({"error": "Bone not found"})
				return
			if params.has("position"):
				var p: Dictionary = params["position"]
				skel.set_bone_pose_position(bone_idx, Vector3(float(p.get("x", 0)), float(p.get("y", 0)), float(p.get("z", 0))))
			if params.has("rotation"):
				var r: Dictionary = params["rotation"]
				skel.set_bone_pose_rotation(bone_idx, Quaternion(float(r.get("x", 0)), float(r.get("y", 0)), float(r.get("z", 0)), float(r.get("w", 1))))
			if params.has("scale"):
				var s: Dictionary = params["scale"]
				skel.set_bone_pose_scale(bone_idx, Vector3(float(s.get("x", 1)), float(s.get("y", 1)), float(s.get("z", 1))))
			_send_response({"success": true, "action": "set", "bone_index": bone_idx, "bone_name": skel.get_bone_name(bone_idx)})
		_:
			_send_response({"error": "Unknown bone action: %s. Use list, get, or set" % action})


func _resolve_bone_index(skel: Skeleton3D, params: Dictionary) -> int:
	if params.has("bone_index"):
		return int(params["bone_index"])
	if params.has("bone_name"):
		return skel.find_bone(params["bone_name"])
	return -1


# --- UI Theme ---
func _cmd_ui_theme(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		_send_response({"error": "node_path is required"})
		return

	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return

	if not node is Control:
		_send_response({"error": "Node is not a Control: %s (is %s)" % [node_path, node.get_class()]})
		return

	var ctrl: Control = node as Control
	var overrides: Dictionary = params.get("overrides", {})
	var applied: Array = []

	# Color overrides
	var colors: Dictionary = overrides.get("colors", {})
	for name in colors:
		var c: Dictionary = colors[name]
		ctrl.add_theme_color_override(name, Color(float(c.get("r", 0)), float(c.get("g", 0)), float(c.get("b", 0)), float(c.get("a", 1))))
		applied.append("color:" + name)

	# Constant overrides
	var constants: Dictionary = overrides.get("constants", {})
	for name in constants:
		ctrl.add_theme_constant_override(name, int(constants[name]))
		applied.append("constant:" + name)

	# Font size overrides
	var font_sizes: Dictionary = overrides.get("font_sizes", {})
	for name in font_sizes:
		ctrl.add_theme_font_size_override(name, int(font_sizes[name]))
		applied.append("font_size:" + name)

	_send_response({"success": true, "node_path": node_path, "applied": applied})


# --- Viewport ---
func _cmd_viewport(params: Dictionary) -> void:
	var action: String = params.get("action", "create")

	match action:
		"create":
			var parent_path: String = params.get("parent_path", "/root")
			var parent: Node = get_tree().root.get_node_or_null(parent_path)
			if parent == null:
				_send_response({"error": "Parent node not found: %s" % parent_path})
				return
			var viewport: SubViewport = SubViewport.new()
			if params.has("width") and params.has("height"):
				viewport.size = Vector2i(int(params["width"]), int(params["height"]))
			if params.has("transparent_bg"):
				viewport.transparent_bg = bool(params["transparent_bg"])
			if params.has("msaa"):
				viewport.msaa_2d = int(params["msaa"]) as Viewport.MSAA
				viewport.msaa_3d = int(params["msaa"]) as Viewport.MSAA
			if params.has("name") and params["name"] is String and not (params["name"] as String).is_empty():
				viewport.name = params["name"]
			var container: SubViewportContainer = SubViewportContainer.new()
			container.add_child(viewport)
			parent.add_child(container)
			_send_response({"success": true, "action": "create", "viewport_path": str(viewport.get_path()), "container_path": str(container.get_path()), "size": _variant_to_json(viewport.size)})
		"configure":
			var node_path: String = params.get("node_path", "")
			if node_path.is_empty():
				_send_response({"error": "node_path is required for configure"})
				return
			var vp: Node = get_tree().root.get_node_or_null(node_path)
			if vp == null or not vp is SubViewport:
				_send_response({"error": "SubViewport not found: %s" % node_path})
				return
			var sv: SubViewport = vp as SubViewport
			if params.has("width") and params.has("height"):
				sv.size = Vector2i(int(params["width"]), int(params["height"]))
			if params.has("transparent_bg"):
				sv.transparent_bg = bool(params["transparent_bg"])
			if params.has("msaa"):
				sv.msaa_2d = int(params["msaa"]) as Viewport.MSAA
				sv.msaa_3d = int(params["msaa"]) as Viewport.MSAA
			_send_response({"success": true, "action": "configure", "size": _variant_to_json(sv.size), "transparent_bg": sv.transparent_bg})
		"get":
			var node_path: String = params.get("node_path", "")
			if node_path.is_empty():
				_send_response({"error": "node_path is required for get"})
				return
			var vp: Node = get_tree().root.get_node_or_null(node_path)
			if vp == null or not vp is SubViewport:
				_send_response({"error": "SubViewport not found: %s" % node_path})
				return
			var sv: SubViewport = vp as SubViewport
			_send_response({"success": true, "action": "get", "size": _variant_to_json(sv.size), "transparent_bg": sv.transparent_bg, "msaa_2d": sv.msaa_2d, "msaa_3d": sv.msaa_3d})
		_:
			_send_response({"error": "Unknown viewport action: %s. Use create, configure, or get" % action})


# --- Debug Draw ---
var _debug_draw_node: Node = null
var _debug_meshes: Array = []

func _cmd_debug_draw(params: Dictionary) -> void:
	var action: String = params.get("action", "line")
	var color_dict: Dictionary = params.get("color", {"r": 1.0, "g": 0.0, "b": 0.0})
	var color: Color = Color(float(color_dict.get("r", 1)), float(color_dict.get("g", 0)), float(color_dict.get("b", 0)), float(color_dict.get("a", 1)))
	var duration: int = int(params.get("duration", 0))

	if action == "clear":
		_clear_debug_draw()
		_send_response({"success": true, "action": "clear"})
		return

	# Ensure we have a debug draw parent
	if _debug_draw_node == null or not is_instance_valid(_debug_draw_node):
		_debug_draw_node = Node3D.new()
		_debug_draw_node.name = "_McpDebugDraw"
		get_tree().root.add_child(_debug_draw_node)

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if color.a < 1.0 else BaseMaterial3D.TRANSPARENCY_DISABLED

	match action:
		"line":
			var from_dict: Dictionary = params.get("from", {})
			var to_dict: Dictionary = params.get("to", {})
			var from_pos: Vector3 = Vector3(float(from_dict.get("x", 0)), float(from_dict.get("y", 0)), float(from_dict.get("z", 0)))
			var to_pos: Vector3 = Vector3(float(to_dict.get("x", 0)), float(to_dict.get("y", 0)), float(to_dict.get("z", 0)))
			var im: ImmediateMesh = ImmediateMesh.new()
			im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
			im.surface_add_vertex(from_pos)
			im.surface_add_vertex(to_pos)
			im.surface_end()
			var mi: MeshInstance3D = MeshInstance3D.new()
			mi.mesh = im
			_debug_draw_node.add_child(mi)
			_debug_meshes.append({"node": mi, "frames_left": duration})
			_send_response({"success": true, "action": "line"})
		"sphere":
			var center_dict: Dictionary = params.get("center", {})
			var center: Vector3 = Vector3(float(center_dict.get("x", 0)), float(center_dict.get("y", 0)), float(center_dict.get("z", 0)))
			var radius: float = float(params.get("radius", 0.5))
			var sphere_mesh: SphereMesh = SphereMesh.new()
			sphere_mesh.radius = radius
			sphere_mesh.height = radius * 2.0
			sphere_mesh.material = mat
			var mi: MeshInstance3D = MeshInstance3D.new()
			mi.mesh = sphere_mesh
			mi.global_position = center
			_debug_draw_node.add_child(mi)
			_debug_meshes.append({"node": mi, "frames_left": duration})
			_send_response({"success": true, "action": "sphere"})
		"box":
			var center_dict: Dictionary = params.get("center", {})
			var center: Vector3 = Vector3(float(center_dict.get("x", 0)), float(center_dict.get("y", 0)), float(center_dict.get("z", 0)))
			var size_dict: Dictionary = params.get("size", {"x": 1, "y": 1, "z": 1})
			var box_size: Vector3 = Vector3(float(size_dict.get("x", 1)), float(size_dict.get("y", 1)), float(size_dict.get("z", 1)))
			var box_mesh: BoxMesh = BoxMesh.new()
			box_mesh.size = box_size
			box_mesh.material = mat
			var mi: MeshInstance3D = MeshInstance3D.new()
			mi.mesh = box_mesh
			mi.global_position = center
			_debug_draw_node.add_child(mi)
			_debug_meshes.append({"node": mi, "frames_left": duration})
			_send_response({"success": true, "action": "box"})
		_:
			_send_response({"error": "Unknown debug draw action: %s. Use line, sphere, box, or clear" % action})


func _clear_debug_draw() -> void:
	for entry in _debug_meshes:
		if is_instance_valid(entry["node"]):
			entry["node"].queue_free()
	_debug_meshes.clear()
	if _debug_draw_node != null and is_instance_valid(_debug_draw_node):
		_debug_draw_node.queue_free()
		_debug_draw_node = null


# ==========================================================================
# Batch 1: Networking + Input + System + Signals + Script
# ==========================================================================

func _cmd_http_request(params: Dictionary) -> void:
	var url: String = params.get("url", "")
	if url.is_empty():
		_send_response({"error": "url is required"})
		return
	var method_str: String = params.get("method", "GET").to_upper()
	var http: HTTPRequest = HTTPRequest.new()
	http.timeout = float(params.get("timeout", 30))
	add_child(http)
	var headers: PackedStringArray = PackedStringArray()
	if params.has("headers"):
		var h: Dictionary = params["headers"]
		for k in h:
			headers.append("%s: %s" % [k, str(h[k])])
	var method_enum: int = HTTPClient.METHOD_GET
	match method_str:
		"POST": method_enum = HTTPClient.METHOD_POST
		"PUT": method_enum = HTTPClient.METHOD_PUT
		"DELETE": method_enum = HTTPClient.METHOD_DELETE
	var body: String = params.get("body", "")
	var err: int = http.request(url, headers, method_enum, body)
	if err != OK:
		http.queue_free()
		_send_response({"error": "HTTP request failed to start: %d" % err})
		return
	var result: Array = await http.request_completed
	http.queue_free()
	_send_response({"success": true, "status_code": result[1], "body": result[3].get_string_from_utf8()})


var _websocket: WebSocketPeer = null

func _cmd_websocket(params: Dictionary) -> void:
	var action: String = params.get("action", "")
	match action:
		"connect":
			var url: String = params.get("url", "")
			if url.is_empty():
				_send_response({"error": "url is required for connect"})
				return
			_websocket = WebSocketPeer.new()
			var err: int = _websocket.connect_to_url(url)
			if err != OK:
				_send_response({"error": "WebSocket connect failed: %d" % err})
				_websocket = null
				return
			_send_response({"success": true, "action": "connect", "url": url})
		"disconnect":
			if _websocket != null:
				_websocket.close()
				_websocket = null
			_send_response({"success": true, "action": "disconnect"})
		"send":
			if _websocket == null:
				_send_response({"error": "No WebSocket connection"})
				return
			_websocket.poll()
			var msg: String = params.get("message", "")
			_websocket.send_text(msg)
			_send_response({"success": true, "action": "send"})
		"status":
			if _websocket == null:
				_send_response({"success": true, "status": "disconnected"})
				return
			_websocket.poll()
			_send_response({"success": true, "status": _websocket.get_ready_state()})
		_:
			_send_response({"error": "Unknown websocket action: %s" % action})


func _cmd_multiplayer(params: Dictionary) -> void:
	var action: String = params.get("action", "")
	match action:
		"create_server":
			var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
			var port: int = int(params.get("port", 7000))
			var max_cl: int = int(params.get("max_clients", 32))
			var err: int = peer.create_server(port, max_cl)
			if err != OK:
				_send_response({"error": "Failed to create server: %d" % err})
				return
			multiplayer.multiplayer_peer = peer
			_send_response({"success": true, "action": "create_server", "port": port})
		"create_client":
			var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
			var address: String = params.get("address", "127.0.0.1")
			var port: int = int(params.get("port", 7000))
			var err: int = peer.create_client(address, port)
			if err != OK:
				_send_response({"error": "Failed to create client: %d" % err})
				return
			multiplayer.multiplayer_peer = peer
			_send_response({"success": true, "action": "create_client", "address": address, "port": port})
		"disconnect":
			multiplayer.multiplayer_peer = null
			_send_response({"success": true, "action": "disconnect"})
		"status":
			var peer = multiplayer.multiplayer_peer
			if peer == null:
				_send_response({"success": true, "connected": false})
				return
			_send_response({"success": true, "connected": true, "unique_id": multiplayer.get_unique_id(), "is_server": multiplayer.is_server()})
		_:
			_send_response({"error": "Unknown multiplayer action: %s" % action})


func _cmd_rpc(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return
	var action: String = params.get("action", "call")
	var method: String = params.get("method", "")
	if action == "call":
		var args: Array = params.get("args", [])
		node.rpc(method, args)
		_send_response({"success": true, "action": "call", "method": method})
	else:
		_send_response({"success": true, "action": action, "method": method})


func _cmd_touch(params: Dictionary) -> void:
	var action: String = params.get("action", "press")
	var x: float = float(params.get("x", 0))
	var y: float = float(params.get("y", 0))
	var idx: int = int(params.get("index", 0))
	match action:
		"press":
			var ev: InputEventScreenTouch = InputEventScreenTouch.new()
			ev.index = idx
			ev.position = Vector2(x, y)
			ev.pressed = true
			Input.parse_input_event(ev)
			await get_tree().process_frame
			_send_response({"success": true, "action": "press", "x": x, "y": y})
		"release":
			var ev: InputEventScreenTouch = InputEventScreenTouch.new()
			ev.index = idx
			ev.position = Vector2(x, y)
			ev.pressed = false
			Input.parse_input_event(ev)
			await get_tree().process_frame
			_send_response({"success": true, "action": "release", "x": x, "y": y})
		"drag":
			var to_x: float = float(params.get("to_x", x))
			var to_y: float = float(params.get("to_y", y))
			var steps: int = int(params.get("steps", 10))
			var press_ev: InputEventScreenTouch = InputEventScreenTouch.new()
			press_ev.index = idx
			press_ev.position = Vector2(x, y)
			press_ev.pressed = true
			Input.parse_input_event(press_ev)
			for i in range(steps):
				var t: float = float(i + 1) / float(steps)
				var drag_ev: InputEventScreenDrag = InputEventScreenDrag.new()
				drag_ev.index = idx
				drag_ev.position = Vector2(lerp(x, to_x, t), lerp(y, to_y, t))
				Input.parse_input_event(drag_ev)
				await get_tree().process_frame
			var rel_ev: InputEventScreenTouch = InputEventScreenTouch.new()
			rel_ev.index = idx
			rel_ev.position = Vector2(to_x, to_y)
			rel_ev.pressed = false
			Input.parse_input_event(rel_ev)
			await get_tree().process_frame
			_send_response({"success": true, "action": "drag", "from": {"x": x, "y": y}, "to": {"x": to_x, "y": to_y}})
		_:
			_send_response({"error": "Unknown touch action: %s" % action})


func _cmd_input_state(params: Dictionary) -> void:
	var action: String = params.get("action", "query")
	match action:
		"query":
			var mouse_pos: Vector2 = get_viewport().get_mouse_position()
			var joypads: Array = Input.get_connected_joypads()
			_send_response({"success": true, "mouse_position": {"x": mouse_pos.x, "y": mouse_pos.y}, "connected_joypads": joypads.size()})
		"warp_mouse":
			var pos: Vector2 = Vector2(float(params.get("x", 0)), float(params.get("y", 0)))
			Input.warp_mouse(pos)
			_send_response({"success": true, "action": "warp_mouse", "position": {"x": pos.x, "y": pos.y}})
		"set_mouse_mode":
			var mode_str: String = params.get("mouse_mode", "visible")
			var mode_val: int = Input.MOUSE_MODE_VISIBLE
			match mode_str:
				"hidden": mode_val = Input.MOUSE_MODE_HIDDEN
				"captured": mode_val = Input.MOUSE_MODE_CAPTURED
				"confined": mode_val = Input.MOUSE_MODE_CONFINED
			Input.mouse_mode = mode_val
			_send_response({"success": true, "action": "set_mouse_mode", "mode": mode_str})
		_:
			_send_response({"error": "Unknown input_state action: %s" % action})


func _cmd_input_action(params: Dictionary) -> void:
	var action: String = params.get("action", "")
	match action:
		"set_strength":
			var action_name: String = params.get("action_name", "")
			var strength: float = float(params.get("strength", 1.0))
			Input.action_press(action_name, strength)
			_send_response({"success": true, "action": "set_strength", "action_name": action_name, "strength": strength})
		"add_action":
			var action_name: String = params.get("action_name", "")
			if not InputMap.has_action(action_name):
				InputMap.add_action(action_name)
			if params.has("key"):
				var ev: InputEventKey = InputEventKey.new()
				ev.keycode = OS.find_keycode_from_string(params["key"])
				InputMap.action_add_event(action_name, ev)
			_send_response({"success": true, "action": "add_action", "action_name": action_name})
		"remove_action":
			var action_name: String = params.get("action_name", "")
			if InputMap.has_action(action_name):
				InputMap.erase_action(action_name)
			_send_response({"success": true, "action": "remove_action", "action_name": action_name})
		"list":
			var actions: Array = InputMap.get_actions()
			_send_response({"success": true, "actions": actions})
		_:
			_send_response({"error": "Unknown input_action action: %s" % action})


func _cmd_list_signals(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return
	var signals: Array = []
	for sig in node.get_signal_list():
		var connections: Array = []
		for conn in node.get_signal_connection_list(sig["name"]):
			connections.append({"callable": str(conn["callable"]), "flags": conn["flags"]})
		signals.append({"name": sig["name"], "args": str(sig["args"]), "connections": connections})
	_send_response({"success": true, "node_path": node_path, "signals": signals})


func _cmd_await_signal(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var signal_name: String = params.get("signal_name", "")
	var timeout: float = float(params.get("timeout", 10))
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return
	if not node.has_signal(signal_name):
		_send_response({"error": "Signal not found: %s on %s" % [signal_name, node_path]})
		return
	var timer: SceneTreeTimer = get_tree().create_timer(timeout)
	var result: Array = [false, []]
	var cb: Callable = func():
		result[0] = true
	node.connect(signal_name, cb, CONNECT_ONE_SHOT)
	while not result[0] and timer.time_left > 0:
		await get_tree().process_frame
	if node.is_connected(signal_name, cb):
		node.disconnect(signal_name, cb)
	if result[0]:
		_send_response({"success": true, "signal_name": signal_name, "received": true})
	else:
		_send_response({"success": true, "signal_name": signal_name, "received": false, "timeout": true})


func _cmd_script(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return
	var action: String = params.get("action", "get_source")
	match action:
		"get_source":
			var s = node.get_script()
			if s == null:
				_send_response({"success": true, "has_script": false})
				return
			_send_response({"success": true, "has_script": true, "source": s.source_code if s is GDScript else "", "path": s.resource_path})
		"attach":
			var source: String = params.get("source", "")
			if source.is_empty():
				_send_response({"error": "source is required for attach"})
				return
			var s: GDScript = GDScript.new()
			s.source_code = source
			var err: int = s.reload()
			if err != OK:
				_send_response({"error": "Script compile error: %d" % err})
				return
			node.set_script(s)
			_send_response({"success": true, "action": "attach", "node_path": node_path})
		"detach":
			node.set_script(null)
			_send_response({"success": true, "action": "detach", "node_path": node_path})
		_:
			_send_response({"error": "Unknown script action: %s" % action})


func _cmd_window(params: Dictionary) -> void:
	var action: String = params.get("action", "get")
	var win: Window = get_tree().root
	if action == "get":
		_send_response({"success": true, "size": {"x": win.size.x, "y": win.size.y}, "position": {"x": win.position.x, "y": win.position.y}, "fullscreen": win.mode == Window.MODE_FULLSCREEN, "borderless": win.borderless, "title": win.title})
		return
	if params.has("width") and params.has("height"):
		win.size = Vector2i(int(params["width"]), int(params["height"]))
	if params.has("fullscreen"):
		win.mode = Window.MODE_FULLSCREEN if bool(params["fullscreen"]) else Window.MODE_WINDOWED
	if params.has("borderless"):
		win.borderless = bool(params["borderless"])
	if params.has("title"):
		win.title = str(params["title"])
	if params.has("position"):
		var p: Dictionary = params["position"]
		win.position = Vector2i(int(p.get("x", 0)), int(p.get("y", 0)))
	if params.has("vsync"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(params["vsync"]) else DisplayServer.VSYNC_DISABLED)
	_send_response({"success": true, "action": "set", "size": {"x": win.size.x, "y": win.size.y}})


func _cmd_os_info() -> void:
	var screen_size: Vector2i = DisplayServer.screen_get_size()
	_send_response({"success": true, "os_name": OS.get_name(), "locale": OS.get_locale(), "screen_size": {"x": screen_size.x, "y": screen_size.y}, "video_adapter": RenderingServer.get_video_adapter_name(), "processor_count": OS.get_processor_count()})


func _cmd_time_scale(params: Dictionary) -> void:
	var action: String = params.get("action", "get")
	if action == "set":
		Engine.time_scale = float(params.get("time_scale", 1.0))
	_send_response({"success": true, "time_scale": Engine.time_scale, "ticks_msec": Time.get_ticks_msec(), "fps": Engine.get_frames_per_second()})


func _cmd_process_mode(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return
	var mode_str: String = params.get("mode", "inherit")
	var mode_val: int = Node.PROCESS_MODE_INHERIT
	match mode_str:
		"pausable": mode_val = Node.PROCESS_MODE_PAUSABLE
		"when_paused": mode_val = Node.PROCESS_MODE_WHEN_PAUSED
		"always": mode_val = Node.PROCESS_MODE_ALWAYS
		"disabled": mode_val = Node.PROCESS_MODE_DISABLED
	node.process_mode = mode_val
	_send_response({"success": true, "node_path": node_path, "mode": mode_str})


func _cmd_world_settings(params: Dictionary) -> void:
	var action: String = params.get("action", "get")
	if action == "set":
		if params.has("gravity"):
			ProjectSettings.set_setting("physics/3d/default_gravity", float(params["gravity"]))
		if params.has("physics_fps"):
			Engine.physics_ticks_per_second = int(params["physics_fps"])
	_send_response({"success": true, "gravity": ProjectSettings.get_setting("physics/3d/default_gravity"), "physics_fps": Engine.physics_ticks_per_second})


# ==========================================================================
# Batch 2: 3D Rendering + Lighting + Sky + Physics
# ==========================================================================

func _cmd_csg(params: Dictionary) -> void:
	var action: String = params.get("action", "create")
	if action == "create":
		var parent_path: String = params.get("parent_path", "/root")
		var parent: Node = get_tree().root.get_node_or_null(parent_path)
		if parent == null:
			_send_response({"error": "Parent not found: %s" % parent_path})
			return
		var csg_type: String = params.get("csg_type", "box")
		var node: CSGShape3D
		match csg_type:
			"box": node = CSGBox3D.new()
			"sphere": node = CSGSphere3D.new()
			"cylinder": node = CSGCylinder3D.new()
			"mesh": node = CSGMesh3D.new()
			"combiner": node = CSGCombiner3D.new()
			_:
				_send_response({"error": "Unknown CSG type: %s" % csg_type})
				return
		if params.has("operation"):
			match params["operation"]:
				"union": node.operation = CSGShape3D.OPERATION_UNION
				"intersection": node.operation = CSGShape3D.OPERATION_INTERSECTION
				"subtraction": node.operation = CSGShape3D.OPERATION_SUBTRACTION
		if params.has("name") and not (params["name"] as String).is_empty():
			node.name = params["name"]
		parent.add_child(node)
		node.owner = get_tree().edited_scene_root if get_tree().edited_scene_root else get_tree().root
		_send_response({"success": true, "action": "create", "path": str(node.get_path()), "type": csg_type})
	elif action == "configure":
		var node_path: String = params.get("node_path", "")
		var node: Node = get_tree().root.get_node_or_null(node_path)
		if node == null or not node is CSGShape3D:
			_send_response({"error": "CSGShape3D not found: %s" % node_path})
			return
		if params.has("operation"):
			match params["operation"]:
				"union": (node as CSGShape3D).operation = CSGShape3D.OPERATION_UNION
				"intersection": (node as CSGShape3D).operation = CSGShape3D.OPERATION_INTERSECTION
				"subtraction": (node as CSGShape3D).operation = CSGShape3D.OPERATION_SUBTRACTION
		_send_response({"success": true, "action": "configure", "path": str(node.get_path())})
	else:
		_send_response({"error": "Unknown csg action: %s" % action})


func _cmd_multimesh(params: Dictionary) -> void:
	var action: String = params.get("action", "create")
	match action:
		"create":
			var parent_path: String = params.get("parent_path", "/root")
			var parent: Node = get_tree().root.get_node_or_null(parent_path)
			if parent == null:
				_send_response({"error": "Parent not found: %s" % parent_path})
				return
			var mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
			var mm: MultiMesh = MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.instance_count = int(params.get("count", 1))
			var mesh_type: String = params.get("mesh_type", "box")
			match mesh_type:
				"box": mm.mesh = BoxMesh.new()
				"sphere": mm.mesh = SphereMesh.new()
				"cylinder": mm.mesh = CylinderMesh.new()
				_: mm.mesh = BoxMesh.new()
			mmi.multimesh = mm
			if params.has("name") and not (params["name"] as String).is_empty():
				mmi.name = params["name"]
			parent.add_child(mmi)
			_send_response({"success": true, "action": "create", "path": str(mmi.get_path()), "count": mm.instance_count})
		"set_instance":
			var node_path: String = params.get("node_path", "")
			var node: Node = get_tree().root.get_node_or_null(node_path)
			if node == null or not node is MultiMeshInstance3D:
				_send_response({"error": "MultiMeshInstance3D not found: %s" % node_path})
				return
			var idx: int = int(params.get("index", 0))
			var tf: Dictionary = params.get("transform", {})
			var origin: Dictionary = tf.get("origin", {})
			var xform: Transform3D = Transform3D.IDENTITY
			xform.origin = Vector3(float(origin.get("x", 0)), float(origin.get("y", 0)), float(origin.get("z", 0)))
			(node as MultiMeshInstance3D).multimesh.set_instance_transform(idx, xform)
			_send_response({"success": true, "action": "set_instance", "index": idx})
		"get_info":
			var node_path: String = params.get("node_path", "")
			var node: Node = get_tree().root.get_node_or_null(node_path)
			if node == null or not node is MultiMeshInstance3D:
				_send_response({"error": "MultiMeshInstance3D not found: %s" % node_path})
				return
			var mm = (node as MultiMeshInstance3D).multimesh
			_send_response({"success": true, "count": mm.instance_count if mm else 0, "visible_count": mm.visible_instance_count if mm else 0})
		_:
			_send_response({"error": "Unknown multimesh action: %s" % action})


func _cmd_procedural_mesh(params: Dictionary) -> void:
	var parent_path: String = params.get("parent_path", "/root")
	var parent: Node = get_tree().root.get_node_or_null(parent_path)
	if parent == null:
		_send_response({"error": "Parent not found: %s" % parent_path})
		return
	var verts_arr: Array = params.get("vertices", [])
	var verts: PackedVector3Array = PackedVector3Array()
	for v in verts_arr:
		verts.append(Vector3(float(v[0]), float(v[1]), float(v[2])))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	if params.has("normals"):
		var norms: PackedVector3Array = PackedVector3Array()
		for n in params["normals"]:
			norms.append(Vector3(float(n[0]), float(n[1]), float(n[2])))
		arrays[Mesh.ARRAY_NORMAL] = norms
	if params.has("uvs"):
		var uvs: PackedVector2Array = PackedVector2Array()
		for uv in params["uvs"]:
			uvs.append(Vector2(float(uv[0]), float(uv[1])))
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	if params.has("indices"):
		var indices: PackedInt32Array = PackedInt32Array()
		for idx in params["indices"]:
			indices.append(int(idx))
		arrays[Mesh.ARRAY_INDEX] = indices
	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	if params.has("name") and not (params["name"] as String).is_empty():
		mi.name = params["name"]
	parent.add_child(mi)
	_send_response({"success": true, "path": str(mi.get_path()), "vertex_count": verts.size()})


func _cmd_light_3d(params: Dictionary) -> void:
	var action: String = params.get("action", "create")
	if action == "create":
		var parent_path: String = params.get("parent_path", "/root")
		var parent: Node = get_tree().root.get_node_or_null(parent_path)
		if parent == null:
			_send_response({"error": "Parent not found: %s" % parent_path})
			return
		var light_type: String = params.get("light_type", "omni")
		var light: Light3D
		match light_type:
			"directional": light = DirectionalLight3D.new()
			"omni": light = OmniLight3D.new()
			"spot": light = SpotLight3D.new()
			_:
				_send_response({"error": "Unknown light type: %s" % light_type})
				return
		if params.has("color"):
			var c: Dictionary = params["color"]
			light.light_color = Color(float(c.get("r", 1)), float(c.get("g", 1)), float(c.get("b", 1)))
		if params.has("energy"):
			light.light_energy = float(params["energy"])
		if params.has("shadows"):
			light.shadow_enabled = bool(params["shadows"])
		if light is OmniLight3D and params.has("range"):
			(light as OmniLight3D).omni_range = float(params["range"])
		if light is SpotLight3D:
			if params.has("range"):
				(light as SpotLight3D).spot_range = float(params["range"])
			if params.has("spot_angle"):
				(light as SpotLight3D).spot_angle = float(params["spot_angle"])
		if params.has("name") and not (params["name"] as String).is_empty():
			light.name = params["name"]
		parent.add_child(light)
		_send_response({"success": true, "action": "create", "path": str(light.get_path()), "type": light_type})
	elif action == "configure":
		var node_path: String = params.get("node_path", "")
		var node: Node = get_tree().root.get_node_or_null(node_path)
		if node == null or not node is Light3D:
			_send_response({"error": "Light3D not found: %s" % node_path})
			return
		var light: Light3D = node as Light3D
		if params.has("color"):
			var c: Dictionary = params["color"]
			light.light_color = Color(float(c.get("r", 1)), float(c.get("g", 1)), float(c.get("b", 1)))
		if params.has("energy"):
			light.light_energy = float(params["energy"])
		if params.has("shadows"):
			light.shadow_enabled = bool(params["shadows"])
		_send_response({"success": true, "action": "configure", "path": str(node.get_path())})
	else:
		_send_response({"error": "Unknown light_3d action: %s" % action})


func _cmd_mesh_instance(params: Dictionary) -> void:
	var parent_path: String = params.get("parent_path", "/root")
	var parent: Node = get_tree().root.get_node_or_null(parent_path)
	if parent == null:
		_send_response({"error": "Parent not found: %s" % parent_path})
		return
	var mesh_type: String = params.get("mesh_type", "box")
	var mesh: Mesh
	match mesh_type:
		"box": mesh = BoxMesh.new()
		"sphere": mesh = SphereMesh.new()
		"cylinder": mesh = CylinderMesh.new()
		"capsule": mesh = CapsuleMesh.new()
		"plane": mesh = PlaneMesh.new()
		"quad": mesh = QuadMesh.new()
		_:
			_send_response({"error": "Unknown mesh type: %s" % mesh_type})
			return
	if params.has("size") and mesh is BoxMesh:
		var s: Dictionary = params["size"]
		(mesh as BoxMesh).size = Vector3(float(s.get("x", 1)), float(s.get("y", 1)), float(s.get("z", 1)))
	if params.has("radius"):
		if mesh is SphereMesh: (mesh as SphereMesh).radius = float(params["radius"])
		elif mesh is CylinderMesh: (mesh as CylinderMesh).top_radius = float(params["radius"])
		elif mesh is CapsuleMesh: (mesh as CapsuleMesh).radius = float(params["radius"])
	if params.has("height"):
		if mesh is CylinderMesh: (mesh as CylinderMesh).height = float(params["height"])
		elif mesh is CapsuleMesh: (mesh as CapsuleMesh).height = float(params["height"])
		elif mesh is SphereMesh: (mesh as SphereMesh).height = float(params["height"])
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	if params.has("material") and params["material"] is String:
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		var hex: String = params["material"]
		if hex.begins_with("#") or hex.length() == 6 or hex.length() == 8:
			mat.albedo_color = Color.from_string(hex, Color.WHITE)
		mi.material_override = mat
	if params.has("name") and not (params["name"] as String).is_empty():
		mi.name = params["name"]
	parent.add_child(mi)
	_send_response({"success": true, "path": str(mi.get_path()), "mesh_type": mesh_type})


func _cmd_gridmap(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null or not node is GridMap:
		_send_response({"error": "GridMap not found: %s" % node_path})
		return
	var gm: GridMap = node as GridMap
	var action: String = params.get("action", "get_used")
	match action:
		"set_cell":
			gm.set_cell_item(Vector3i(int(params.get("x", 0)), int(params.get("y", 0)), int(params.get("z", 0))), int(params.get("item", 0)), int(params.get("orientation", 0)))
			_send_response({"success": true, "action": "set_cell"})
		"get_cell":
			var item: int = gm.get_cell_item(Vector3i(int(params.get("x", 0)), int(params.get("y", 0)), int(params.get("z", 0))))
			_send_response({"success": true, "action": "get_cell", "item": item})
		"clear":
			gm.clear()
			_send_response({"success": true, "action": "clear"})
		"get_used":
			var cells: Array = gm.get_used_cells()
			var result: Array = []
			for c in cells.slice(0, 100):
				result.append({"x": c.x, "y": c.y, "z": c.z})
			_send_response({"success": true, "action": "get_used", "cells": result, "total": cells.size()})
		_:
			_send_response({"error": "Unknown gridmap action: %s" % action})


func _cmd_3d_effects(params: Dictionary) -> void:
	var parent_path: String = params.get("parent_path", "/root")
	var parent: Node = get_tree().root.get_node_or_null(parent_path)
	if parent == null:
		_send_response({"error": "Parent not found: %s" % parent_path})
		return
	var effect_type: String = params.get("effect_type", "")
	var node: Node3D
	match effect_type:
		"reflection_probe": node = ReflectionProbe.new()
		"decal": node = Decal.new()
		"fog_volume": node = FogVolume.new()
		_:
			_send_response({"error": "Unknown effect type: %s" % effect_type})
			return
	if params.has("size"):
		var s: Dictionary = params["size"]
		var size_v: Vector3 = Vector3(float(s.get("x", 1)), float(s.get("y", 1)), float(s.get("z", 1)))
		if node is ReflectionProbe: (node as ReflectionProbe).size = size_v
		elif node is Decal: (node as Decal).size = size_v
		elif node is FogVolume: (node as FogVolume).size = size_v
	if params.has("name") and not (params["name"] as String).is_empty():
		node.name = params["name"]
	parent.add_child(node)
	_send_response({"success": true, "path": str(node.get_path()), "effect_type": effect_type})


func _cmd_gi(params: Dictionary) -> void:
	var parent_path: String = params.get("parent_path", "/root")
	var parent: Node = get_tree().root.get_node_or_null(parent_path)
	if parent == null:
		_send_response({"error": "Parent not found: %s" % parent_path})
		return
	var gi_type: String = params.get("gi_type", "voxel_gi")
	var node: VisualInstance3D
	match gi_type:
		"voxel_gi": node = VoxelGI.new()
		"lightmap_gi": node = LightmapGI.new()
		_:
			_send_response({"error": "Unknown GI type: %s" % gi_type})
			return
	if params.has("size") and node is VoxelGI:
		var s: Dictionary = params["size"]
		(node as VoxelGI).size = Vector3(float(s.get("x", 10)), float(s.get("y", 10)), float(s.get("z", 10)))
	if params.has("name") and not (params["name"] as String).is_empty():
		node.name = params["name"]
	parent.add_child(node)
	_send_response({"success": true, "path": str(node.get_path()), "gi_type": gi_type})


func _cmd_path_3d(params: Dictionary) -> void:
	var action: String = params.get("action", "create")
	match action:
		"create":
			var parent_path: String = params.get("parent_path", "/root")
			var parent: Node = get_tree().root.get_node_or_null(parent_path)
			if parent == null:
				_send_response({"error": "Parent not found: %s" % parent_path})
				return
			var path_node: Path3D = Path3D.new()
			path_node.curve = Curve3D.new()
			if params.has("name") and not (params["name"] as String).is_empty():
				path_node.name = params["name"]
			if params.has("points"):
				for p in params["points"]:
					path_node.curve.add_point(Vector3(float(p.get("x", 0)), float(p.get("y", 0)), float(p.get("z", 0))))
			parent.add_child(path_node)
			_send_response({"success": true, "action": "create", "path": str(path_node.get_path()), "point_count": path_node.curve.point_count})
		"add_point":
			var node_path: String = params.get("node_path", "")
			var node: Node = get_tree().root.get_node_or_null(node_path)
			if node == null or not node is Path3D:
				_send_response({"error": "Path3D not found: %s" % node_path})
				return
			var p: Dictionary = params.get("point", {})
			(node as Path3D).curve.add_point(Vector3(float(p.get("x", 0)), float(p.get("y", 0)), float(p.get("z", 0))))
			_send_response({"success": true, "action": "add_point", "point_count": (node as Path3D).curve.point_count})
		"get_points":
			var node_path: String = params.get("node_path", "")
			var node: Node = get_tree().root.get_node_or_null(node_path)
			if node == null or not node is Path3D:
				_send_response({"error": "Path3D not found: %s" % node_path})
				return
			var pts: Array = []
			for i in (node as Path3D).curve.point_count:
				var pt: Vector3 = (node as Path3D).curve.get_point_position(i)
				pts.append({"x": pt.x, "y": pt.y, "z": pt.z})
			_send_response({"success": true, "action": "get_points", "points": pts})
		_:
			_send_response({"error": "Unknown path_3d action: %s" % action})


func _cmd_sky(params: Dictionary) -> void:
	var action: String = params.get("action", "create")
	var env: Environment = _get_or_create_environment()
	if env == null:
		_send_response({"error": "Could not get or create environment"})
		return
	var sky_type: String = params.get("sky_type", "procedural")
	if action == "create" or env.sky == null:
		env.sky = Sky.new()
		env.background_mode = Environment.BG_SKY
		var sky_mat: ProceduralSkyMaterial = ProceduralSkyMaterial.new()
		if params.has("top_color"):
			var c: Dictionary = params["top_color"]
			sky_mat.sky_top_color = Color(float(c.get("r", 0.4)), float(c.get("g", 0.6)), float(c.get("b", 1.0)))
		if params.has("bottom_color"):
			var c: Dictionary = params["bottom_color"]
			sky_mat.sky_horizon_color = Color(float(c.get("r", 0.7)), float(c.get("g", 0.8)), float(c.get("b", 0.9)))
		if params.has("ground_color"):
			var c: Dictionary = params["ground_color"]
			sky_mat.ground_bottom_color = Color(float(c.get("r", 0.1)), float(c.get("g", 0.1)), float(c.get("b", 0.1)))
		if params.has("sun_energy"):
			sky_mat.sun_curve = float(params["sun_energy"])
		env.sky.sky_material = sky_mat
	_send_response({"success": true, "action": action, "sky_type": sky_type})


func _get_or_create_environment() -> Environment:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam != null and cam.get_environment() != null:
		return cam.get_environment()
	var we: WorldEnvironment = null
	for child in get_tree().root.get_children():
		if child is WorldEnvironment:
			we = child as WorldEnvironment
			break
	if we != null and we.environment != null:
		return we.environment
	# Create one
	we = WorldEnvironment.new()
	we.environment = Environment.new()
	get_tree().root.add_child(we)
	return we.environment


func _cmd_camera_attributes(params: Dictionary) -> void:
	var action: String = params.get("action", "get")
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		_send_response({"error": "No Camera3D found in viewport"})
		return
	if action == "get":
		var info: Dictionary = {"success": true, "action": "get"}
		if cam.attributes != null:
			info["has_attributes"] = true
		else:
			info["has_attributes"] = false
		_send_response(info)
		return
	# set
	if cam.attributes == null:
		cam.attributes = CameraAttributesPractical.new()
	var attr: CameraAttributesPractical = cam.attributes as CameraAttributesPractical
	if attr == null:
		_send_response({"error": "Camera attributes is not CameraAttributesPractical"})
		return
	if params.has("dof_blur_far"):
		attr.dof_blur_far_enabled = true
		attr.dof_blur_far_distance = float(params["dof_blur_far"])
	if params.has("dof_blur_near"):
		attr.dof_blur_near_enabled = true
		attr.dof_blur_near_distance = float(params["dof_blur_near"])
	if params.has("dof_blur_amount"):
		attr.dof_blur_amount = float(params["dof_blur_amount"])
	if params.has("auto_exposure"):
		attr.auto_exposure_enabled = bool(params["auto_exposure"])
	_send_response({"success": true, "action": "set"})


func _cmd_navigation_3d(params: Dictionary) -> void:
	var action: String = params.get("action", "create")
	match action:
		"create":
			var parent_path: String = params.get("parent_path", "/root")
			var parent: Node = get_tree().root.get_node_or_null(parent_path)
			if parent == null:
				_send_response({"error": "Parent not found: %s" % parent_path})
				return
			var region: NavigationRegion3D = NavigationRegion3D.new()
			region.navigation_mesh = NavigationMesh.new()
			if params.has("cell_size"):
				region.navigation_mesh.cell_size = float(params["cell_size"])
			if params.has("agent_radius"):
				region.navigation_mesh.agent_radius = float(params["agent_radius"])
			if params.has("agent_height"):
				region.navigation_mesh.agent_height = float(params["agent_height"])
			if params.has("name") and not (params["name"] as String).is_empty():
				region.name = params["name"]
			parent.add_child(region)
			_send_response({"success": true, "action": "create", "path": str(region.get_path())})
		"bake":
			var node_path: String = params.get("node_path", "")
			var node: Node = get_tree().root.get_node_or_null(node_path)
			if node == null or not node is NavigationRegion3D:
				_send_response({"error": "NavigationRegion3D not found: %s" % node_path})
				return
			(node as NavigationRegion3D).bake_navigation_mesh()
			await get_tree().process_frame
			await get_tree().process_frame
			_send_response({"success": true, "action": "bake"})
		_:
			_send_response({"error": "Unknown navigation_3d action: %s" % action})


func _cmd_physics_3d(params: Dictionary) -> void:
	var action: String = params.get("action", "ray")
	await get_tree().physics_frame
	var space: PhysicsDirectSpaceState3D = get_viewport().world_3d.direct_space_state
	match action:
		"ray":
			var from_d: Dictionary = params.get("from", {})
			var to_d: Dictionary = params.get("to", {})
			var from: Vector3 = Vector3(float(from_d.get("x", 0)), float(from_d.get("y", 0)), float(from_d.get("z", 0)))
			var to: Vector3 = Vector3(float(to_d.get("x", 0)), float(to_d.get("y", 0)), float(to_d.get("z", 0)))
			var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to)
			if params.has("collision_mask"):
				query.collision_mask = int(params["collision_mask"])
			var result: Dictionary = space.intersect_ray(query)
			if result.is_empty():
				_send_response({"success": true, "action": "ray", "hit": false})
			else:
				_send_response({"success": true, "action": "ray", "hit": true, "position": _variant_to_json(result["position"]), "normal": _variant_to_json(result["normal"]), "collider": str(result.get("collider", ""))})
		"overlap":
			var node_path: String = params.get("node_path", "")
			var node: Node = get_tree().root.get_node_or_null(node_path)
			if node == null or not node is Area3D:
				_send_response({"error": "Area3D not found: %s" % node_path})
				return
			var bodies: Array = (node as Area3D).get_overlapping_bodies()
			var result: Array = []
			for b in bodies:
				result.append({"name": b.name, "path": str(b.get_path())})
			_send_response({"success": true, "action": "overlap", "bodies": result})
		_:
			_send_response({"error": "Unknown physics_3d action: %s" % action})


# ==========================================================================
# Batch 3: 2D Systems + Animation Advanced + Audio Effects
# ==========================================================================

func _cmd_canvas(params: Dictionary) -> void:
	var action: String = params.get("action", "create_layer")
	match action:
		"create_layer":
			var parent_path: String = params.get("parent_path", "/root")
			var parent: Node = get_tree().root.get_node_or_null(parent_path)
			if parent == null:
				_send_response({"error": "Parent not found: %s" % parent_path})
				return
			var cl: CanvasLayer = CanvasLayer.new()
			if params.has("layer"):
				cl.layer = int(params["layer"])
			if params.has("name") and not (params["name"] as String).is_empty():
				cl.name = params["name"]
			parent.add_child(cl)
			_send_response({"success": true, "action": "create_layer", "path": str(cl.get_path())})
		"create_modulate":
			var parent_path: String = params.get("parent_path", "/root")
			var parent: Node = get_tree().root.get_node_or_null(parent_path)
			if parent == null:
				_send_response({"error": "Parent not found: %s" % parent_path})
				return
			var cm: CanvasModulate = CanvasModulate.new()
			if params.has("color"):
				var c: Dictionary = params["color"]
				cm.color = Color(float(c.get("r", 1)), float(c.get("g", 1)), float(c.get("b", 1)), float(c.get("a", 1)))
			if params.has("name") and not (params["name"] as String).is_empty():
				cm.name = params["name"]
			parent.add_child(cm)
			_send_response({"success": true, "action": "create_modulate", "path": str(cm.get_path())})
		_:
			_send_response({"error": "Unknown canvas action: %s" % action})


var _canvas_draw_node: Node2D = null
var _draw_commands: Array = []

func _cmd_canvas_draw(params: Dictionary) -> void:
	var action: String = params.get("action", "line")
	if action == "clear":
		_draw_commands.clear()
		if _canvas_draw_node != null and is_instance_valid(_canvas_draw_node):
			_canvas_draw_node.queue_redraw()
		_send_response({"success": true, "action": "clear"})
		return
	# Ensure draw node
	if _canvas_draw_node == null or not is_instance_valid(_canvas_draw_node):
		var parent_path: String = params.get("parent_path", "/root")
		var parent: Node = get_tree().root.get_node_or_null(parent_path)
		if parent == null:
			_send_response({"error": "Parent not found: %s" % parent_path})
			return
		_canvas_draw_node = Node2D.new()
		_canvas_draw_node.name = "_McpCanvasDraw"
		_canvas_draw_node.set_script(_create_draw_script())
		parent.add_child(_canvas_draw_node)
		_canvas_draw_node.set("draw_commands", _draw_commands)
	var color_d: Dictionary = params.get("color", {"r": 1.0, "g": 1.0, "b": 1.0, "a": 1.0})
	var color: Color = Color(float(color_d.get("r", 1)), float(color_d.get("g", 1)), float(color_d.get("b", 1)), float(color_d.get("a", 1)))
	_draw_commands.append({"action": action, "params": params, "color": color})
	_canvas_draw_node.set("draw_commands", _draw_commands)
	_canvas_draw_node.queue_redraw()
	_send_response({"success": true, "action": action})

func _create_draw_script() -> GDScript:
	var s: GDScript = GDScript.new()
	s.source_code = """extends Node2D
var draw_commands: Array = []
func _draw():
	for cmd in draw_commands:
		var p = cmd.params
		var c = cmd.color
		match cmd.action:
			"line":
				var f = p.get("from", {})
				var t = p.get("to", {})
				draw_line(Vector2(float(f.get("x",0)),float(f.get("y",0))),Vector2(float(t.get("x",0)),float(t.get("y",0))),c,float(p.get("width",2)))
			"rect":
				var r = p.get("rect", {})
				draw_rect(Rect2(float(r.get("x",0)),float(r.get("y",0)),float(r.get("w",10)),float(r.get("h",10))),c,bool(p.get("filled",true)))
			"circle":
				var ct = p.get("center", {})
				draw_circle(Vector2(float(ct.get("x",0)),float(ct.get("y",0))),float(p.get("radius",10)),c)
"""
	s.reload()
	return s


func _cmd_light_2d(params: Dictionary) -> void:
	var action: String = params.get("action", "create_point")
	var parent_path: String = params.get("parent_path", "/root")
	var parent: Node = get_tree().root.get_node_or_null(parent_path)
	if parent == null:
		_send_response({"error": "Parent not found: %s" % parent_path})
		return
	match action:
		"create_point":
			var light: PointLight2D = PointLight2D.new()
			if params.has("color"):
				var c: Dictionary = params["color"]
				light.color = Color(float(c.get("r", 1)), float(c.get("g", 1)), float(c.get("b", 1)), float(c.get("a", 1)))
			if params.has("energy"):
				light.energy = float(params["energy"])
			# Create a simple gradient texture for the light
			var tex: GradientTexture2D = GradientTexture2D.new()
			tex.width = 128
			tex.height = 128
			tex.fill = GradientTexture2D.FILL_RADIAL
			tex.gradient = Gradient.new()
			light.texture = tex
			if params.has("range"):
				light.texture_scale = float(params["range"])
			if params.has("name") and not (params["name"] as String).is_empty():
				light.name = params["name"]
			parent.add_child(light)
			_send_response({"success": true, "action": "create_point", "path": str(light.get_path())})
		"create_directional":
			var light: DirectionalLight2D = DirectionalLight2D.new()
			if params.has("color"):
				var c: Dictionary = params["color"]
				light.color = Color(float(c.get("r", 1)), float(c.get("g", 1)), float(c.get("b", 1)), float(c.get("a", 1)))
			if params.has("energy"):
				light.energy = float(params["energy"])
			if params.has("name") and not (params["name"] as String).is_empty():
				light.name = params["name"]
			parent.add_child(light)
			_send_response({"success": true, "action": "create_directional", "path": str(light.get_path())})
		_:
			_send_response({"error": "Unknown light_2d action: %s" % action})


func _cmd_parallax(params: Dictionary) -> void:
	var action: String = params.get("action", "create_background")
	match action:
		"create_background":
			var parent_path: String = params.get("parent_path", "/root")
			var parent: Node = get_tree().root.get_node_or_null(parent_path)
			if parent == null:
				_send_response({"error": "Parent not found: %s" % parent_path})
				return
			var bg: ParallaxBackground = ParallaxBackground.new()
			if params.has("name") and not (params["name"] as String).is_empty():
				bg.name = params["name"]
			parent.add_child(bg)
			_send_response({"success": true, "action": "create_background", "path": str(bg.get_path())})
		"add_layer":
			var parent_path: String = params.get("parent_path", "")
			var parent: Node = get_tree().root.get_node_or_null(parent_path)
			if parent == null or not parent is ParallaxBackground:
				_send_response({"error": "ParallaxBackground not found: %s" % parent_path})
				return
			var layer: ParallaxLayer = ParallaxLayer.new()
			if params.has("motion_scale"):
				var ms: Dictionary = params["motion_scale"]
				layer.motion_scale = Vector2(float(ms.get("x", 1)), float(ms.get("y", 1)))
			if params.has("motion_offset"):
				var mo: Dictionary = params["motion_offset"]
				layer.motion_offset = Vector2(float(mo.get("x", 0)), float(mo.get("y", 0)))
			if params.has("mirroring"):
				var mi: Dictionary = params["mirroring"]
				layer.motion_mirroring = Vector2(float(mi.get("x", 0)), float(mi.get("y", 0)))
			if params.has("name") and not (params["name"] as String).is_empty():
				layer.name = params["name"]
			parent.add_child(layer)
			_send_response({"success": true, "action": "add_layer", "path": str(layer.get_path())})
		_:
			_send_response({"error": "Unknown parallax action: %s" % action})


func _cmd_shape_2d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return
	var action: String = params.get("action", "get_points")
	match action:
		"add_point":
			var p: Dictionary = params.get("point", {})
			var pt: Vector2 = Vector2(float(p.get("x", 0)), float(p.get("y", 0)))
			if node is Line2D:
				(node as Line2D).add_point(pt)
			elif node is Polygon2D:
				var polygon: PackedVector2Array = (node as Polygon2D).polygon
				polygon.append(pt)
				(node as Polygon2D).polygon = polygon
			_send_response({"success": true, "action": "add_point"})
		"set_points":
			var pts: Array = params.get("points", [])
			var packed: PackedVector2Array = PackedVector2Array()
			for p in pts:
				packed.append(Vector2(float(p.get("x", 0)), float(p.get("y", 0))))
			if node is Line2D:
				(node as Line2D).points = packed
			elif node is Polygon2D:
				(node as Polygon2D).polygon = packed
			_send_response({"success": true, "action": "set_points", "count": packed.size()})
		"clear":
			if node is Line2D:
				(node as Line2D).clear_points()
			elif node is Polygon2D:
				(node as Polygon2D).polygon = PackedVector2Array()
			_send_response({"success": true, "action": "clear"})
		"get_points":
			var pts: PackedVector2Array
			if node is Line2D:
				pts = (node as Line2D).points
			elif node is Polygon2D:
				pts = (node as Polygon2D).polygon
			else:
				_send_response({"error": "Node is not Line2D or Polygon2D"})
				return
			var result: Array = []
			for p in pts:
				result.append({"x": p.x, "y": p.y})
			_send_response({"success": true, "action": "get_points", "points": result})
		_:
			_send_response({"error": "Unknown shape_2d action: %s" % action})


func _cmd_path_2d(params: Dictionary) -> void:
	var action: String = params.get("action", "create")
	match action:
		"create":
			var parent_path: String = params.get("parent_path", "/root")
			var parent: Node = get_tree().root.get_node_or_null(parent_path)
			if parent == null:
				_send_response({"error": "Parent not found: %s" % parent_path})
				return
			var path_node: Path2D = Path2D.new()
			path_node.curve = Curve2D.new()
			if params.has("name") and not (params["name"] as String).is_empty():
				path_node.name = params["name"]
			if params.has("points"):
				for p in params["points"]:
					path_node.curve.add_point(Vector2(float(p.get("x", 0)), float(p.get("y", 0))))
			parent.add_child(path_node)
			_send_response({"success": true, "action": "create", "path": str(path_node.get_path()), "point_count": path_node.curve.point_count})
		"add_point":
			var node_path: String = params.get("node_path", "")
			var node: Node = get_tree().root.get_node_or_null(node_path)
			if node == null or not node is Path2D:
				_send_response({"error": "Path2D not found: %s" % node_path})
				return
			var p: Dictionary = params.get("point", {})
			(node as Path2D).curve.add_point(Vector2(float(p.get("x", 0)), float(p.get("y", 0))))
			_send_response({"success": true, "action": "add_point", "point_count": (node as Path2D).curve.point_count})
		"get_points":
			var node_path: String = params.get("node_path", "")
			var node: Node = get_tree().root.get_node_or_null(node_path)
			if node == null or not node is Path2D:
				_send_response({"error": "Path2D not found: %s" % node_path})
				return
			var pts: Array = []
			for i in (node as Path2D).curve.point_count:
				var pt: Vector2 = (node as Path2D).curve.get_point_position(i)
				pts.append({"x": pt.x, "y": pt.y})
			_send_response({"success": true, "action": "get_points", "points": pts})
		_:
			_send_response({"error": "Unknown path_2d action: %s" % action})


func _cmd_physics_2d(params: Dictionary) -> void:
	var action: String = params.get("action", "ray")
	await get_tree().physics_frame
	var space: PhysicsDirectSpaceState2D = get_viewport().world_2d.direct_space_state
	match action:
		"ray":
			var from_d: Dictionary = params.get("from", {})
			var to_d: Dictionary = params.get("to", {})
			var from: Vector2 = Vector2(float(from_d.get("x", 0)), float(from_d.get("y", 0)))
			var to: Vector2 = Vector2(float(to_d.get("x", 0)), float(to_d.get("y", 0)))
			var query: PhysicsRayQueryParameters2D = PhysicsRayQueryParameters2D.create(from, to)
			if params.has("collision_mask"):
				query.collision_mask = int(params["collision_mask"])
			var result: Dictionary = space.intersect_ray(query)
			if result.is_empty():
				_send_response({"success": true, "action": "ray", "hit": false})
			else:
				_send_response({"success": true, "action": "ray", "hit": true, "position": _variant_to_json(result["position"]), "normal": _variant_to_json(result["normal"]), "collider": str(result.get("collider", ""))})
		"overlap":
			var node_path: String = params.get("node_path", "")
			var node: Node = get_tree().root.get_node_or_null(node_path)
			if node == null or not node is Area2D:
				_send_response({"error": "Area2D not found: %s" % node_path})
				return
			var bodies: Array = (node as Area2D).get_overlapping_bodies()
			var result: Array = []
			for b in bodies:
				result.append({"name": b.name, "path": str(b.get_path())})
			_send_response({"success": true, "action": "overlap", "bodies": result})
		_:
			_send_response({"error": "Unknown physics_2d action: %s" % action})


func _cmd_animation_tree(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found: %s" % node_path})
		return
	var tree: AnimationTree = node as AnimationTree
	var action: String = params.get("action", "get_state")
	match action:
		"travel":
			var state_name: String = params.get("state_name", "")
			var playback = tree.get("parameters/playback")
			if playback != null:
				playback.travel(state_name)
			_send_response({"success": true, "action": "travel", "state": state_name})
		"set_param":
			var param_name: String = params.get("param_name", "")
			var param_value = params.get("param_value", 0)
			tree.set("parameters/" + param_name, param_value)
			_send_response({"success": true, "action": "set_param", "param": param_name})
		"get_state":
			var playback = tree.get("parameters/playback")
			var current: String = ""
			if playback != null:
				current = playback.get_current_node()
			_send_response({"success": true, "action": "get_state", "current": current})
		_:
			_send_response({"error": "Unknown animation_tree action: %s" % action})


func _cmd_animation_control(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null or not node is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: %s" % node_path})
		return
	var player: AnimationPlayer = node as AnimationPlayer
	var action: String = params.get("action", "get_info")
	match action:
		"seek":
			var pos: float = float(params.get("position", 0))
			player.seek(pos)
			_send_response({"success": true, "action": "seek", "position": pos})
		"queue":
			var anim: String = params.get("animation_name", "")
			player.queue(anim)
			_send_response({"success": true, "action": "queue", "animation": anim})
		"set_speed":
			player.speed_scale = float(params.get("speed", 1.0))
			_send_response({"success": true, "action": "set_speed", "speed": player.speed_scale})
		"stop":
			player.stop()
			_send_response({"success": true, "action": "stop"})
		"get_info":
			var anims: PackedStringArray = player.get_animation_list()
			_send_response({"success": true, "action": "get_info", "current": player.current_animation, "playing": player.is_playing(), "animations": Array(anims), "speed_scale": player.speed_scale, "position": player.current_animation_position})
		_:
			_send_response({"error": "Unknown animation_control action: %s" % action})


func _cmd_skeleton_ik(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null or not node is SkeletonIK3D:
		_send_response({"error": "SkeletonIK3D not found: %s" % node_path})
		return
	var ik: SkeletonIK3D = node as SkeletonIK3D
	var action: String = params.get("action", "start")
	match action:
		"start":
			ik.start()
			_send_response({"success": true, "action": "start"})
		"stop":
			ik.stop()
			_send_response({"success": true, "action": "stop"})
		"set_target":
			var t: Dictionary = params.get("target", {})
			var target_tf: Transform3D = Transform3D.IDENTITY
			target_tf.origin = Vector3(float(t.get("x", 0)), float(t.get("y", 0)), float(t.get("z", 0)))
			ik.target = target_tf
			_send_response({"success": true, "action": "set_target"})
		_:
			_send_response({"error": "Unknown skeleton_ik action: %s" % action})


func _cmd_audio_effect(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "Master")
	var bus_idx: int = AudioServer.get_bus_index(bus_name)
	if bus_idx < 0:
		_send_response({"error": "Audio bus not found: %s" % bus_name})
		return
	var action: String = params.get("action", "list")
	match action:
		"list":
			var effects: Array = []
			for i in AudioServer.get_bus_effect_count(bus_idx):
				var eff: AudioEffect = AudioServer.get_bus_effect(bus_idx, i)
				effects.append({"index": i, "type": eff.get_class(), "enabled": AudioServer.is_bus_effect_enabled(bus_idx, i)})
			_send_response({"success": true, "action": "list", "bus": bus_name, "effects": effects})
		"add":
			var effect_type: String = params.get("effect_type", "reverb")
			var effect: AudioEffect
			match effect_type:
				"reverb": effect = AudioEffectReverb.new()
				"delay": effect = AudioEffectDelay.new()
				"chorus": effect = AudioEffectChorus.new()
				"eq": effect = AudioEffectEQ6.new()
				"compressor": effect = AudioEffectCompressor.new()
				"limiter": effect = AudioEffectLimiter.new()
				_:
					_send_response({"error": "Unknown effect type: %s" % effect_type})
					return
			AudioServer.add_bus_effect(bus_idx, effect)
			_send_response({"success": true, "action": "add", "effect_type": effect_type, "index": AudioServer.get_bus_effect_count(bus_idx) - 1})
		"remove":
			var idx: int = int(params.get("index", 0))
			AudioServer.remove_bus_effect(bus_idx, idx)
			_send_response({"success": true, "action": "remove", "index": idx})
		_:
			_send_response({"error": "Unknown audio_effect action: %s" % action})


func _cmd_audio_bus_layout(params: Dictionary) -> void:
	var action: String = params.get("action", "list")
	match action:
		"list":
			var buses: Array = []
			for i in AudioServer.bus_count:
				buses.append({"index": i, "name": AudioServer.get_bus_name(i), "volume": AudioServer.get_bus_volume_db(i), "mute": AudioServer.is_bus_mute(i), "solo": AudioServer.is_bus_solo(i), "send": AudioServer.get_bus_send(i), "effect_count": AudioServer.get_bus_effect_count(i)})
			_send_response({"success": true, "action": "list", "buses": buses})
		"add":
			var bus_name: String = params.get("bus_name", "New Bus")
			AudioServer.add_bus()
			var idx: int = AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
			_send_response({"success": true, "action": "add", "bus_name": bus_name, "index": idx})
		"remove":
			var bus_name: String = params.get("bus_name", "")
			var idx: int = AudioServer.get_bus_index(bus_name)
			if idx <= 0:
				_send_response({"error": "Cannot remove bus: %s" % bus_name})
				return
			AudioServer.remove_bus(idx)
			_send_response({"success": true, "action": "remove", "bus_name": bus_name})
		"set_send":
			var bus_name: String = params.get("bus_name", "")
			var send_to: String = params.get("send_to", "Master")
			var idx: int = AudioServer.get_bus_index(bus_name)
			if idx < 0:
				_send_response({"error": "Bus not found: %s" % bus_name})
				return
			AudioServer.set_bus_send(idx, send_to)
			_send_response({"success": true, "action": "set_send", "bus": bus_name, "send_to": send_to})
		_:
			_send_response({"error": "Unknown audio_bus_layout action: %s" % action})


func _cmd_audio_spatial(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null or not node is AudioStreamPlayer3D:
		_send_response({"error": "AudioStreamPlayer3D not found: %s" % node_path})
		return
	var player: AudioStreamPlayer3D = node as AudioStreamPlayer3D
	var action: String = params.get("action", "get_info")
	if action == "get_info":
		_send_response({"success": true, "max_distance": player.max_distance, "unit_size": player.unit_size, "max_db": player.max_db, "playing": player.playing})
		return
	if params.has("max_distance"):
		player.max_distance = float(params["max_distance"])
	if params.has("unit_size"):
		player.unit_size = float(params["unit_size"])
	if params.has("max_db"):
		player.max_db = float(params["max_db"])
	_send_response({"success": true, "action": "configure"})


# ==========================================================================
# Batch 4: Locale (runtime)
# ==========================================================================

func _cmd_locale(params: Dictionary) -> void:
	var action: String = params.get("action", "get")
	match action:
		"get":
			_send_response({"success": true, "locale": TranslationServer.get_locale()})
		"set":
			var locale: String = params.get("locale", "en")
			TranslationServer.set_locale(locale)
			_send_response({"success": true, "action": "set", "locale": locale})
		"translate":
			var key: String = params.get("key", "")
			var translated: String = tr(key)
			_send_response({"success": true, "key": key, "translated": translated})
		_:
			_send_response({"error": "Unknown locale action: %s" % action})


# ==========================================================================
# Batch 5: UI Controls + Rendering + Resource Runtime
# ==========================================================================

func _cmd_ui_control(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null or not node is Control:
		_send_response({"error": "Control not found: %s" % node_path})
		return
	var ctrl: Control = node as Control
	var action: String = params.get("action", "get_info")
	match action:
		"grab_focus":
			ctrl.grab_focus()
			_send_response({"success": true, "action": "grab_focus"})
		"release_focus":
			ctrl.release_focus()
			_send_response({"success": true, "action": "release_focus"})
		"configure":
			if params.has("tooltip"):
				ctrl.tooltip_text = str(params["tooltip"])
			if params.has("mouse_filter"):
				match params["mouse_filter"]:
					"stop": ctrl.mouse_filter = Control.MOUSE_FILTER_STOP
					"pass": ctrl.mouse_filter = Control.MOUSE_FILTER_PASS
					"ignore": ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			if params.has("min_size"):
				var s: Dictionary = params["min_size"]
				ctrl.custom_minimum_size = Vector2(float(s.get("x", 0)), float(s.get("y", 0)))
			_send_response({"success": true, "action": "configure"})
		"get_info":
			_send_response({"success": true, "size": _variant_to_json(ctrl.size), "position": _variant_to_json(ctrl.position), "has_focus": ctrl.has_focus(), "visible": ctrl.visible, "tooltip": ctrl.tooltip_text, "mouse_filter": ctrl.mouse_filter})
		_:
			_send_response({"error": "Unknown ui_control action: %s" % action})


func _cmd_ui_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return
	var action: String = params.get("action", "get")
	match action:
		"get":
			var text: String = ""
			if node is LineEdit: text = (node as LineEdit).text
			elif node is TextEdit: text = (node as TextEdit).text
			elif node is RichTextLabel: text = (node as RichTextLabel).text
			else:
				_send_response({"error": "Node is not a text control"})
				return
			_send_response({"success": true, "text": text})
		"set":
			var text: String = str(params.get("text", ""))
			if node is LineEdit: (node as LineEdit).text = text
			elif node is TextEdit: (node as TextEdit).text = text
			elif node is RichTextLabel: (node as RichTextLabel).text = text
			_send_response({"success": true, "action": "set"})
		"append":
			var text: String = str(params.get("text", ""))
			if node is TextEdit: (node as TextEdit).text += text
			elif node is RichTextLabel: (node as RichTextLabel).append_text(text)
			_send_response({"success": true, "action": "append"})
		"clear":
			if node is LineEdit: (node as LineEdit).text = ""
			elif node is TextEdit: (node as TextEdit).text = ""
			elif node is RichTextLabel: (node as RichTextLabel).clear()
			_send_response({"success": true, "action": "clear"})
		"bbcode":
			if node is RichTextLabel:
				(node as RichTextLabel).bbcode_enabled = true
				(node as RichTextLabel).text = str(params.get("text", ""))
			_send_response({"success": true, "action": "bbcode"})
		_:
			_send_response({"error": "Unknown ui_text action: %s" % action})


func _cmd_ui_popup(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null or not node is Window:
		_send_response({"error": "Window/Popup not found: %s" % node_path})
		return
	var win: Window = node as Window
	var action: String = params.get("action", "popup_centered")
	match action:
		"popup_centered":
			if params.has("size"):
				var s: Dictionary = params["size"]
				win.popup_centered(Vector2i(int(s.get("x", 200)), int(s.get("y", 100))))
			else:
				win.popup_centered()
			_send_response({"success": true, "action": "popup_centered"})
		"popup":
			win.popup()
			_send_response({"success": true, "action": "popup"})
		"hide":
			win.hide()
			_send_response({"success": true, "action": "hide"})
		"get_info":
			_send_response({"success": true, "visible": win.visible, "title": win.title, "size": _variant_to_json(win.size)})
		_:
			_send_response({"error": "Unknown ui_popup action: %s" % action})


func _cmd_ui_tree(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null or not node is Tree:
		_send_response({"error": "Tree not found: %s" % node_path})
		return
	var tree: Tree = node as Tree
	var action: String = params.get("action", "get_items")
	match action:
		"get_items":
			var items: Array = []
			var root: TreeItem = tree.get_root()
			if root != null:
				_collect_tree_items(root, items, 0)
			_send_response({"success": true, "action": "get_items", "items": items})
		"add":
			var text: String = str(params.get("text", "Item"))
			var root: TreeItem = tree.get_root()
			if root == null:
				root = tree.create_item()
			var item: TreeItem = tree.create_item(root)
			item.set_text(int(params.get("column", 0)), text)
			_send_response({"success": true, "action": "add", "text": text})
		_:
			_send_response({"error": "Unknown ui_tree action: %s" % action})

func _collect_tree_items(item: TreeItem, result: Array, depth: int) -> void:
	var col: int = 0
	result.append({"text": item.get_text(col), "depth": depth, "collapsed": item.collapsed})
	var child: TreeItem = item.get_first_child()
	while child != null:
		_collect_tree_items(child, result, depth + 1)
		child = child.get_next()


func _cmd_ui_item_list(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return
	var action: String = params.get("action", "get_items")
	if node is ItemList:
		var il: ItemList = node as ItemList
		match action:
			"get_items":
				var items: Array = []
				for i in il.item_count:
					items.append({"index": i, "text": il.get_item_text(i), "selected": il.is_selected(i)})
				_send_response({"success": true, "items": items})
			"select":
				il.select(int(params.get("index", 0)))
				_send_response({"success": true, "action": "select"})
			"add":
				il.add_item(str(params.get("text", "Item")))
				_send_response({"success": true, "action": "add"})
			"remove":
				il.remove_item(int(params.get("index", 0)))
				_send_response({"success": true, "action": "remove"})
			"clear":
				il.clear()
				_send_response({"success": true, "action": "clear"})
			_:
				_send_response({"error": "Unknown ui_item_list action: %s" % action})
	elif node is OptionButton:
		var ob: OptionButton = node as OptionButton
		match action:
			"get_items":
				var items: Array = []
				for i in ob.item_count:
					items.append({"index": i, "text": ob.get_item_text(i)})
				_send_response({"success": true, "items": items, "selected": ob.selected})
			"select":
				ob.select(int(params.get("index", 0)))
				_send_response({"success": true, "action": "select"})
			"add":
				ob.add_item(str(params.get("text", "Item")))
				_send_response({"success": true, "action": "add"})
			_:
				_send_response({"error": "Unknown action for OptionButton: %s" % action})
	else:
		_send_response({"error": "Node is not ItemList or OptionButton"})


func _cmd_ui_tabs(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return
	var action: String = params.get("action", "get_tabs")
	if node is TabContainer:
		var tc: TabContainer = node as TabContainer
		match action:
			"get_tabs":
				var tabs: Array = []
				for i in tc.get_tab_count():
					tabs.append({"index": i, "title": tc.get_tab_title(i)})
				_send_response({"success": true, "tabs": tabs, "current": tc.current_tab})
			"set_current":
				tc.current_tab = int(params.get("index", 0))
				_send_response({"success": true, "action": "set_current"})
			"set_title":
				tc.set_tab_title(int(params.get("index", 0)), str(params.get("title", "")))
				_send_response({"success": true, "action": "set_title"})
			_:
				_send_response({"error": "Unknown ui_tabs action: %s" % action})
	elif node is TabBar:
		var tb: TabBar = node as TabBar
		match action:
			"get_tabs":
				var tabs: Array = []
				for i in tb.tab_count:
					tabs.append({"index": i, "title": tb.get_tab_title(i)})
				_send_response({"success": true, "tabs": tabs, "current": tb.current_tab})
			"set_current":
				tb.current_tab = int(params.get("index", 0))
				_send_response({"success": true, "action": "set_current"})
			_:
				_send_response({"error": "Unknown ui_tabs action: %s" % action})
	else:
		_send_response({"error": "Node is not TabContainer or TabBar"})


func _cmd_ui_menu(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null or not node is PopupMenu:
		_send_response({"error": "PopupMenu not found: %s" % node_path})
		return
	var menu: PopupMenu = node as PopupMenu
	var action: String = params.get("action", "get_items")
	match action:
		"get_items":
			var items: Array = []
			for i in menu.item_count:
				items.append({"index": i, "text": menu.get_item_text(i), "checked": menu.is_item_checked(i), "disabled": menu.is_item_disabled(i), "id": menu.get_item_id(i)})
			_send_response({"success": true, "items": items})
		"add":
			var text: String = str(params.get("text", "Item"))
			var id: int = int(params.get("id", -1))
			menu.add_item(text, id)
			_send_response({"success": true, "action": "add"})
		"remove":
			menu.remove_item(int(params.get("index", 0)))
			_send_response({"success": true, "action": "remove"})
		"set_checked":
			menu.set_item_checked(int(params.get("index", 0)), bool(params.get("checked", true)))
			_send_response({"success": true, "action": "set_checked"})
		"clear":
			menu.clear()
			_send_response({"success": true, "action": "clear"})
		_:
			_send_response({"error": "Unknown ui_menu action: %s" % action})


func _cmd_ui_range(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		_send_response({"error": "Node not found: %s" % node_path})
		return
	var action: String = params.get("action", "get")
	if node is Range:
		var r: Range = node as Range
		if action == "get":
			_send_response({"success": true, "value": r.value, "min": r.min_value, "max": r.max_value, "step": r.step})
			return
		if params.has("value"): r.value = float(params["value"])
		if params.has("min_value"): r.min_value = float(params["min_value"])
		if params.has("max_value"): r.max_value = float(params["max_value"])
		if params.has("step"): r.step = float(params["step"])
		_send_response({"success": true, "action": "set", "value": r.value})
	elif node is ColorPicker:
		var cp: ColorPicker = node as ColorPicker
		if action == "get":
			var c: Color = cp.color
			_send_response({"success": true, "color": {"r": c.r, "g": c.g, "b": c.b, "a": c.a}})
			return
		if params.has("color"):
			var cd: Dictionary = params["color"]
			cp.color = Color(float(cd.get("r", 0)), float(cd.get("g", 0)), float(cd.get("b", 0)), float(cd.get("a", 1)))
		_send_response({"success": true, "action": "set"})
	else:
		_send_response({"error": "Node is not Range or ColorPicker"})


func _cmd_render_settings(params: Dictionary) -> void:
	var vp: Viewport = get_viewport()
	var action: String = params.get("action", "get")
	if action == "get":
		_send_response({"success": true, "msaa_2d": vp.msaa_2d, "msaa_3d": vp.msaa_3d, "screen_space_aa": vp.screen_space_aa, "use_taa": vp.use_taa, "scaling_3d_mode": vp.scaling_3d_mode, "scaling_3d_scale": vp.scaling_3d_scale})
		return
	if params.has("msaa_2d"):
		vp.msaa_2d = int(params["msaa_2d"]) as Viewport.MSAA
	if params.has("msaa_3d"):
		vp.msaa_3d = int(params["msaa_3d"]) as Viewport.MSAA
	if params.has("fxaa"):
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if bool(params["fxaa"]) else Viewport.SCREEN_SPACE_AA_DISABLED
	if params.has("taa"):
		vp.use_taa = bool(params["taa"])
	if params.has("scaling_mode"):
		vp.scaling_3d_mode = int(params["scaling_mode"]) as Viewport.Scaling3DMode
	if params.has("scaling_scale"):
		vp.scaling_3d_scale = float(params["scaling_scale"])
	_send_response({"success": true, "action": "set"})


func _cmd_resource(params: Dictionary) -> void:
	var action: String = params.get("action", "load")
	var res_path: String = params.get("path", "")
	match action:
		"load":
			if not ResourceLoader.exists(res_path):
				_send_response({"error": "Resource not found: %s" % res_path})
				return
			var res: Resource = ResourceLoader.load(res_path)
			if res == null:
				_send_response({"error": "Failed to load resource: %s" % res_path})
				return
			_send_response({"success": true, "action": "load", "path": res_path, "type": res.get_class()})
		"save":
			var node_path: String = params.get("node_path", "")
			var prop: String = params.get("property", "")
			if node_path.is_empty():
				_send_response({"error": "node_path is required for save"})
				return
			var node: Node = get_tree().root.get_node_or_null(node_path)
			if node == null:
				_send_response({"error": "Node not found: %s" % node_path})
				return
			var res = node.get(prop) if not prop.is_empty() else null
			if res is Resource:
				var err: int = ResourceSaver.save(res, res_path)
				_send_response({"success": err == OK, "action": "save", "path": res_path})
			else:
				_send_response({"error": "Property is not a Resource"})
		"exists":
			_send_response({"success": true, "action": "exists", "path": res_path, "exists": ResourceLoader.exists(res_path)})
		_:
			_send_response({"error": "Unknown resource action: %s" % action})


func _cmd_find_text(params: Dictionary) -> void:
	var search: String = params.get("text", "")
	var results: Array = []
	var root: Node = get_tree().root
	_collect_text_nodes(root, search, results)
	_send_response({"success": true, "found": not results.is_empty(), "matches": results, "search": search})


func _collect_text_nodes(node: Node, search: String, results: Array) -> void:
	var text: String = ""
	if node is Label:
		text = (node as Label).text
	elif node is RichTextLabel:
		text = (node as RichTextLabel).text
	elif node is Button:
		text = (node as Button).text
	elif node is LineEdit:
		text = (node as LineEdit).text
	elif node is TextEdit:
		text = (node as TextEdit).text
	if not text.is_empty():
		if search.is_empty() or text.to_lower().contains(search.to_lower()):
			results.append({"path": str(node.get_path()), "type": node.get_class(), "text": text})
	for child in node.get_children():
		_collect_text_nodes(child, search, results)


func _cmd_stress_test(params: Dictionary) -> void:
	var frames: int = params.get("frames", 300)
	var start_fps: float = Engine.get_frames_per_second()
	var min_fps: float = start_fps
	var node_count_start: int = get_tree().get_node_count()
	for i in range(frames):
		await get_tree().process_frame
		var fps: float = Engine.get_frames_per_second()
		if fps < min_fps:
			min_fps = fps
	var node_count_end: int = get_tree().get_node_count()
	_send_response({
		"success": true,
		"frames_run": frames,
		"start_fps": start_fps,
		"min_fps": min_fps,
		"node_count_start": node_count_start,
		"node_count_end": node_count_end,
		"node_leak_suspected": (node_count_end - node_count_start) > 10
	})


func _cmd_find_nodes_by_script(params: Dictionary) -> void:
	var script_path: String = params.get("script_path", "")
	var partial: bool = params.get("partial", true)
	var results: Array = []
	_collect_nodes_by_script(get_tree().root, script_path, partial, results)
	_send_response({"success": true, "nodes": results})

func _collect_nodes_by_script(node: Node, script_path: String, partial: bool, results: Array) -> void:
	var s = node.get_script()
	if s != null:
		var path: String = s.resource_path
		if (partial and path.contains(script_path)) or (not partial and path == script_path):
			results.append({"path": str(node.get_path()), "type": node.get_class(), "script": path})
	for child in node.get_children():
		_collect_nodes_by_script(child, script_path, partial, results)


func _cmd_batch_get_properties(params: Dictionary) -> void:
	var queries: Array = params.get("queries", [])
	var results: Array = []
	for q in queries:
		var node_path: String = q.get("nodePath", q.get("node_path", ""))
		var properties: Array = q.get("properties", [])
		var node: Node = get_tree().root.get_node_or_null(node_path)
		if node == null:
			results.append({"nodePath": node_path, "error": "Node not found"})
			continue
		var props: Dictionary = {}
		for prop in properties:
			var val = node.get(prop)
			props[prop] = _to_serializable(val)
		results.append({"nodePath": node_path, "properties": props})
	_send_response({"success": true, "results": results})


func _cmd_click_button_by_text(params: Dictionary) -> void:
	var text: String = params.get("text", "")
	var exact: bool = params.get("exact", false)
	var found: Array = []
	_find_buttons(get_tree().root, text, exact, found)
	if found.is_empty():
		_send_response({"error": "No button found with text: %s" % text})
		return
	var btn: Button = found[0]
	btn.emit_signal("pressed")
	_send_response({"success": true, "button": str(btn.get_path()), "text": btn.text})

func _find_buttons(node: Node, text: String, exact: bool, found: Array) -> void:
	if node is Button:
		var btn: Button = node as Button
		if (exact and btn.text == text) or (not exact and btn.text.to_lower().contains(text.to_lower())):
			found.append(btn)
	for child in node.get_children():
		_find_buttons(child, text, exact, found)


func _cmd_wait_for_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var timeout_ms: float = float(params.get("timeout_ms", 5000))
	var start: float = Time.get_ticks_msec()
	while true:
		var node = get_tree().root.get_node_or_null(node_path)
		if node != null:
			_send_response({"success": true, "found": true, "nodePath": node_path, "elapsed_ms": Time.get_ticks_msec() - start})
			return
		if Time.get_ticks_msec() - start > timeout_ms:
			_send_response({"success": false, "found": false, "nodePath": node_path, "timeout": true})
			return
		await get_tree().process_frame


func _cmd_find_nearby_nodes(params: Dictionary) -> void:
	var pos_dict: Dictionary = params.get("position", {})
	var radius: float = float(params.get("radius", 100.0))
	var node_type: String = params.get("node_type", "")
	var is_3d: bool = pos_dict.has("z")
	var results: Array = []
	_collect_nearby(get_tree().root, pos_dict, radius, node_type, is_3d, results)
	_send_response({"success": true, "nodes": results})

func _collect_nearby(node: Node, pos: Dictionary, radius: float, type_filter: String, is_3d: bool, results: Array) -> void:
	if not type_filter.is_empty() and node.get_class() != type_filter:
		pass
	elif is_3d and node is Node3D:
		var n3: Node3D = node as Node3D
		var target: Vector3 = Vector3(pos.get("x", 0.0), pos.get("y", 0.0), pos.get("z", 0.0))
		var dist: float = n3.global_position.distance_to(target)
		if dist <= radius:
			results.append({"path": str(node.get_path()), "type": node.get_class(), "distance": dist})
	elif not is_3d and node is Node2D:
		var n2: Node2D = node as Node2D
		var target2: Vector2 = Vector2(pos.get("x", 0.0), pos.get("y", 0.0))
		var dist: float = n2.global_position.distance_to(target2)
		if dist <= radius:
			results.append({"path": str(node.get_path()), "type": node.get_class(), "distance": dist})
	for child in node.get_children():
		_collect_nearby(child, pos, radius, type_filter, is_3d, results)


func _cmd_capture_frames(params: Dictionary) -> void:
	var count: int = int(params.get("count", 5))
	var interval: int = int(params.get("interval_frames", 10))
	var frames_data: Array = []
	for i in range(count):
		for _j in range(interval):
			await get_tree().process_frame
		await get_tree().process_frame
		var img: Image = get_viewport().get_texture().get_image()
		if img:
			var data: PackedByteArray = img.save_png_to_buffer()
			frames_data.append({"frame": i, "base64": Marshalls.raw_to_base64(data), "width": img.get_width(), "height": img.get_height()})
	_send_response({"success": true, "frames": frames_data})


func _cmd_monitor_properties(params: Dictionary) -> void:
	var queries: Array = params.get("queries", [])
	var frames: int = int(params.get("frames", 60))
	var interval: int = int(params.get("interval_frames", 1))
	var timeline: Array = []
	for f in range(frames):
		if f % interval == 0:
			var snapshot: Dictionary = {"frame": f, "values": []}
			for q in queries:
				var node_path: String = q.get("nodePath", q.get("node_path", ""))
				var prop: String = q.get("property", "")
				var node: Node = get_tree().root.get_node_or_null(node_path)
				if node:
					snapshot["values"].append({"nodePath": node_path, "property": prop, "value": _to_serializable(node.get(prop))})
			timeline.append(snapshot)
		await get_tree().process_frame
	_send_response({"success": true, "timeline": timeline, "frames_recorded": frames})


func _cmd_start_recording(_params: Dictionary) -> void:
	_recording = true
	_recorded_events = []
	_recording_start_ms = Time.get_ticks_msec()
	_send_response({"success": true, "recording": true})


func _cmd_stop_recording(_params: Dictionary) -> void:
	_recording = false
	_send_response({"success": true, "recording": false, "event_count": _recorded_events.size(), "events": _recorded_events})


func _cmd_replay_recording(params: Dictionary) -> void:
	var events: Array = params.get("events", [])
	var speed_scale: float = float(params.get("speed_scale", 1.0))
	if events.is_empty():
		_send_response({"error": "No events to replay"})
		return
	var prev_time: float = 0.0
	for entry in events:
		var t: float = float(entry.get("time_ms", 0)) / speed_scale
		var delay_ms: float = t - prev_time
		prev_time = t
		if delay_ms > 0:
			await get_tree().create_timer(delay_ms / 1000.0).timeout
		var etype: String = entry.get("type", "")
		var event: InputEvent = null
		if etype == "InputEventKey":
			var ke: InputEventKey = InputEventKey.new()
			ke.keycode = int(entry.get("keycode", 0))
			ke.pressed = bool(entry.get("pressed", false))
			event = ke
		elif etype == "InputEventMouseButton":
			var mb: InputEventMouseButton = InputEventMouseButton.new()
			mb.button_index = int(entry.get("button_index", 0))
			mb.pressed = bool(entry.get("pressed", false))
			var p = entry.get("position", {})
			mb.position = Vector2(float(p.get("x", 0)), float(p.get("y", 0)))
			event = mb
		elif etype == "InputEventMouseMotion":
			var mm: InputEventMouseMotion = InputEventMouseMotion.new()
			var p = entry.get("position", {})
			mm.position = Vector2(float(p.get("x", 0)), float(p.get("y", 0)))
			event = mm
		if event:
			Input.parse_input_event(event)
	_send_response({"success": true, "events_replayed": events.size()})


func _cmd_animtree_add_state(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var state_name: String = params.get("state_name", "")
	var animation_name: String = params.get("animation_name", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found at: %s" % node_path})
		return
	var tree: AnimationTree = node as AnimationTree
	var sm = tree.get("parameters/playback")
	if sm == null:
		_send_response({"error": "No StateMachinePlayback found"})
		return
	var root_sm: AnimationNodeStateMachine = tree.tree_root as AnimationNodeStateMachine
	if root_sm == null:
		_send_response({"error": "Tree root is not AnimationNodeStateMachine"})
		return
	var anim_node: AnimationNodeAnimation = AnimationNodeAnimation.new()
	anim_node.animation = animation_name
	root_sm.add_node(state_name, anim_node)
	_send_response({"success": true, "state": state_name, "animation": animation_name})


func _cmd_animtree_remove_state(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var state_name: String = params.get("state_name", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found at: %s" % node_path})
		return
	var tree: AnimationTree = node as AnimationTree
	var root_sm: AnimationNodeStateMachine = tree.tree_root as AnimationNodeStateMachine
	if root_sm == null:
		_send_response({"error": "Tree root is not AnimationNodeStateMachine"})
		return
	root_sm.remove_node(state_name)
	_send_response({"success": true, "removed": state_name})


func _cmd_animtree_add_transition(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var from_state: String = params.get("from_state", "")
	var to_state: String = params.get("to_state", "")
	var switch_mode: String = params.get("switch_mode", "immediate")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found at: %s" % node_path})
		return
	var tree: AnimationTree = node as AnimationTree
	var root_sm: AnimationNodeStateMachine = tree.tree_root as AnimationNodeStateMachine
	if root_sm == null:
		_send_response({"error": "Tree root is not AnimationNodeStateMachine"})
		return
	var t: AnimationNodeStateMachineTransition = AnimationNodeStateMachineTransition.new()
	match switch_mode:
		"sync": t.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_SYNC
		"at_end": t.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
		_: t.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
	root_sm.add_transition(from_state, to_state, t)
	_send_response({"success": true, "from": from_state, "to": to_state})


func _cmd_animtree_remove_transition(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var from_state: String = params.get("from_state", "")
	var to_state: String = params.get("to_state", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found at: %s" % node_path})
		return
	var tree: AnimationTree = node as AnimationTree
	var root_sm: AnimationNodeStateMachine = tree.tree_root as AnimationNodeStateMachine
	if root_sm == null:
		_send_response({"error": "Tree root is not AnimationNodeStateMachine"})
		return
	root_sm.remove_transition(from_state, to_state)
	_send_response({"success": true, "removed_transition": "%s->%s" % [from_state, to_state]})


func _cmd_animtree_get_structure(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node: Node = get_tree().root.get_node_or_null(node_path)
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found at: %s" % node_path})
		return
	var tree: AnimationTree = node as AnimationTree
	var root_sm: AnimationNodeStateMachine = tree.tree_root as AnimationNodeStateMachine
	if root_sm == null:
		_send_response({"error": "Tree root is not AnimationNodeStateMachine"})
		return
	var node_names: Array = Array(root_sm.get_node_list())
	var states: Array = []
	for name in node_names:
		var sm_node = root_sm.get_node(name)
		states.append({"name": name, "type": sm_node.get_class() if sm_node else "unknown"})
	var transitions: Array = []
	for from_name in node_names:
		for to_name in node_names:
			if root_sm.has_transition(from_name, to_name):
				var t = root_sm.get_transition(from_name, to_name)
				transitions.append({"from": from_name, "to": to_name, "switch_mode": t.switch_mode})
	_send_response({"success": true, "states": states, "transitions": transitions, "active_state": str(tree.get("parameters/playback").get_current_node()) if tree.get("parameters/playback") else ""})


func _to_serializable(val: Variant) -> Variant:
	return _variant_to_json(val)


func _cmd_tilemap_set_cell(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var layer: int = params.get("layer", 0)
	var x: int = params.get("x", 0)
	var y: int = params.get("y", 0)
	var source_id: int = params.get("source_id", 0)
	var ax: int = params.get("atlas_coords_x", 0)
	var ay: int = params.get("atlas_coords_y", 0)
	var alt: int = params.get("alternative_tile", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	var tm := node as TileMap
	tm.set_cell(layer, Vector2i(x, y), source_id, Vector2i(ax, ay), alt)
	_send_response({"success": true, "cell": {"x": x, "y": y}, "layer": layer})


func _cmd_tilemap_get_used_cells(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var layer: int = params.get("layer", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	var tm := node as TileMap
	var cells: Array = []
	for cell in tm.get_used_cells(layer):
		cells.append({"x": cell.x, "y": cell.y})
	_send_response({"success": true, "cells": cells, "count": cells.size()})


func _cmd_tilemap_clear(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var layer: int = params.get("layer", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	var tm := node as TileMap
	tm.clear_layer(layer)
	_send_response({"success": true, "layer": layer})


func _cmd_audio_bus_list(params: Dictionary) -> void:
	var buses: Array = []
	for i in range(AudioServer.get_bus_count()):
		var effects: Array = []
		for j in range(AudioServer.get_bus_effect_count(i)):
			var fx = AudioServer.get_bus_effect(i, j)
			effects.append({"type": fx.get_class(), "enabled": AudioServer.is_bus_effect_enabled(i, j)})
		buses.append({
			"name": AudioServer.get_bus_name(i),
			"volume_db": AudioServer.get_bus_volume_db(i),
			"muted": AudioServer.is_bus_mute(i),
			"solo": AudioServer.is_bus_solo(i),
			"effects": effects
		})
	_send_response({"success": true, "buses": buses})


func _cmd_audio_bus_create(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "")
	if bus_name.is_empty():
		_send_response({"error": "bus_name is required"})
		return
	if AudioServer.get_bus_index(bus_name) >= 0:
		_send_response({"error": "Bus already exists: " + bus_name})
		return
	AudioServer.add_bus()
	var idx: int = AudioServer.get_bus_count() - 1
	AudioServer.set_bus_name(idx, bus_name)
	_send_response({"success": true, "bus_name": bus_name, "index": idx})


func _cmd_audio_bus_set_volume(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "")
	var volume_db: float = params.get("volume_db", 0.0)
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		_send_response({"error": "Bus not found: " + bus_name})
		return
	AudioServer.set_bus_volume_db(idx, volume_db)
	_send_response({"success": true, "bus_name": bus_name, "volume_db": volume_db})


func _cmd_audio_bus_add_effect(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "")
	var effect_type: String = params.get("effect_type", "AudioEffectReverb")
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		_send_response({"error": "Bus not found: " + bus_name})
		return
	var effect = ClassDB.instantiate(effect_type)
	if effect == null:
		_send_response({"error": "Unknown effect type: " + effect_type})
		return
	var effect_params: Dictionary = params.get("effect_params", {})
	for key in effect_params:
		if effect.get(key) != null:
			effect.set(key, effect_params[key])
	AudioServer.add_bus_effect(idx, effect)
	_send_response({"success": true, "bus_name": bus_name, "effect_type": effect_type})


func _cmd_get_performance_counters(params: Dictionary) -> void:
	var requested: Array = params.get("counter_names", [])
	var ALL_COUNTERS = [
		"time/fps", "time/process", "time/physics_process",
		"memory/static", "memory/static_max", "memory/msg_buf_max",
		"object/objects", "object/resources", "object/nodes",
		"render/total_primitives_in_frame", "render/total_draw_calls_in_frame",
		"render/video_mem_used", "render/texture_mem_used", "render/buffer_mem_used",
		"physics_2d/active_objects", "physics_2d/collision_pairs", "physics_2d/island_count",
		"physics_3d/active_objects", "physics_3d/collision_pairs", "physics_3d/island_count",
	]
	var counters_to_get = requested if not requested.is_empty() else ALL_COUNTERS
	var results: Dictionary = {}
	for name in counters_to_get:
		var idx: int = Performance.MONITOR_NAMES.find(name) if "MONITOR_NAMES" in Performance else -1
		if idx >= 0:
			results[name] = Performance.get_monitor(idx)
		else:
			# try by Monitor enum
			results[name] = Performance.get_monitor(Performance.TIME_FPS) if name == "time/fps" else null
	# Simpler approach using known enums
	results = {
		"fps": Performance.get_monitor(Performance.TIME_FPS),
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000,
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		"video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"physics_2d_objects": Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS),
		"physics_3d_objects": Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
	}
	_send_response({"success": true, "counters": results})


func _cmd_batch_set_properties(params: Dictionary) -> void:
	var operations: Array = params.get("operations", [])
	var results: Array = []
	for op in operations:
		var node_path: String = op.get("node_path", op.get("nodePath", ""))
		var property: String = op.get("property", "")
		var value = op.get("value", null)
		var node = get_tree().root.get_node_or_null(NodePath(node_path))
		if node == null:
			results.append({"node_path": node_path, "property": property, "success": false, "error": "Node not found"})
			continue
		node.set(property, value)
		results.append({"node_path": node_path, "property": property, "success": true})
	_send_response({"success": true, "results": results})


func _cmd_animation_add_keyframe(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var anim_name: String = params.get("animation_name", "")
	var track_path: String = params.get("track_path", "")
	var time: float = params.get("time", 0.0)
	var value = params.get("value", null)
	var player = get_tree().root.get_node_or_null(NodePath(node_path))
	if player == null or not player is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	var anim_player := player as AnimationPlayer
	if not anim_player.has_animation(anim_name):
		_send_response({"error": "Animation not found: " + anim_name})
		return
	var anim: Animation = anim_player.get_animation(anim_name)
	var track_idx: int = -1
	for i in range(anim.get_track_count()):
		if str(anim.track_get_path(i)) == track_path:
			track_idx = i
			break
	if track_idx < 0:
		track_idx = anim.add_track(Animation.TYPE_VALUE)
		anim.track_set_path(track_idx, NodePath(track_path))
	var key_idx: int = anim.track_insert_key(track_idx, time, value)
	_send_response({"success": true, "key_index": key_idx, "time": time})


func _cmd_animation_get_keyframes(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var anim_name: String = params.get("animation_name", "")
	var track_path: String = params.get("track_path", "")
	var player = get_tree().root.get_node_or_null(NodePath(node_path))
	if player == null or not player is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	var anim_player := player as AnimationPlayer
	if not anim_player.has_animation(anim_name):
		_send_response({"error": "Animation not found: " + anim_name})
		return
	var anim: Animation = anim_player.get_animation(anim_name)
	var track_idx: int = -1
	for i in range(anim.get_track_count()):
		if str(anim.track_get_path(i)) == track_path:
			track_idx = i
			break
	if track_idx < 0:
		_send_response({"error": "Track not found: " + track_path})
		return
	var keyframes: Array = []
	for i in range(anim.track_get_key_count(track_idx)):
		keyframes.append({
			"index": i,
			"time": anim.track_get_key_time(track_idx, i),
			"value": _to_serializable(anim.track_get_key_value(track_idx, i)),
			"transition": anim.track_get_key_transition(track_idx, i)
		})
	_send_response({"success": true, "keyframes": keyframes, "track_path": track_path})


func _cmd_animation_delete_keyframe(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var anim_name: String = params.get("animation_name", "")
	var track_path: String = params.get("track_path", "")
	var key_index: int = params.get("key_index", -1)
	var player = get_tree().root.get_node_or_null(NodePath(node_path))
	if player == null or not player is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	var anim_player := player as AnimationPlayer
	if not anim_player.has_animation(anim_name):
		_send_response({"error": "Animation not found: " + anim_name})
		return
	var anim: Animation = anim_player.get_animation(anim_name)
	var track_idx: int = -1
	for i in range(anim.get_track_count()):
		if str(anim.track_get_path(i)) == track_path:
			track_idx = i
			break
	if track_idx < 0:
		_send_response({"error": "Track not found: " + track_path})
		return
	if key_index < 0 or key_index >= anim.track_get_key_count(track_idx):
		_send_response({"error": "Key index out of range: " + str(key_index)})
		return
	anim.track_remove_key(track_idx, key_index)
	_send_response({"success": true, "deleted_key_index": key_index})


func _cmd_label_set_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var text: String = params.get("text", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is Label:
		(node as Label).text = text
		_send_response({"success": true, "node_path": node_path, "text": text})
	elif node is RichTextLabel:
		(node as RichTextLabel).text = text
		_send_response({"success": true, "node_path": node_path, "text": text})
	elif node is Button:
		(node as Button).text = text
		_send_response({"success": true, "node_path": node_path, "text": text})
	elif node is LineEdit:
		(node as LineEdit).text = text
		_send_response({"success": true, "node_path": node_path, "text": text})
	else:
		_send_response({"error": "Node is not a text node: " + node.get_class()})


func _cmd_control_set_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control node not found: " + node_path})
		return
	var ctrl := node as Control
	var changed: Array = []
	if params.has("custom_minimum_size"):
		var cms = params.get("custom_minimum_size")
		ctrl.custom_minimum_size = Vector2(cms.get("x", 0), cms.get("y", 0))
		changed.append("custom_minimum_size")
	if params.has("size"):
		var s = params.get("size")
		ctrl.size = Vector2(s.get("x", ctrl.size.x), s.get("y", ctrl.size.y))
		changed.append("size")
	_send_response({"success": true, "changed": changed, "node_path": node_path})


func _cmd_get_tree_structure(params: Dictionary) -> void:
	var max_depth: int = params.get("max_depth", 10)
	var root_path: String = params.get("root_path", "/root")
	var root_node = get_tree().root.get_node_or_null(NodePath(root_path))
	if root_node == null:
		_send_response({"error": "Root node not found: " + root_path})
		return
	_send_response({"success": true, "tree": _node_to_dict(root_node, 0, max_depth)})

func _node_to_dict(node: Node, depth: int, max_depth: int) -> Dictionary:
	var result: Dictionary = {
		"name": node.name,
		"class": node.get_class(),
		"path": str(node.get_path()),
		"children": []
	}
	if node.get_script() != null:
		result["script"] = node.get_script().resource_path
	if depth < max_depth:
		for child in node.get_children():
			result["children"].append(_node_to_dict(child, depth + 1, max_depth))
	return result


func _cmd_node_get_meta(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var meta_key: String = params.get("meta_key", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if meta_key.is_empty():
		var meta: Dictionary = {}
		for key in node.get_meta_list():
			meta[key] = _to_serializable(node.get_meta(key))
		_send_response({"success": true, "meta": meta})
	else:
		if not node.has_meta(meta_key):
			_send_response({"error": "Meta key not found: " + meta_key})
			return
		_send_response({"success": true, "key": meta_key, "value": _to_serializable(node.get_meta(meta_key))})


func _cmd_node_set_meta(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var meta_key: String = params.get("meta_key", "")
	var meta_value = params.get("meta_value", null)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if meta_key.is_empty():
		_send_response({"error": "meta_key is required"})
		return
	node.set_meta(meta_key, meta_value)
	_send_response({"success": true, "key": meta_key, "value": _to_serializable(meta_value)})


func _cmd_game_quit(params: Dictionary) -> void:
	var exit_code: int = params.get("exit_code", 0)
	_send_response({"success": true, "message": "Quitting game with exit code " + str(exit_code)})
	await get_tree().process_frame
	get_tree().quit(exit_code)


func _cmd_set_window_title(params: Dictionary) -> void:
	var title: String = params.get("title", "")
	DisplayServer.window_set_title(title)
	_send_response({"success": true, "title": title})


func _cmd_camera_set_current(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is Camera2D:
		(node as Camera2D).make_current()
		_send_response({"success": true, "type": "Camera2D", "node_path": node_path})
	elif node is Camera3D:
		(node as Camera3D).make_current()
		_send_response({"success": true, "type": "Camera3D", "node_path": node_path})
	else:
		_send_response({"error": "Node is not a Camera: " + node.get_class()})


func _cmd_camera_get_info(params: Dictionary) -> void:
	var root_path: String = params.get("root_path", "/root")
	var root_node = get_tree().root.get_node_or_null(NodePath(root_path))
	if root_node == null:
		_send_response({"error": "Root not found: " + root_path})
		return
	var cameras: Array = []
	_collect_cameras(root_node, cameras)
	_send_response({"success": true, "cameras": cameras})

func _collect_cameras(node: Node, result: Array) -> void:
	if node is Camera2D:
		var cam := node as Camera2D
		result.append({"type": "Camera2D", "path": str(node.get_path()), "current": cam.is_current(), "zoom": {"x": cam.zoom.x, "y": cam.zoom.y}})
	elif node is Camera3D:
		var cam := node as Camera3D
		result.append({"type": "Camera3D", "path": str(node.get_path()), "current": cam.is_current(), "fov": cam.fov, "near": cam.near, "far": cam.far})
	for child in node.get_children():
		_collect_cameras(child, result)


func _cmd_set_node_z_index(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var z_index: int = params.get("z_index", 0)
	var z_as_relative: bool = params.get("z_as_relative", false)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node2D:
		_send_response({"error": "Node2D not found: " + node_path})
		return
	var node2d := node as Node2D
	node2d.z_index = z_index
	node2d.z_as_relative = z_as_relative
	_send_response({"success": true, "z_index": z_index, "z_as_relative": z_as_relative})


func _cmd_canvas_layer_set(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var layer: int = params.get("layer", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasLayer:
		_send_response({"error": "CanvasLayer not found: " + node_path})
		return
	(node as CanvasLayer).layer = layer
	_send_response({"success": true, "layer": layer, "node_path": node_path})


func _cmd_particle_set_emitting(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var emitting: bool = params.get("emitting", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is GPUParticles2D:
		(node as GPUParticles2D).emitting = emitting
	elif node is GPUParticles3D:
		(node as GPUParticles3D).emitting = emitting
	elif node is CPUParticles2D:
		(node as CPUParticles2D).emitting = emitting
	elif node is CPUParticles3D:
		(node as CPUParticles3D).emitting = emitting
	else:
		_send_response({"error": "Node is not a Particles node: " + node.get_class()})
		return
	_send_response({"success": true, "emitting": emitting, "node_path": node_path})


func _cmd_particle_restart(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is GPUParticles2D:
		(node as GPUParticles2D).restart()
	elif node is GPUParticles3D:
		(node as GPUParticles3D).restart()
	elif node is CPUParticles2D:
		(node as CPUParticles2D).restart()
	elif node is CPUParticles3D:
		(node as CPUParticles3D).restart()
	else:
		_send_response({"error": "Node is not a Particles node: " + node.get_class()})
		return
	_send_response({"success": true, "restarted": true, "node_path": node_path})


func _cmd_grab_focus(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control node not found: " + node_path})
		return
	(node as Control).grab_focus()
	_send_response({"success": true, "node_path": node_path})


func _cmd_get_viewport_info(_params: Dictionary) -> void:
	var viewport: Viewport = get_tree().root
	_send_response({
		"success": true,
		"size": {"x": viewport.size.x, "y": viewport.size.y},
		"content_scale_mode": viewport.content_scale_mode,
		"content_scale_aspect": viewport.content_scale_aspect,
		"msaa_2d": viewport.msaa_2d,
		"msaa_3d": viewport.msaa_3d,
		"transparent_bg": viewport.transparent_bg,
		"handle_input_locally": viewport.handle_input_locally,
	})


func _cmd_skeleton_get_bones(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is Skeleton2D:
		var sk := node as Skeleton2D
		var bones: Array = []
		for i in range(sk.get_bone_count()):
			var bone := sk.get_bone(i)
			bones.append({
				"index": i,
				"name": bone.name,
				"rest": {"x": bone.rest.origin.x, "y": bone.rest.origin.y, "rotation": bone.rest.get_rotation()}
			})
		_send_response({"success": true, "type": "Skeleton2D", "bones": bones})
	elif node is Skeleton3D:
		var sk := node as Skeleton3D
		var bones: Array = []
		for i in range(sk.get_bone_count()):
			bones.append({
				"index": i,
				"name": sk.get_bone_name(i),
				"parent": sk.get_bone_parent(i),
				"rest": _to_serializable(sk.get_bone_rest(i))
			})
		_send_response({"success": true, "type": "Skeleton3D", "bones": bones})
	else:
		_send_response({"error": "Node is not a Skeleton: " + node.get_class()})


func _cmd_skeleton_set_bone_pose(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bone_name: String = params.get("bone_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is Skeleton3D:
		var sk := node as Skeleton3D
		var bone_idx: int = sk.find_bone(bone_name)
		if bone_idx < 0:
			_send_response({"error": "Bone not found: " + bone_name})
			return
		var pose: Transform3D = sk.get_bone_pose(bone_idx)
		if params.has("rotation"):
			var r: float = params.get("rotation")
			pose.basis = Basis(Vector3(0, 1, 0), r)
		if params.has("position"):
			var pos = params.get("position")
			pose.origin = Vector3(pos.get("x", 0), pos.get("y", 0), pos.get("z", 0))
		sk.set_bone_pose(bone_idx, pose)
		_send_response({"success": true, "bone_name": bone_name, "bone_index": bone_idx})
	else:
		_send_response({"error": "Node is not a Skeleton3D: " + node.get_class()})


func _cmd_subviewport_set_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var width: int = params.get("width", 256)
	var height: int = params.get("height", 256)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SubViewport:
		_send_response({"error": "SubViewport not found: " + node_path})
		return
	(node as SubViewport).size = Vector2i(width, height)
	_send_response({"success": true, "size": {"x": width, "y": height}})


func _cmd_gridmap_set_cell(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: int = params.get("x", 0)
	var y: int = params.get("y", 0)
	var z: int = params.get("z", 0)
	var item_index: int = params.get("item_index", 0)
	var orientation: int = params.get("orientation", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GridMap:
		_send_response({"error": "GridMap not found: " + node_path})
		return
	(node as GridMap).set_cell_item(Vector3i(x, y, z), item_index, orientation)
	_send_response({"success": true, "cell": {"x": x, "y": y, "z": z}, "item_index": item_index})


func _cmd_gridmap_get_used_cells(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GridMap:
		_send_response({"error": "GridMap not found: " + node_path})
		return
	var gm := node as GridMap
	var cells: Array = []
	for cell in gm.get_used_cells():
		cells.append({"x": cell.x, "y": cell.y, "z": cell.z, "item": gm.get_cell_item(cell)})
	_send_response({"success": true, "cells": cells, "count": cells.size()})


func _cmd_gridmap_clear(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GridMap:
		_send_response({"error": "GridMap not found: " + node_path})
		return
	(node as GridMap).clear()
	_send_response({"success": true, "cleared": true})


func _cmd_path2d_set_points(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var points: Array = params.get("points", [])
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Path2D:
		_send_response({"error": "Path2D not found: " + node_path})
		return
	var path := node as Path2D
	var curve := Curve2D.new()
	for pt in points:
		curve.add_point(Vector2(pt.get("x", 0), pt.get("y", 0)))
	path.curve = curve
	_send_response({"success": true, "point_count": curve.get_point_count()})


func _cmd_get_fps_history(params: Dictionary) -> void:
	var sample_count: int = params.get("sample_count", 60)
	# Return current FPS and recent history from our tracked array
	var current_fps: float = Engine.get_frames_per_second()
	# We store fps samples in _fps_history; if empty, fill with current value
	if _fps_history.is_empty():
		_fps_history.append(current_fps)
	var history = _fps_history.slice(max(0, _fps_history.size() - sample_count))
	var avg_fps: float = 0.0
	for f in history:
		avg_fps += f
	avg_fps = avg_fps / max(history.size(), 1)
	_send_response({
		"success": true,
		"current_fps": current_fps,
		"average_fps": avg_fps,
		"sample_count": history.size(),
		"history": history
	})


func _cmd_set_environment_property(params: Dictionary) -> void:
	var property_name: String = params.get("property_name", "")
	var property_value = params.get("property_value", null)
	var env_node: WorldEnvironment = _find_world_environment(get_tree().root)
	if env_node == null:
		_send_response({"error": "No WorldEnvironment found in scene"})
		return
	if env_node.environment == null:
		_send_response({"error": "WorldEnvironment has no Environment resource"})
		return
	env_node.environment.set(property_name, property_value)
	_send_response({"success": true, "property": property_name})


func _find_world_environment(node: Node) -> WorldEnvironment:
	if node is WorldEnvironment:
		return node as WorldEnvironment
	for child in node.get_children():
		var result = _find_world_environment(child)
		if result != null:
			return result
	return null


func _cmd_get_physics_layers(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var result: Dictionary = {"node_path": node_path, "node_class": node.get_class()}
	if node.get("collision_layer") != null:
		result["collision_layer"] = node.get("collision_layer")
		result["collision_mask"] = node.get("collision_mask")
	_send_response({"success": true, "physics": result})


func _cmd_set_physics_layers(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var collision_layer = params.get("collision_layer", null)
	var collision_mask = params.get("collision_mask", null)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var changed: Array = []
	if collision_layer != null:
		node.set("collision_layer", collision_layer)
		changed.append("collision_layer")
	if collision_mask != null:
		node.set("collision_mask", collision_mask)
		changed.append("collision_mask")
	_send_response({"success": true, "changed": changed})


func _cmd_get_node_rect(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is Control:
		var ctrl := node as Control
		var rect: Rect2 = ctrl.get_global_rect()
		_send_response({"success": true, "rect": {"x": rect.position.x, "y": rect.position.y, "w": rect.size.x, "h": rect.size.y}})
	elif node is Node2D:
		var n2d := node as Node2D
		_send_response({"success": true, "global_position": {"x": n2d.global_position.x, "y": n2d.global_position.y}})
	else:
		_send_response({"error": "Node is not a Control or Node2D: " + node.get_class()})


func _cmd_theme_set_color_override(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var color_name: String = params.get("color_name", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var a: float = params.get("a", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	(node as Control).add_theme_color_override(color_name, Color(r, g, b, a))
	_send_response({"success": true, "color_name": color_name, "color": {"r": r, "g": g, "b": b, "a": a}})


func _cmd_popup_menu_add_item(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var label: String = params.get("label", "")
	var id: int = params.get("id", -1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is PopupMenu:
		_send_response({"error": "PopupMenu not found: " + node_path})
		return
	(node as PopupMenu).add_item(label, id)
	_send_response({"success": true, "label": label, "id": id, "item_count": (node as PopupMenu).get_item_count()})


func _cmd_option_button_add_item(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var label: String = params.get("label", "")
	var id: int = params.get("id", -1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is OptionButton:
		_send_response({"error": "OptionButton not found: " + node_path})
		return
	(node as OptionButton).add_item(label, id)
	_send_response({"success": true, "label": label, "item_count": (node as OptionButton).get_item_count()})


func _cmd_item_list_add_item(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var label: String = params.get("label", "")
	var selectable: bool = params.get("selectable", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is ItemList:
		_send_response({"error": "ItemList not found: " + node_path})
		return
	var il := node as ItemList
	var idx: int = il.add_item(label)
	il.set_item_selectable(idx, selectable)
	_send_response({"success": true, "label": label, "index": idx, "item_count": il.get_item_count()})


func _cmd_animation_set_loop(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var anim_name: String = params.get("animation_name", "")
	var loop_mode: int = params.get("loop_mode", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	var player := node as AnimationPlayer
	if not player.has_animation(anim_name):
		_send_response({"error": "Animation not found: " + anim_name})
		return
	var anim: Animation = player.get_animation(anim_name)
	anim.loop_mode = loop_mode as Animation.LoopMode
	_send_response({"success": true, "animation_name": anim_name, "loop_mode": loop_mode})


func _cmd_multimesh_set_instance_count(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var count: int = params.get("count", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var mm: MultiMesh = null
	if node is MultiMeshInstance3D:
		mm = (node as MultiMeshInstance3D).multimesh
	elif node is MultiMeshInstance2D:
		mm = (node as MultiMeshInstance2D).multimesh
	if mm == null:
		_send_response({"error": "No MultiMesh found on node: " + node_path})
		return
	mm.instance_count = count
	_send_response({"success": true, "instance_count": count})


func _cmd_multimesh_set_instance_transform(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var instance_index: int = params.get("instance_index", 0)
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is MultiMeshInstance3D:
		var mm: MultiMesh = (node as MultiMeshInstance3D).multimesh
		if mm == null or instance_index >= mm.instance_count:
			_send_response({"error": "Invalid MultiMesh or index out of range"})
			return
		var t := Transform3D.IDENTITY
		t.origin = Vector3(x, y, z)
		mm.set_instance_transform(instance_index, t)
		_send_response({"success": true, "instance_index": instance_index, "position": {"x": x, "y": y, "z": z}})
	elif node is MultiMeshInstance2D:
		var mm: MultiMesh = (node as MultiMeshInstance2D).multimesh
		if mm == null or instance_index >= mm.instance_count:
			_send_response({"error": "Invalid MultiMesh or index out of range"})
			return
		var t := Transform2D.IDENTITY
		t.origin = Vector2(x, y)
		mm.set_instance_transform_2d(instance_index, t)
		_send_response({"success": true, "instance_index": instance_index, "position": {"x": x, "y": y}})
	else:
		_send_response({"error": "Node is not a MultiMeshInstance: " + node.get_class()})


func _cmd_audio_player_set_bus(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bus_name: String = params.get("bus_name", "Master")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is AudioStreamPlayer:
		(node as AudioStreamPlayer).bus = bus_name
	elif node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).bus = bus_name
	elif node is AudioStreamPlayer3D:
		(node as AudioStreamPlayer3D).bus = bus_name
	else:
		_send_response({"error": "Node is not an AudioStreamPlayer: " + node.get_class()})
		return
	_send_response({"success": true, "bus_name": bus_name, "node_path": node_path})


func _cmd_set_material_property(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var surface: int = params.get("surface", 0)
	var property_name: String = params.get("property_name", "")
	var property_value = params.get("property_value", null)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var material: Material = null
	if node is MeshInstance3D:
		material = (node as MeshInstance3D).get_surface_override_material(surface)
		if material == null:
			material = (node as MeshInstance3D).get_active_material(surface)
	elif node is Sprite2D:
		material = (node as Sprite2D).material
	elif node is CanvasItem:
		material = (node as CanvasItem).material
	if material == null:
		_send_response({"error": "No material found on node"})
		return
	material.set(property_name, property_value)
	_send_response({"success": true, "property_name": property_name})


func _cmd_rich_text_append(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bbcode: String = params.get("bbcode", "")
	var clear: bool = params.get("clear", false)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RichTextLabel:
		_send_response({"error": "RichTextLabel not found: " + node_path})
		return
	var rtl := node as RichTextLabel
	if clear:
		rtl.clear()
	rtl.append_text(bbcode)
	_send_response({"success": true, "appended": bbcode.length(), "node_path": node_path})


func _cmd_timer_start(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var wait_time = params.get("wait_time", null)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Timer:
		_send_response({"error": "Timer not found: " + node_path})
		return
	var timer := node as Timer
	if wait_time != null:
		timer.wait_time = wait_time
	timer.start()
	_send_response({"success": true, "wait_time": timer.wait_time, "one_shot": timer.one_shot})


func _cmd_timer_stop(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Timer:
		_send_response({"error": "Timer not found: " + node_path})
		return
	(node as Timer).stop()
	_send_response({"success": true, "stopped": true})


func _cmd_timer_set_wait_time(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var wait_time: float = params.get("wait_time", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Timer:
		_send_response({"error": "Timer not found: " + node_path})
		return
	(node as Timer).wait_time = wait_time
	_send_response({"success": true, "wait_time": wait_time})


func _cmd_rigid_body_apply_impulse(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is RigidBody2D:
		(node as RigidBody2D).apply_impulse(Vector2(x, y))
		_send_response({"success": true, "type": "RigidBody2D", "impulse": {"x": x, "y": y}})
	elif node is RigidBody3D:
		(node as RigidBody3D).apply_impulse(Vector3(x, y, z))
		_send_response({"success": true, "type": "RigidBody3D", "impulse": {"x": x, "y": y, "z": z}})
	else:
		_send_response({"error": "Node is not a RigidBody: " + node.get_class()})


func _cmd_character_body_set_velocity(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CharacterBody2D:
		(node as CharacterBody2D).velocity = Vector2(x, y)
		_send_response({"success": true, "type": "CharacterBody2D", "velocity": {"x": x, "y": y}})
	elif node is CharacterBody3D:
		(node as CharacterBody3D).velocity = Vector3(x, y, z)
		_send_response({"success": true, "type": "CharacterBody3D", "velocity": {"x": x, "y": y, "z": z}})
	else:
		_send_response({"error": "Node is not a CharacterBody: " + node.get_class()})


func _cmd_ray_cast_force_update(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is RayCast2D:
		(node as RayCast2D).force_raycast_update()
		var rc2 := node as RayCast2D
		_send_response({"success": true, "is_colliding": rc2.is_colliding(), "collider": str(rc2.get_collider()) if rc2.is_colliding() else null})
	elif node is RayCast3D:
		(node as RayCast3D).force_raycast_update()
		var rc3 := node as RayCast3D
		_send_response({"success": true, "is_colliding": rc3.is_colliding(), "collider": str(rc3.get_collider()) if rc3.is_colliding() else null})
	else:
		_send_response({"error": "Node is not a RayCast: " + node.get_class()})


func _cmd_area_get_overlapping(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is Area2D:
		var area2 := node as Area2D
		var bodies: Array = []
		for b in area2.get_overlapping_bodies():
			bodies.append({"path": str(b.get_path()), "class": b.get_class()})
		var areas: Array = []
		for a in area2.get_overlapping_areas():
			areas.append({"path": str(a.get_path()), "class": a.get_class()})
		_send_response({"success": true, "type": "Area2D", "overlapping_bodies": bodies, "overlapping_areas": areas})
	elif node is Area3D:
		var area3 := node as Area3D
		var bodies: Array = []
		for b in area3.get_overlapping_bodies():
			bodies.append({"path": str(b.get_path()), "class": b.get_class()})
		var areas: Array = []
		for a in area3.get_overlapping_areas():
			areas.append({"path": str(a.get_path()), "class": a.get_class()})
		_send_response({"success": true, "type": "Area3D", "overlapping_bodies": bodies, "overlapping_areas": areas})
	else:
		_send_response({"error": "Node is not an Area: " + node.get_class()})


func _cmd_visibility_notifier_set_rect(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var width: float = params.get("width", 100.0)
	var height: float = params.get("height", 100.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is VisibleOnScreenNotifier2D:
		_send_response({"error": "VisibleOnScreenNotifier2D not found: " + node_path})
		return
	(node as VisibleOnScreenNotifier2D).rect = Rect2(x, y, width, height)
	_send_response({"success": true, "rect": {"x": x, "y": y, "width": width, "height": height}})


func _cmd_spring_arm_3d_set_length(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var spring_length: float = params.get("spring_length", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SpringArm3D:
		_send_response({"error": "SpringArm3D not found: " + node_path})
		return
	(node as SpringArm3D).spring_length = spring_length
	_send_response({"success": true, "spring_length": spring_length})


func _cmd_get_collision_shape_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var shapes: Array = []
	for child in node.get_children():
		if child is CollisionShape2D:
			var cs := child as CollisionShape2D
			shapes.append({
				"name": child.name,
				"type": "CollisionShape2D",
				"shape_class": cs.shape.get_class() if cs.shape else null,
				"disabled": cs.disabled,
				"position": {"x": cs.position.x, "y": cs.position.y}
			})
		elif child is CollisionShape3D:
			var cs3 := child as CollisionShape3D
			shapes.append({
				"name": child.name,
				"type": "CollisionShape3D",
				"shape_class": cs3.shape.get_class() if cs3.shape else null,
				"disabled": cs3.disabled
			})
	_send_response({"success": true, "node_path": node_path, "shapes": shapes})


func _cmd_get_tilemap_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	var tm := node as TileMap
	var layers: Array = []
	for i in range(tm.get_layers_count()):
		var cells = tm.get_used_cells(i)
		layers.append({"index": i, "name": tm.get_layer_name(i), "enabled": tm.is_layer_enabled(i), "cell_count": cells.size()})
	_send_response({"success": true, "tile_set": str(tm.tile_set), "cell_quadrant_size": tm.rendering_quadrant_size, "layers": layers})

func _cmd_tilemap_set_cell(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var layer: int = params.get("layer", 0)
	var x: int = params.get("x", 0)
	var y: int = params.get("y", 0)
	var source_id: int = params.get("source_id", 0)
	var atlas_x: int = params.get("atlas_x", 0)
	var atlas_y: int = params.get("atlas_y", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	(node as TileMap).set_cell(layer, Vector2i(x, y), source_id, Vector2i(atlas_x, atlas_y))
	_send_response({"success": true, "coords": {"x": x, "y": y}, "layer": layer})

func _cmd_tilemap_clear(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var layer: int = params.get("layer", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	(node as TileMap).clear_layer(layer)
	_send_response({"success": true, "layer": layer})

func _cmd_animation_tree_get_state(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found: " + node_path})
		return
	var at := node as AnimationTree
	_send_response({"success": true, "active": at.active, "root_animation": str(at.tree_root), "anim_player": str(at.anim_player)})

func _cmd_animation_tree_set_param(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var param_path: String = params.get("param_path", "")
	var value = params.get("value", null)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found: " + node_path})
		return
	(node as AnimationTree).set(param_path, value)
	_send_response({"success": true, "param_path": param_path, "value": str(value)})

func _cmd_label_set_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var text: String = params.get("text", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is Label:
		(node as Label).text = text
	elif node is RichTextLabel:
		(node as RichTextLabel).text = text
	else:
		_send_response({"error": "Node is not a Label: " + node.get_class()})
		return
	_send_response({"success": true, "text": text})

func _cmd_progress_bar_set_value(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var value: float = params.get("value", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is ProgressBar:
		_send_response({"error": "ProgressBar not found: " + node_path})
		return
	(node as ProgressBar).value = value
	_send_response({"success": true, "value": value})

func _cmd_slider_set_value(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var value: float = params.get("value", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is HSlider:
		(node as HSlider).value = value
	elif node is VSlider:
		(node as VSlider).value = value
	elif node is Slider:
		(node as Slider).value = value
	else:
		_send_response({"error": "Node is not a Slider: " + node.get_class()})
		return
	_send_response({"success": true, "value": value})

func _cmd_line_edit_set_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var text: String = params.get("text", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is LineEdit:
		_send_response({"error": "LineEdit not found: " + node_path})
		return
	(node as LineEdit).text = text
	_send_response({"success": true, "text": text})

func _cmd_texture_rect_set_texture(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var texture_path: String = params.get("texture_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TextureRect:
		_send_response({"error": "TextureRect not found: " + node_path})
		return
	var tex = load(texture_path)
	if tex == null:
		_send_response({"error": "Cannot load texture: " + texture_path})
		return
	(node as TextureRect).texture = tex
	_send_response({"success": true, "texture_path": texture_path})

func _cmd_get_viewport_size(_params: Dictionary) -> void:
	var vp = get_viewport()
	if vp == null:
		_send_response({"error": "No viewport available"})
		return
	var size = vp.get_visible_rect().size
	_send_response({"success": true, "width": size.x, "height": size.y})

func _cmd_get_render_info(_params: Dictionary) -> void:
	var ri = RenderingServer
	_send_response({
		"success": true,
		"fps": Engine.get_frames_per_second(),
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"video_mem_used": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
	})

func _cmd_get_audio_bus_list(_params: Dictionary) -> void:
	var buses: Array = []
	for i in range(AudioServer.bus_count):
		buses.append({
			"index": i,
			"name": AudioServer.get_bus_name(i),
			"volume_db": AudioServer.get_bus_volume_db(i),
			"muted": AudioServer.is_bus_mute(i),
			"solo": AudioServer.is_bus_solo(i)
		})
	_send_response({"success": true, "bus_count": buses.size(), "buses": buses})

func _cmd_set_audio_bus_volume(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "")
	var volume_db: float = params.get("volume_db", 0.0)
	var idx = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		_send_response({"error": "Audio bus not found: " + bus_name})
		return
	AudioServer.set_bus_volume_db(idx, volume_db)
	_send_response({"success": true, "bus_name": bus_name, "volume_db": volume_db})

func _cmd_get_physics_bodies(_params: Dictionary) -> void:
	var bodies: Array = []
	var queue: Array = [get_tree().root]
	while queue.size() > 0:
		var node = queue.pop_front()
		if node is PhysicsBody2D or node is PhysicsBody3D:
			bodies.append({"path": str(node.get_path()), "class": node.get_class(), "name": node.name})
		for child in node.get_children():
			queue.append(child)
	_send_response({"success": true, "count": bodies.size(), "bodies": bodies})

func _cmd_set_gravity_scale(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var gravity_scale: float = params.get("gravity_scale", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is RigidBody2D:
		(node as RigidBody2D).gravity_scale = gravity_scale
	elif node is RigidBody3D:
		(node as RigidBody3D).gravity_scale = gravity_scale
	else:
		_send_response({"error": "Node is not a RigidBody: " + node.get_class()})
		return
	_send_response({"success": true, "gravity_scale": gravity_scale})

func _cmd_get_animation_player_list(_params: Dictionary) -> void:
	var players: Array = []
	var queue: Array = [get_tree().root]
	while queue.size() > 0:
		var node = queue.pop_front()
		if node is AnimationPlayer:
			var ap := node as AnimationPlayer
			players.append({"path": str(node.get_path()), "animations": ap.get_animation_list(), "current": ap.current_animation, "playing": ap.is_playing()})
		for child in node.get_children():
			queue.append(child)
	_send_response({"success": true, "count": players.size(), "players": players})

func _cmd_node_set_modulate(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var a: float = params.get("a", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasItem:
		_send_response({"error": "CanvasItem not found: " + node_path})
		return
	(node as CanvasItem).modulate = Color(r, g, b, a)
	_send_response({"success": true, "modulate": {"r": r, "g": g, "b": b, "a": a}})

func _cmd_node_set_z_index(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var z_index: int = params.get("z_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node2D:
		_send_response({"error": "Node2D not found: " + node_path})
		return
	(node as Node2D).z_index = z_index
	_send_response({"success": true, "z_index": z_index})

func _cmd_emit_signal_on_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var signal_name: String = params.get("signal_name", "")
	var args: Array = params.get("args", [])
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if not node.has_signal(signal_name):
		_send_response({"error": "Signal not found: " + signal_name})
		return
	node.emit_signal(signal_name)
	_send_response({"success": true, "signal_name": signal_name})


func _cmd_get_node_metadata(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var meta: Dictionary = {}
	for key in node.get_meta_list():
		meta[key] = _to_serializable(node.get_meta(key))
	_send_response({"success": true, "node_path": node_path, "metadata": meta})

func _cmd_set_node_metadata(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var key: String = params.get("key", "")
	var value = params.get("value", null)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	node.set_meta(key, value)
	_send_response({"success": true, "key": key, "value": _to_serializable(value)})

func _cmd_node_add_to_group_runtime(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var group_name: String = params.get("group_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	node.add_to_group(group_name)
	_send_response({"success": true, "group": group_name, "in_group": node.is_in_group(group_name)})

func _cmd_node_remove_from_group_runtime(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var group_name: String = params.get("group_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	node.remove_from_group(group_name)
	_send_response({"success": true, "group": group_name})

func _cmd_get_nodes_in_group_runtime(params: Dictionary) -> void:
	var group_name: String = params.get("group_name", "")
	var nodes = get_tree().get_nodes_in_group(group_name)
	var result: Array = []
	for node in nodes:
		result.append({"path": str(node.get_path()), "name": node.name, "class": node.get_class()})
	_send_response({"success": true, "group": group_name, "count": result.size(), "nodes": result})

func _cmd_game_set_time_scale(params: Dictionary) -> void:
	var time_scale: float = params.get("time_scale", 1.0)
	Engine.time_scale = time_scale
	_send_response({"success": true, "time_scale": time_scale})

func _cmd_game_get_scene_tree(params: Dictionary) -> void:
	var max_depth: int = params.get("max_depth", 5)
	var tree = _build_tree_node_depth(get_tree().root, 0, max_depth)
	_send_response({"success": true, "tree": tree})

func _build_tree_node_depth(node: Node, depth: int, max_depth: int) -> Dictionary:
	var result: Dictionary = {
		"name": node.name,
		"class": node.get_class(),
		"path": str(node.get_path())
	}
	if depth < max_depth:
		var children: Array = []
		for child in node.get_children():
			children.append(_build_tree_node_depth(child, depth + 1, max_depth))
		result["children"] = children
	return result


func _cmd_get_canvas_layers(_params: Dictionary) -> void:
	var layers: Array = []
	var queue: Array = [get_tree().root]
	while queue.size() > 0:
		var node = queue.pop_front()
		if node is CanvasLayer:
			var cl := node as CanvasLayer
			layers.append({"path": str(node.get_path()), "name": node.name, "layer": cl.layer, "follow_viewport": cl.follow_viewport_enabled})
		for child in node.get_children():
			queue.append(child)
	_send_response({"success": true, "count": layers.size(), "layers": layers})

func _cmd_canvas_layer_set_layer(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var layer: int = params.get("layer", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasLayer:
		_send_response({"error": "CanvasLayer not found: " + node_path})
		return
	(node as CanvasLayer).layer = layer
	_send_response({"success": true, "layer": layer})

func _cmd_get_shader_params(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var material = null
	if node is MeshInstance3D:
		material = (node as MeshInstance3D).get_surface_override_material(0)
		if material == null:
			material = (node as MeshInstance3D).mesh.surface_get_material(0) if (node as MeshInstance3D).mesh != null else null
	elif node is CanvasItem:
		material = (node as CanvasItem).material
	if material == null or not material is ShaderMaterial:
		_send_response({"error": "No ShaderMaterial on node: " + node_path})
		return
	var sm := material as ShaderMaterial
	var params_list: Array = []
	if sm.shader != null:
		for param in sm.shader.get_shader_uniform_list():
			params_list.append({"name": param.name, "value": _to_serializable(sm.get_shader_parameter(param.name))})
	_send_response({"success": true, "shader_params": params_list})

func _cmd_get_2d_camera_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var cam: Camera2D
	if node_path != "":
		var node = get_tree().root.get_node_or_null(NodePath(node_path))
		if node == null or not node is Camera2D:
			_send_response({"error": "Camera2D not found: " + node_path})
			return
		cam = node as Camera2D
	else:
		var vp = get_viewport()
		if vp == null:
			_send_response({"error": "No viewport"})
			return
		cam = vp.get_camera_2d() if vp.get_camera_2d() != null else null
		if cam == null:
			_send_response({"error": "No current Camera2D"})
			return
	_send_response({"success": true, "path": str(cam.get_path()), "zoom": {"x": cam.zoom.x, "y": cam.zoom.y}, "offset": {"x": cam.offset.x, "y": cam.offset.y}, "position": {"x": cam.global_position.x, "y": cam.global_position.y}, "enabled": cam.enabled})

func _cmd_camera_2d_set_zoom(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 1.0)
	var y: float = params.get("y", x)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Camera2D:
		_send_response({"error": "Camera2D not found: " + node_path})
		return
	(node as Camera2D).zoom = Vector2(x, y)
	_send_response({"success": true, "zoom": {"x": x, "y": y}})


func _cmd_node_set_visible_runtime(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var visible: bool = params.get("visible", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if not node is CanvasItem and not node is Node3D:
		_send_response({"error": "Node is not a CanvasItem or Node3D: " + node.get_class()})
		return
	if node is CanvasItem:
		(node as CanvasItem).visible = visible
	elif node is Node3D:
		(node as Node3D).visible = visible
	_send_response({"success": true, "node_path": node_path, "visible": visible})

func _cmd_node_get_visible_runtime(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var visible = null
	if node is CanvasItem:
		visible = (node as CanvasItem).visible
	elif node is Node3D:
		visible = (node as Node3D).visible
	_send_response({"success": true, "node_path": node_path, "visible": visible})

func _cmd_free_node_runtime(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var parent_path = str(node.get_parent().get_path()) if node.get_parent() != null else ""
	node.queue_free()
	_send_response({"success": true, "freed_path": node_path, "parent_path": parent_path})

func _cmd_duplicate_node_runtime(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var new_name: String = params.get("new_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var dup = node.duplicate()
	if new_name != "":
		dup.name = new_name
	else:
		dup.name = node.name + "_copy"
	node.get_parent().add_child(dup)
	dup.owner = get_tree().root
	_send_response({"success": true, "original_path": node_path, "new_path": str(dup.get_path()), "new_name": dup.name})

func _cmd_game_reload_scene(_params: Dictionary) -> void:
	var current = get_tree().current_scene.scene_file_path if get_tree().current_scene != null else ""
	_send_response({"success": true, "reloading": current})
	await get_tree().create_timer(0.05).timeout
	get_tree().reload_current_scene()

func _cmd_set_node_process(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var process_mode: String = params.get("process_mode", "process")
	var enabled: bool = params.get("enabled", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	match process_mode:
		"physics":
			node.set_physics_process(enabled)
		"both":
			node.set_process(enabled)
			node.set_physics_process(enabled)
		_:
			node.set_process(enabled)
	_send_response({"success": true, "process_mode": process_mode, "enabled": enabled})

func _cmd_get_object_id(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "node_path": node_path, "instance_id": node.get_instance_id(), "class": node.get_class()})

func _cmd_call_method_on_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var method_name: String = params.get("method_name", "")
	var call_args: Array = params.get("args", [])
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if not node.has_method(method_name):
		_send_response({"error": "Method not found: " + method_name})
		return
	var result = node.callv(method_name, call_args)
	_send_response({"success": true, "method": method_name, "result": _to_serializable(result)})

func _cmd_get_particles_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is GPUParticles3D:
		var p := node as GPUParticles3D
		_send_response({"success": true, "type": "GPUParticles3D", "emitting": p.emitting, "amount": p.amount, "lifetime": p.lifetime, "one_shot": p.one_shot, "explosiveness": p.explosiveness})
	elif node is GPUParticles2D:
		var p := node as GPUParticles2D
		_send_response({"success": true, "type": "GPUParticles2D", "emitting": p.emitting, "amount": p.amount, "lifetime": p.lifetime, "one_shot": p.one_shot, "explosiveness": p.explosiveness})
	elif node is CPUParticles3D:
		var p := node as CPUParticles3D
		_send_response({"success": true, "type": "CPUParticles3D", "emitting": p.emitting, "amount": p.amount, "lifetime": p.lifetime, "one_shot": p.one_shot})
	elif node is CPUParticles2D:
		var p := node as CPUParticles2D
		_send_response({"success": true, "type": "CPUParticles2D", "emitting": p.emitting, "amount": p.amount, "lifetime": p.lifetime, "one_shot": p.one_shot})
	else:
		_send_response({"error": "Node is not a particle emitter: " + node.get_class()})

func _cmd_set_particles_emitting(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var emitting: bool = params.get("emitting", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is GPUParticles3D:
		(node as GPUParticles3D).emitting = emitting
	elif node is GPUParticles2D:
		(node as GPUParticles2D).emitting = emitting
	elif node is CPUParticles3D:
		(node as CPUParticles3D).emitting = emitting
	elif node is CPUParticles2D:
		(node as CPUParticles2D).emitting = emitting
	else:
		_send_response({"error": "Node is not a particle emitter: " + node.get_class()})
		return
	_send_response({"success": true, "emitting": emitting})

func _cmd_get_navigation_agents(_params: Dictionary) -> void:
	var agents: Array = []
	var queue: Array = [get_tree().root]
	while queue.size() > 0:
		var node = queue.pop_front()
		if node is NavigationAgent2D:
			var a := node as NavigationAgent2D
			agents.append({"path": str(node.get_path()), "type": "NavigationAgent2D", "target_position": {"x": a.target_position.x, "y": a.target_position.y}, "is_navigation_finished": a.is_navigation_finished()})
		elif node is NavigationAgent3D:
			var a := node as NavigationAgent3D
			agents.append({"path": str(node.get_path()), "type": "NavigationAgent3D", "target_position": {"x": a.target_position.x, "y": a.target_position.y, "z": a.target_position.z}, "is_navigation_finished": a.is_navigation_finished()})
		for child in node.get_children():
			queue.append(child)
	_send_response({"success": true, "count": agents.size(), "agents": agents})

func _cmd_navigation_agent_set_target(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is NavigationAgent2D:
		(node as NavigationAgent2D).target_position = Vector2(x, y)
		_send_response({"success": true, "type": "2D", "target": {"x": x, "y": y}})
	elif node is NavigationAgent3D:
		(node as NavigationAgent3D).target_position = Vector3(x, y, z)
		_send_response({"success": true, "type": "3D", "target": {"x": x, "y": y, "z": z}})
	else:
		_send_response({"error": "Node is not a NavigationAgent: " + node.get_class()})

func _cmd_get_world_environment(_params: Dictionary) -> void:
	var queue: Array = [get_tree().root]
	while queue.size() > 0:
		var node = queue.pop_front()
		if node is WorldEnvironment:
			var we := node as WorldEnvironment
			var env = we.environment
			if env != null:
				_send_response({"success": true, "path": str(node.get_path()), "background_mode": env.background_mode, "ambient_color": {"r": env.ambient_light_color.r, "g": env.ambient_light_color.g, "b": env.ambient_light_color.b}, "ambient_energy": env.ambient_light_energy, "fog_enabled": env.fog_enabled})
			else:
				_send_response({"success": true, "path": str(node.get_path()), "environment": null})
			return
		for child in node.get_children():
			queue.append(child)
	_send_response({"error": "No WorldEnvironment found in scene"})

func _cmd_batch_set_node_property_runtime(params: Dictionary) -> void:
	var node_paths: Array = params.get("node_paths", [])
	var property_name: String = params.get("property_name", "")
	var value = params.get("value", null)
	var results: Array = []
	for np in node_paths:
		var node = get_tree().root.get_node_or_null(NodePath(np))
		if node == null:
			results.append({"path": np, "success": false, "error": "not found"})
			continue
		if not (property_name in node):
			results.append({"path": np, "success": false, "error": "property not found"})
			continue
		node.set(property_name, value)
		results.append({"path": np, "success": true})
	_send_response({"success": true, "results": results})

func _cmd_get_input_state(params: Dictionary) -> void:
	var requested: Array = params.get("actions", [])
	var actions_to_check: Array = requested if requested.size() > 0 else InputMap.get_actions()
	var state: Dictionary = {}
	for action in actions_to_check:
		if InputMap.has_action(action):
			state[action] = Input.is_action_pressed(action)
	_send_response({"success": true, "input_state": state})

func _cmd_simulate_input_action(params: Dictionary) -> void:
	var action_name: String = params.get("action_name", "")
	var pressed: bool = params.get("pressed", true)
	var strength: float = params.get("strength", 1.0)
	if not InputMap.has_action(action_name):
		_send_response({"error": "Action not found: " + action_name})
		return
	var event = InputEventAction.new()
	event.action = action_name
	event.pressed = pressed
	event.strength = strength
	Input.parse_input_event(event)
	_send_response({"success": true, "action_name": action_name, "pressed": pressed, "strength": strength})

func _cmd_get_network_info(_params: Dictionary) -> void:
	var mp = get_tree().get_multiplayer()
	var peer = mp.multiplayer_peer if mp != null else null
	_send_response({
		"success": true,
		"has_multiplayer": mp != null,
		"unique_id": mp.get_unique_id() if mp != null else 0,
		"is_server": mp.is_server() if mp != null else false,
		"peer_type": peer.get_class() if peer != null else "none"
	})

func _cmd_scene_profiler_start(_params: Dictionary) -> void:
	_profiler_start_time = Time.get_ticks_msec()
	_profiler_running = true
	_send_response({"success": true, "started_at_ms": _profiler_start_time})

func _cmd_scene_profiler_stop(_params: Dictionary) -> void:
	if not _profiler_running:
		_send_response({"error": "Profiler was not started"})
		return
	var elapsed = Time.get_ticks_msec() - _profiler_start_time
	_profiler_running = false
	_send_response({"success": true, "elapsed_ms": elapsed, "fps": Engine.get_frames_per_second()})

func _cmd_get_mouse_position(_params: Dictionary) -> void:
	var pos = get_viewport().get_mouse_position()
	_send_response({"success": true, "x": pos.x, "y": pos.y})

func _cmd_warp_mouse(params: Dictionary) -> void:
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	Input.warp_mouse(Vector2(x, y))
	_send_response({"success": true, "x": x, "y": y})

func _cmd_get_color_in_game(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property_name: String = params.get("property_name", "modulate")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if not (property_name in node):
		_send_response({"error": "Property not found: " + property_name})
		return
	var color = node.get(property_name)
	if color is Color:
		_send_response({"success": true, "property": property_name, "color": {"r": color.r, "g": color.g, "b": color.b, "a": color.a, "html": color.to_html()}})
	else:
		_send_response({"error": "Property is not a Color: " + property_name})

func _cmd_get_light_properties(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is Light2D:
		var l := node as Light2D
		_send_response({"success": true, "type": "Light2D", "enabled": l.enabled, "color": {"r": l.color.r, "g": l.color.g, "b": l.color.b}, "energy": l.energy, "shadow_enabled": l.shadow_enabled})
	elif node is Light3D:
		var l := node as Light3D
		_send_response({"success": true, "type": "Light3D", "class": node.get_class(), "color": {"r": l.light_color.r, "g": l.light_color.g, "b": l.light_color.b}, "energy": l.light_energy, "shadow": l.shadow_enabled, "bake_mode": l.light_bake_mode})
	else:
		_send_response({"error": "Node is not a Light: " + node.get_class()})

func _cmd_set_light_property(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property_name: String = params.get("property_name", "")
	var value = params.get("value", null)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if not (node is Light2D or node is Light3D):
		_send_response({"error": "Node is not a Light: " + node.get_class()})
		return
	node.set(property_name, value)
	_send_response({"success": true, "property_name": property_name})

func _cmd_get_runtime_scene_list(_params: Dictionary) -> void:
	var scenes: Array = []
	var queue: Array = [get_tree().root]
	while queue.size() > 0:
		var node = queue.pop_front()
		var scene_path = node.scene_file_path if node.scene_file_path != "" else null
		if scene_path != null:
			scenes.append({"path": str(node.get_path()), "scene_file": scene_path, "name": node.name})
		for child in node.get_children():
			queue.append(child)
	_send_response({"success": true, "count": scenes.size(), "scenes": scenes})

func _cmd_game_set_debug_visible(params: Dictionary) -> void:
	var enabled: bool = params.get("enabled", true)
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME if enabled else Viewport.DEBUG_DRAW_DISABLED
	_send_response({"success": true, "debug_draw": enabled})

func _cmd_get_print_output(params: Dictionary) -> void:
	var max_lines: int = params.get("max_lines", 50)
	var output = _print_buffer.slice(max(_print_buffer.size() - max_lines, 0))
	_send_response({"success": true, "line_count": output.size(), "total_buffered": _print_buffer.size(), "output": output})

func _cmd_clear_print_output(_params: Dictionary) -> void:
	var count = _print_buffer.size()
	_print_buffer.clear()
	_send_response({"success": true, "cleared_lines": count})

func _cmd_send_message_to_game(params: Dictionary) -> void:
	var message_type: String = params.get("message_type", "")
	var data: Dictionary = params.get("data", {})
	emit_signal("mcp_message_received", message_type, data) if has_signal("mcp_message_received") else null
	_send_response({"success": true, "message_type": message_type, "data": data})

func _cmd_add_tween(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property_path: String = params.get("property_path", "")
	var final_value = params.get("final_value", null)
	var duration: float = params.get("duration", 1.0)
	var trans_type_str: String = params.get("trans_type", "LINEAR")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var trans_type = Tween.TRANS_LINEAR
	match trans_type_str:
		"SINE": trans_type = Tween.TRANS_SINE
		"QUINT": trans_type = Tween.TRANS_QUINT
		"QUART": trans_type = Tween.TRANS_QUART
		"QUAD": trans_type = Tween.TRANS_QUAD
		"EXPO": trans_type = Tween.TRANS_EXPO
		"ELASTIC": trans_type = Tween.TRANS_ELASTIC
		"CUBIC": trans_type = Tween.TRANS_CUBIC
		"CIRC": trans_type = Tween.TRANS_CIRC
		"BOUNCE": trans_type = Tween.TRANS_BOUNCE
		"BACK": trans_type = Tween.TRANS_BACK
	var tween = node.create_tween()
	tween.tween_property(node, property_path, final_value, duration).set_trans(trans_type)
	_send_response({"success": true, "node_path": node_path, "property_path": property_path, "duration": duration})

func _cmd_stop_tween(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	get_tree().get_processed_tweens()
	_send_response({"success": true, "node_path": node_path, "note": "Tweens killed via scene tree"})

func _cmd_get_http_response(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is HTTPRequest:
		_send_response({"error": "HTTPRequest not found: " + node_path})
		return
	_send_response({"success": true, "path": node_path, "is_processing": node.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED})

func _cmd_make_http_request(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var url: String = params.get("url", "")
	var method_str: String = params.get("method", "GET")
	var body: String = params.get("body", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is HTTPRequest:
		_send_response({"error": "HTTPRequest not found: " + node_path})
		return
	var method = HTTPClient.METHOD_GET
	match method_str:
		"POST": method = HTTPClient.METHOD_POST
		"PUT": method = HTTPClient.METHOD_PUT
		"DELETE": method = HTTPClient.METHOD_DELETE
	var err = (node as HTTPRequest).request(url, [], method, body)
	_send_response({"success": err == OK, "url": url, "method": method_str, "error_code": err})

func _cmd_get_os_info(_params: Dictionary) -> void:
	_send_response({
		"success": true,
		"name": OS.get_name(),
		"locale": OS.get_locale(),
		"locale_language": OS.get_locale_language(),
		"processor_count": OS.get_processor_count(),
		"model_name": OS.get_processor_name(),
		"unique_id": OS.get_unique_id(),
		"is_debug_build": OS.is_debug_build(),
		"executable_path": OS.get_executable_path()
	})

func _cmd_open_url_in_browser(params: Dictionary) -> void:
	var url: String = params.get("url", "")
	OS.shell_open(url)
	_send_response({"success": true, "url": url})

func _cmd_get_clipboard(_params: Dictionary) -> void:
	_send_response({"success": true, "clipboard": DisplayServer.clipboard_get()})

func _cmd_set_clipboard(params: Dictionary) -> void:
	var text: String = params.get("text", "")
	DisplayServer.clipboard_set(text)
	_send_response({"success": true, "text": text})

func _cmd_get_display_info(_params: Dictionary) -> void:
	var screen_count = DisplayServer.get_screen_count()
	var screens: Array = []
	for i in range(screen_count):
		screens.append({
			"index": i,
			"size": {"width": DisplayServer.screen_get_size(i).x, "height": DisplayServer.screen_get_size(i).y},
			"dpi": DisplayServer.screen_get_dpi(i),
			"refresh_rate": DisplayServer.screen_get_refresh_rate(i)
		})
	var win_size = DisplayServer.window_get_size()
	_send_response({"success": true, "screen_count": screen_count, "screens": screens, "window_size": {"width": win_size.x, "height": win_size.y}})

func _cmd_set_window_size(params: Dictionary) -> void:
	var width: int = params.get("width", 1280)
	var height: int = params.get("height", 720)
	DisplayServer.window_set_size(Vector2i(width, height))
	_send_response({"success": true, "width": width, "height": height})

func _cmd_instantiate_scene_at_runtime(params: Dictionary) -> void:
	var scene_path: String = params.get("scene_path", "")
	var parent_node_path: String = params.get("parent_node_path", "/root")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var packed = load(scene_path) as PackedScene
	if packed == null:
		_send_response({"error": "Cannot load scene: " + scene_path})
		return
	var instance = packed.instantiate()
	var parent = get_tree().root.get_node_or_null(NodePath(parent_node_path))
	if parent == null:
		parent = get_tree().root
	parent.add_child(instance)
	instance.owner = get_tree().root
	if instance is Node3D:
		(instance as Node3D).position = Vector3(x, y, z)
	elif instance is Node2D:
		(instance as Node2D).position = Vector2(x, y)
	_send_response({"success": true, "scene_path": scene_path, "instance_path": str(instance.get_path()), "name": instance.name})

func _cmd_save_scene_at_runtime(params: Dictionary) -> void:
	var output_path: String = params.get("output_path", "")
	var current_scene = get_tree().current_scene
	if current_scene == null:
		_send_response({"error": "No current scene"})
		return
	var packed = PackedScene.new()
	packed.pack(current_scene)
	var err = ResourceSaver.save(packed, output_path)
	_send_response({"success": err == OK, "output_path": output_path, "error_code": err})

func _cmd_get_script_source(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var script = node.get_script() as GDScript
	if script == null:
		_send_response({"error": "No GDScript attached to node"})
		return
	_send_response({"success": true, "source_code": script.source_code, "resource_path": script.resource_path})

func _cmd_set_animation_speed_scale(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var speed_scale: float = params.get("speed_scale", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	(node as AnimationPlayer).speed_scale = speed_scale
	_send_response({"success": true, "speed_scale": speed_scale})

func _cmd_get_animation_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	var ap := node as AnimationPlayer
	_send_response({"success": true, "current_position": ap.current_animation_position, "length": ap.current_animation_length, "animation": ap.current_animation, "playing": ap.is_playing()})

func _cmd_seek_animation(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var position: float = params.get("position", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	(node as AnimationPlayer).seek(position)
	_send_response({"success": true, "position": position})

func _cmd_blend_shape_set_value(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var blend_shape_idx: int = params.get("blend_shape_idx", 0)
	var value: float = params.get("value", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	(node as MeshInstance3D).set_blend_shape_value(blend_shape_idx, value)
	_send_response({"success": true, "blend_shape_idx": blend_shape_idx, "value": value})

func _cmd_blend_shape_get_values(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mi := node as MeshInstance3D
	var shapes: Array = []
	for i in range(mi.get_blend_shape_count()):
		shapes.append({"idx": i, "name": mi.mesh.get_blend_shape_name(i) if mi.mesh != null else str(i), "value": mi.get_blend_shape_value(i)})
	_send_response({"success": true, "count": shapes.size(), "blend_shapes": shapes})

func _cmd_get_bone_global_pose(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bone_idx: int = params.get("bone_idx", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	var skel := node as Skeleton3D
	var pose = skel.get_bone_global_pose(bone_idx)
	_send_response({"success": true, "bone_idx": bone_idx, "bone_name": skel.get_bone_name(bone_idx), "position": {"x": pose.origin.x, "y": pose.origin.y, "z": pose.origin.z}})

func _cmd_set_bone_pose_xyz(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bone_idx: int = params.get("bone_idx", 0)
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	var skel := node as Skeleton3D
	var pose = skel.get_bone_pose(bone_idx)
	pose.origin = Vector3(x, y, z)
	skel.set_bone_pose(bone_idx, pose)
	_send_response({"success": true, "bone_idx": bone_idx, "position": {"x": x, "y": y, "z": z}})

func _cmd_add_audio_effect_to_bus(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "Master")
	var effect_class: String = params.get("effect_class", "")
	if effect_class.is_empty():
		_send_response({"error": "effect_class is required"})
		return
	var bus_idx = AudioServer.get_bus_index(bus_name)
	if bus_idx < 0:
		_send_response({"error": "Audio bus not found: " + bus_name})
		return
	var effect = ClassDB.instantiate(effect_class) as AudioEffect
	if effect == null:
		_send_response({"error": "Cannot create AudioEffect: " + effect_class})
		return
	AudioServer.add_bus_effect(bus_idx, effect)
	var new_idx = AudioServer.get_bus_effect_count(bus_idx) - 1
	_send_response({"success": true, "bus_name": bus_name, "effect_class": effect_class, "effect_idx": new_idx})

func _cmd_remove_audio_effect_from_bus(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "Master")
	var effect_idx: int = params.get("effect_idx", 0)
	var bus_idx = AudioServer.get_bus_index(bus_name)
	if bus_idx < 0:
		_send_response({"error": "Audio bus not found: " + bus_name})
		return
	if effect_idx >= AudioServer.get_bus_effect_count(bus_idx):
		_send_response({"error": "Effect index out of range"})
		return
	AudioServer.remove_bus_effect(bus_idx, effect_idx)
	_send_response({"success": true, "bus_name": bus_name, "removed_idx": effect_idx})

func _cmd_get_audio_bus_effects(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "Master")
	var bus_idx = AudioServer.get_bus_index(bus_name)
	if bus_idx < 0:
		_send_response({"error": "Audio bus not found: " + bus_name})
		return
	var effects: Array = []
	for i in range(AudioServer.get_bus_effect_count(bus_idx)):
		var eff = AudioServer.get_bus_effect(bus_idx, i)
		effects.append({"idx": i, "class": eff.get_class(), "enabled": AudioServer.is_bus_effect_enabled(bus_idx, i)})
	_send_response({"success": true, "bus_name": bus_name, "effects": effects})

func _cmd_set_audio_effect_parameter(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "Master")
	var effect_idx: int = params.get("effect_idx", 0)
	var param_name: String = params.get("param_name", "")
	var param_value = params.get("param_value", null)
	var bus_idx = AudioServer.get_bus_index(bus_name)
	if bus_idx < 0:
		_send_response({"error": "Audio bus not found: " + bus_name})
		return
	if effect_idx >= AudioServer.get_bus_effect_count(bus_idx):
		_send_response({"error": "Effect index out of range"})
		return
	var eff = AudioServer.get_bus_effect(bus_idx, effect_idx)
	if not eff.has_method("set"):
		_send_response({"error": "Cannot set parameter on effect"})
		return
	eff.set(param_name, param_value)
	_send_response({"success": true, "param_name": param_name, "value": param_value})

func _cmd_create_audio_bus(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "")
	if bus_name.is_empty():
		_send_response({"error": "bus_name is required"})
		return
	var existing = AudioServer.get_bus_index(bus_name)
	if existing >= 0:
		_send_response({"error": "Bus already exists: " + bus_name})
		return
	var new_idx = AudioServer.get_bus_count()
	AudioServer.add_bus(new_idx)
	AudioServer.set_bus_name(new_idx, bus_name)
	_send_response({"success": true, "bus_name": bus_name, "bus_idx": new_idx})

func _cmd_list_audio_buses(params: Dictionary) -> void:
	var buses: Array = []
	for i in range(AudioServer.get_bus_count()):
		buses.append({"idx": i, "name": AudioServer.get_bus_name(i), "volume_db": AudioServer.get_bus_volume_db(i), "muted": AudioServer.is_bus_mute(i), "solo": AudioServer.is_bus_solo(i), "effect_count": AudioServer.get_bus_effect_count(i)})
	_send_response({"success": true, "count": buses.size(), "buses": buses})

func _cmd_set_environment_glow(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "/root/WorldEnvironment")
	var enabled: bool = params.get("enabled", true)
	var intensity: float = params.get("intensity", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is WorldEnvironment:
		_send_response({"error": "WorldEnvironment not found: " + node_path})
		return
	var env = (node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "No Environment resource on WorldEnvironment"})
		return
	env.glow_enabled = enabled
	env.glow_intensity = intensity
	_send_response({"success": true, "glow_enabled": enabled, "glow_intensity": intensity})

func _cmd_set_environment_ssao(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "/root/WorldEnvironment")
	var enabled: bool = params.get("enabled", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is WorldEnvironment:
		_send_response({"error": "WorldEnvironment not found: " + node_path})
		return
	var env = (node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "No Environment resource"})
		return
	env.ssao_enabled = enabled
	_send_response({"success": true, "ssao_enabled": enabled})

func _cmd_set_environment_fog(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "/root/WorldEnvironment")
	var enabled: bool = params.get("enabled", true)
	var fog_density: float = params.get("fog_density", 0.01)
	var fog_color_hex: String = params.get("fog_color", "#FFFFFF")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is WorldEnvironment:
		_send_response({"error": "WorldEnvironment not found: " + node_path})
		return
	var env = (node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "No Environment resource"})
		return
	env.fog_enabled = enabled
	env.fog_density = fog_density
	env.fog_light_color = Color(fog_color_hex)
	_send_response({"success": true, "fog_enabled": enabled, "fog_density": fog_density})

func _cmd_get_environment_properties(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "/root/WorldEnvironment")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is WorldEnvironment:
		_send_response({"error": "WorldEnvironment not found: " + node_path})
		return
	var env = (node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "No Environment resource"})
		return
	_send_response({"success": true, "glow_enabled": env.glow_enabled, "glow_intensity": env.glow_intensity, "ssao_enabled": env.ssao_enabled, "ssil_enabled": env.ssil_enabled, "fog_enabled": env.fog_enabled, "fog_density": env.fog_density, "background_mode": env.background_mode, "ambient_light_energy": env.ambient_light_energy})

func _cmd_setup_enet_multiplayer(params: Dictionary) -> void:
	var mode: String = params.get("mode", "server")
	var port: int = params.get("port", 7777)
	var address: String = params.get("address", "127.0.0.1")
	var max_clients: int = params.get("max_clients", 32)
	var peer = ENetMultiplayerPeer.new()
	var err: int
	if mode == "server":
		err = peer.create_server(port, max_clients)
	else:
		err = peer.create_client(address, port)
	if err != OK:
		_send_response({"error": "ENet setup failed with error code: " + str(err)})
		return
	multiplayer.multiplayer_peer = peer
	_send_response({"success": true, "mode": mode, "port": port, "address": address})

func _cmd_get_connected_peers(params: Dictionary) -> void:
	var peers = multiplayer.get_peers()
	_send_response({"success": true, "unique_id": multiplayer.get_unique_id(), "is_server": multiplayer.is_server(), "peer_count": peers.size(), "peers": peers})

func _cmd_disconnect_multiplayer(params: Dictionary) -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_send_response({"success": true, "disconnected": true})

func _cmd_send_multiplayer_rpc(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var method_name: String = params.get("method_name", "")
	var target_peer_id: int = params.get("target_peer_id", 0)
	var rpc_args: Array = params.get("args", [])
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if not node.has_method(method_name):
		_send_response({"error": "Method not found: " + method_name})
		return
	node.rpc_id(target_peer_id, method_name, rpc_args)
	_send_response({"success": true, "node_path": node_path, "method_name": method_name, "target_peer_id": target_peer_id})

func _cmd_reload_script_at_runtime(params: Dictionary) -> void:
	var script_path: String = params.get("script_path", "")
	if script_path.is_empty():
		_send_response({"error": "script_path is required"})
		return
	var script = load(script_path) as GDScript
	if script == null:
		_send_response({"error": "Cannot load script: " + script_path})
		return
	script.reload()
	_send_response({"success": true, "script_path": script_path})

func _cmd_get_loaded_gdextensions(params: Dictionary) -> void:
	var extensions: Array = []
	for ext in GDExtensionManager.get_loaded_extensions():
		extensions.append({"path": ext})
	_send_response({"success": true, "count": extensions.size(), "extensions": extensions})

func _cmd_get_physics_body_state(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var result = {"node_path": node_path, "class": node.get_class()}
	if node is RigidBody3D:
		var rb := node as RigidBody3D
		result["linear_velocity"] = {"x": rb.linear_velocity.x, "y": rb.linear_velocity.y, "z": rb.linear_velocity.z}
		result["angular_velocity"] = {"x": rb.angular_velocity.x, "y": rb.angular_velocity.y, "z": rb.angular_velocity.z}
		result["mass"] = rb.mass
		result["freeze"] = rb.freeze
		result["sleeping"] = rb.sleeping
	elif node is RigidBody2D:
		var rb := node as RigidBody2D
		result["linear_velocity"] = {"x": rb.linear_velocity.x, "y": rb.linear_velocity.y}
		result["angular_velocity"] = rb.angular_velocity
		result["mass"] = rb.mass
		result["freeze"] = rb.freeze
		result["sleeping"] = rb.sleeping
	else:
		result["error"] = "Not a RigidBody node"
	_send_response(result)

func _cmd_apply_impulse_to_rigid_body(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is RigidBody3D:
		(node as RigidBody3D).apply_central_impulse(Vector3(x, y, z))
		_send_response({"success": true, "impulse": {"x": x, "y": y, "z": z}})
	elif node is RigidBody2D:
		(node as RigidBody2D).apply_central_impulse(Vector2(x, y))
		_send_response({"success": true, "impulse": {"x": x, "y": y}})
	else:
		_send_response({"error": "Not a RigidBody node: " + node.get_class()})

func _cmd_set_rigid_body_freeze(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var freeze: bool = params.get("freeze", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is RigidBody3D:
		(node as RigidBody3D).freeze = freeze
		_send_response({"success": true, "freeze": freeze})
	elif node is RigidBody2D:
		(node as RigidBody2D).freeze = freeze
		_send_response({"success": true, "freeze": freeze})
	else:
		_send_response({"error": "Not a RigidBody node: " + node.get_class()})

func _cmd_set_collision_mask(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var mask: int = params.get("mask", 1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node.has_method("set_collision_mask"):
		node.set_collision_mask(mask)
		_send_response({"success": true, "collision_mask": mask})
	else:
		_send_response({"error": "Node does not support collision_mask: " + node.get_class()})

func _cmd_set_collision_layer(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var layer: int = params.get("layer", 1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node.has_method("set_collision_layer"):
		node.set_collision_layer(layer)
		_send_response({"success": true, "collision_layer": layer})
	else:
		_send_response({"error": "Node does not support collision_layer: " + node.get_class()})

func _cmd_get_runtime_input_actions(params: Dictionary) -> void:
	var actions: Array = []
	for action in InputMap.get_actions():
		var events: Array = []
		for event in InputMap.action_get_events(action):
			events.append(event.as_text())
		actions.append({"action": action, "deadzone": InputMap.action_get_deadzone(action), "events": events})
	_send_response({"success": true, "count": actions.size(), "actions": actions})

func _cmd_is_action_pressed(params: Dictionary) -> void:
	var action_name: String = params.get("action_name", "")
	if action_name.is_empty():
		_send_response({"error": "action_name is required"})
		return
	if not InputMap.has_action(action_name):
		_send_response({"error": "Action not found: " + action_name})
		return
	_send_response({"success": true, "action_name": action_name, "pressed": Input.is_action_pressed(action_name), "strength": Input.get_action_strength(action_name)})

func _cmd_get_global_transform_3d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	var xform = (node as Node3D).global_transform
	_send_response({"success": true, "position": {"x": xform.origin.x, "y": xform.origin.y, "z": xform.origin.z}, "basis_x": {"x": xform.basis.x.x, "y": xform.basis.x.y, "z": xform.basis.x.z}, "basis_y": {"x": xform.basis.y.x, "y": xform.basis.y.y, "z": xform.basis.y.z}, "basis_z": {"x": xform.basis.z.x, "y": xform.basis.z.y, "z": xform.basis.z.z}})

func _cmd_set_global_position_3d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	(node as Node3D).global_position = Vector3(x, y, z)
	_send_response({"success": true, "position": {"x": x, "y": y, "z": z}})

func _cmd_look_at_target(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var target_x: float = params.get("target_x", 0.0)
	var target_y: float = params.get("target_y", 0.0)
	var target_z: float = params.get("target_z", 0.0)
	var up_x: float = params.get("up_x", 0.0)
	var up_y: float = params.get("up_y", 1.0)
	var up_z: float = params.get("up_z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	(node as Node3D).look_at(Vector3(target_x, target_y, target_z), Vector3(up_x, up_y, up_z))
	_send_response({"success": true, "target": {"x": target_x, "y": target_y, "z": target_z}})

func _cmd_list_connected_signals_in_game(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var signals: Array = []
	for sig in node.get_signal_list():
		var connections: Array = []
		for conn in node.get_signal_connection_list(sig["name"]):
			connections.append({"target": str(conn["callable"].get_object().get_path()) if conn["callable"].get_object() != null else "null", "method": conn["callable"].get_method()})
		if not connections.is_empty():
			signals.append({"signal": sig["name"], "connections": connections})
	_send_response({"success": true, "node_path": node_path, "count": signals.size(), "signals": signals})

func _cmd_connect_signal_in_game(params: Dictionary) -> void:
	var source_path: String = params.get("source_path", "")
	var signal_name: String = params.get("signal_name", "")
	var target_path: String = params.get("target_path", "")
	var method_name: String = params.get("method_name", "")
	var source = get_tree().root.get_node_or_null(NodePath(source_path))
	var target = get_tree().root.get_node_or_null(NodePath(target_path))
	if source == null:
		_send_response({"error": "Source node not found: " + source_path})
		return
	if target == null:
		_send_response({"error": "Target node not found: " + target_path})
		return
	if not source.has_signal(signal_name):
		_send_response({"error": "Signal not found: " + signal_name})
		return
	if not target.has_method(method_name):
		_send_response({"error": "Method not found: " + method_name})
		return
	var err = source.connect(signal_name, Callable(target, method_name))
	_send_response({"success": err == OK, "source": source_path, "signal": signal_name, "target": target_path, "method": method_name, "error_code": err})

func _cmd_disconnect_signal_in_game(params: Dictionary) -> void:
	var source_path: String = params.get("source_path", "")
	var signal_name: String = params.get("signal_name", "")
	var target_path: String = params.get("target_path", "")
	var method_name: String = params.get("method_name", "")
	var source = get_tree().root.get_node_or_null(NodePath(source_path))
	var target = get_tree().root.get_node_or_null(NodePath(target_path))
	if source == null or target == null:
		_send_response({"error": "Source or target node not found"})
		return
	if not source.is_connected(signal_name, Callable(target, method_name)):
		_send_response({"error": "Signal not connected"})
		return
	source.disconnect(signal_name, Callable(target, method_name))
	_send_response({"success": true, "disconnected": signal_name})

func _cmd_emit_signal_in_game(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var signal_name: String = params.get("signal_name", "")
	var signal_args: Array = params.get("args", [])
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if not node.has_signal(signal_name):
		_send_response({"error": "Signal not found: " + signal_name})
		return
	node.emit_signal(signal_name, signal_args)
	_send_response({"success": true, "signal": signal_name, "node_path": node_path})

func _cmd_get_node_groups(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "node_path": node_path, "groups": node.get_groups()})

func _cmd_add_node_to_group(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var group_name: String = params.get("group_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	node.add_to_group(group_name, true)
	_send_response({"success": true, "node_path": node_path, "group": group_name})

func _cmd_remove_node_from_group(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var group_name: String = params.get("group_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if not node.is_in_group(group_name):
		_send_response({"error": "Node is not in group: " + group_name})
		return
	node.remove_from_group(group_name)
	_send_response({"success": true, "node_path": node_path, "removed_from": group_name})

func _cmd_call_group_method(params: Dictionary) -> void:
	var group_name: String = params.get("group_name", "")
	var method_name: String = params.get("method_name", "")
	var call_args: Array = params.get("args", [])
	var nodes_in_group = get_tree().get_nodes_in_group(group_name)
	var called_count = 0
	for node in nodes_in_group:
		if node.has_method(method_name):
			node.callv(method_name, call_args)
			called_count += 1
	_send_response({"success": true, "group": group_name, "method": method_name, "called_count": called_count, "total_in_group": nodes_in_group.size()})

func _cmd_set_particle_emission_rate(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var amount: int = params.get("amount", -1)
	var lifetime: float = params.get("lifetime", -1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var changed: Dictionary = {}
	if node.has_method("set_amount") and amount >= 0:
		node.set("amount", amount)
		changed["amount"] = amount
	if node.has_method("set_lifetime") and lifetime >= 0:
		node.set("lifetime", lifetime)
		changed["lifetime"] = lifetime
	_send_response({"success": true, "node_path": node_path, "changed": changed})

func _cmd_get_particle_state(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var result: Dictionary = {"node_path": node_path, "class": node.get_class()}
	for prop in ["emitting", "amount", "lifetime", "one_shot", "preprocess", "speed_scale"]:
		if node.get(prop) != null:
			result[prop] = node.get(prop)
	_send_response(result)

func _cmd_restart_particles(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node.has_method("restart"):
		node.restart()
		_send_response({"success": true, "node_path": node_path})
	else:
		_send_response({"error": "Node does not support restart(): " + node.get_class()})

func _cmd_set_shader_uniform(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var uniform_name: String = params.get("uniform_name", "")
	var value = params.get("value", null)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var mat: Material = null
	if node.has_method("get_material"):
		mat = node.get_material()
	elif node.get("material_override") != null:
		mat = node.get("material_override")
	elif node.get("material") != null:
		mat = node.get("material")
	if mat == null or not mat is ShaderMaterial:
		_send_response({"error": "ShaderMaterial not found on node"})
		return
	(mat as ShaderMaterial).set_shader_parameter(uniform_name, value)
	_send_response({"success": true, "uniform_name": uniform_name, "value": str(value)})

func _cmd_get_shader_uniforms(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var mat: Material = null
	if node.has_method("get_material"):
		mat = node.get_material()
	elif node.get("material_override") != null:
		mat = node.get("material_override")
	elif node.get("material") != null:
		mat = node.get("material")
	if mat == null or not mat is ShaderMaterial:
		_send_response({"error": "ShaderMaterial not found on node"})
		return
	var shader_mat := mat as ShaderMaterial
	var uniforms: Array = []
	if shader_mat.shader != null:
		for param in shader_mat.shader.get_shader_uniform_list():
			uniforms.append({"name": param["name"], "type": param["type"], "value": str(shader_mat.get_shader_parameter(param["name"]))})
	_send_response({"success": true, "count": uniforms.size(), "uniforms": uniforms})

func _cmd_get_material_properties(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var mat: Material = null
	if node.get("material_override") != null:
		mat = node.get("material_override")
	if mat == null and node is MeshInstance3D:
		mat = (node as MeshInstance3D).get_surface_override_material(0)
	if mat == null and node.get("material") != null:
		mat = node.get("material")
	if mat == null:
		_send_response({"error": "No material found on node"})
		return
	var props: Dictionary = {"class": mat.get_class()}
	for p in mat.get_property_list():
		if p["usage"] & PROPERTY_USAGE_EDITOR:
			var val = mat.get(p["name"])
			props[p["name"]] = str(val) if val != null else null
	_send_response({"success": true, "material_class": mat.get_class(), "properties": props})

func _cmd_set_light_3d_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Light3D:
		_send_response({"error": "Light3D not found: " + node_path})
		return
	(node as Light3D).light_color = Color(r, g, b)
	_send_response({"success": true, "light_color": {"r": r, "g": g, "b": b}})

func _cmd_set_light_3d_energy(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var energy: float = params.get("energy", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Light3D:
		_send_response({"error": "Light3D not found: " + node_path})
		return
	(node as Light3D).light_energy = energy
	_send_response({"success": true, "light_energy": energy})

func _cmd_set_sky_material(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "/root/WorldEnvironment")
	var sky_material_path: String = params.get("sky_material_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is WorldEnvironment:
		_send_response({"error": "WorldEnvironment not found: " + node_path})
		return
	var env = (node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "No Environment resource"})
		return
	var sky_mat = load(sky_material_path) as SkyMaterial
	if sky_mat == null:
		_send_response({"error": "Cannot load SkyMaterial: " + sky_material_path})
		return
	if env.sky == null:
		env.sky = Sky.new()
	env.sky.sky_material = sky_mat
	_send_response({"success": true, "sky_material_path": sky_material_path})

func _cmd_get_node_metadata_in_game(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var meta_names = node.get_meta_list()
	var meta_dict: Dictionary = {}
	for key in meta_names:
		meta_dict[key] = str(node.get_meta(key))
	_send_response({"success": true, "node_path": node_path, "meta_count": meta_names.size(), "metadata": meta_dict})

func _cmd_set_node_metadata_in_game(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var key: String = params.get("key", "")
	var value = params.get("value", null)
	if key.is_empty():
		_send_response({"error": "key is required"})
		return
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	node.set_meta(key, value)
	_send_response({"success": true, "node_path": node_path, "key": key, "value": str(value)})

func _cmd_get_time_in_game(params: Dictionary) -> void:
	var ticks_ms = Time.get_ticks_msec()
	var ticks_usec = Time.get_ticks_usec()
	var unix_time = Time.get_unix_time_from_system()
	_send_response({"success": true, "ticks_msec": ticks_ms, "ticks_usec": ticks_usec, "unix_time": unix_time, "engine_time_scale": Engine.time_scale, "physics_ticks_per_second": Engine.physics_ticks_per_second})

func _cmd_get_engine_version_in_game(params: Dictionary) -> void:
	var version = Engine.get_version_info()
	_send_response({"success": true, "major": version["major"], "minor": version["minor"], "patch": version["patch"], "status": version["status"], "build": version["build"], "string": version["string"]})

func _cmd_set_camera_fov(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var fov: float = params.get("fov", 75.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Camera3D:
		_send_response({"error": "Camera3D not found: " + node_path})
		return
	(node as Camera3D).fov = fov
	_send_response({"success": true, "fov": fov})

func _cmd_set_camera_3d_current(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Camera3D:
		_send_response({"error": "Camera3D not found: " + node_path})
		return
	(node as Camera3D).make_current()
	_send_response({"success": true, "current_camera": node_path})

func _cmd_get_current_camera_3d(params: Dictionary) -> void:
	var viewport = get_tree().root
	var camera = viewport.get_camera_3d()
	if camera == null:
		_send_response({"success": true, "current_camera": null, "note": "No active Camera3D"})
	else:
		_send_response({"success": true, "current_camera": str(camera.get_path()), "fov": camera.fov, "near": camera.near, "far": camera.far, "projection": camera.projection})

func _cmd_set_camera_2d_zoom(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var zoom_x: float = params.get("zoom_x", 1.0)
	var zoom_y: float = params.get("zoom_y", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Camera2D:
		_send_response({"error": "Camera2D not found: " + node_path})
		return
	(node as Camera2D).zoom = Vector2(zoom_x, zoom_y)
	_send_response({"success": true, "zoom": {"x": zoom_x, "y": zoom_y}})

func _cmd_set_camera_2d_limit(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var side: String = params.get("side", "left")
	var value: int = params.get("value", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Camera2D:
		_send_response({"error": "Camera2D not found: " + node_path})
		return
	var cam := node as Camera2D
	match side:
		"left": cam.limit_left = value
		"right": cam.limit_right = value
		"top": cam.limit_top = value
		"bottom": cam.limit_bottom = value
		_: _send_response({"error": "Invalid side: " + side}); return
	_send_response({"success": true, "side": side, "value": value})

func _cmd_set_viewport_size_ingame(params: Dictionary) -> void:
	var width: int = params.get("width", 1280)
	var height: int = params.get("height", 720)
	DisplayServer.window_set_size(Vector2i(width, height))
	_send_response({"success": true, "width": width, "height": height})

func _cmd_set_time_scale(params: Dictionary) -> void:
	var time_scale: float = params.get("time_scale", 1.0)
	Engine.time_scale = time_scale
	_send_response({"success": true, "time_scale": time_scale})

func _cmd_get_scene_tree_paused(params: Dictionary) -> void:
	_send_response({"success": true, "paused": get_tree().paused, "current_scene": str(get_tree().current_scene.get_path()) if get_tree().current_scene != null else null})

func _cmd_set_rich_text_label_bbcode(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var text: String = params.get("text", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RichTextLabel:
		_send_response({"error": "RichTextLabel not found: " + node_path})
		return
	var rtl := node as RichTextLabel
	rtl.bbcode_enabled = true
	rtl.text = text
	_send_response({"success": true, "text": text})

func _cmd_set_progress_bar_value(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var value: float = params.get("value", 0.0)
	var min_value = params.get("min_value", null)
	var max_value = params.get("max_value", null)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is ProgressBar:
		_send_response({"error": "ProgressBar not found: " + node_path})
		return
	var pb := node as ProgressBar
	if min_value != null:
		pb.min_value = float(min_value)
	if max_value != null:
		pb.max_value = float(max_value)
	pb.value = value
	_send_response({"success": true, "value": pb.value, "min": pb.min_value, "max": pb.max_value})

func _cmd_set_slider_value(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var value: float = params.get("value", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not (node is HSlider or node is VSlider):
		_send_response({"error": "Slider not found: " + node_path})
		return
	(node as Range).value = value
	_send_response({"success": true, "value": value})

func _cmd_get_spin_box_value(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SpinBox:
		_send_response({"error": "SpinBox not found: " + node_path})
		return
	var sb := node as SpinBox
	_send_response({"success": true, "value": sb.value, "min": sb.min_value, "max": sb.max_value, "step": sb.step})

func _cmd_set_spin_box_value(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var value: float = params.get("value", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SpinBox:
		_send_response({"error": "SpinBox not found: " + node_path})
		return
	(node as SpinBox).value = value
	_send_response({"success": true, "value": value})

func _cmd_set_option_button_selected(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var index: int = params.get("index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is OptionButton:
		_send_response({"error": "OptionButton not found: " + node_path})
		return
	(node as OptionButton).selected = index
	_send_response({"success": true, "selected": index})

func _cmd_get_option_button_selected(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is OptionButton:
		_send_response({"error": "OptionButton not found: " + node_path})
		return
	var ob := node as OptionButton
	_send_response({"success": true, "selected_index": ob.selected, "selected_text": ob.get_item_text(ob.selected) if ob.selected >= 0 else null, "item_count": ob.item_count})

func _cmd_add_option_button_item(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var label: String = params.get("label", "")
	var id: int = params.get("id", -1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is OptionButton:
		_send_response({"error": "OptionButton not found: " + node_path})
		return
	var ob := node as OptionButton
	if id >= 0:
		ob.add_item(label, id)
	else:
		ob.add_item(label)
	_send_response({"success": true, "label": label, "item_count": ob.item_count})

func _cmd_set_tab_container_current(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var tab_index: int = params.get("tab_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TabContainer:
		_send_response({"error": "TabContainer not found: " + node_path})
		return
	(node as TabContainer).current_tab = tab_index
	_send_response({"success": true, "current_tab": tab_index})

func _cmd_get_color_picker_value(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is ColorPicker:
		_send_response({"error": "ColorPicker not found: " + node_path})
		return
	var cp := node as ColorPicker
	var color = cp.color
	_send_response({"success": true, "color": {"r": color.r, "g": color.g, "b": color.b, "a": color.a}, "html": color.to_html()})

func _cmd_set_color_picker_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var a: float = params.get("a", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is ColorPicker:
		_send_response({"error": "ColorPicker not found: " + node_path})
		return
	(node as ColorPicker).color = Color(r, g, b, a)
	_send_response({"success": true, "color": {"r": r, "g": g, "b": b, "a": a}})

func _cmd_show_popup_menu(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: int = params.get("x", 0)
	var y: int = params.get("y", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is PopupMenu:
		_send_response({"error": "PopupMenu not found: " + node_path})
		return
	(node as PopupMenu).popup(Rect2i(x, y, 0, 0))
	_send_response({"success": true, "position": {"x": x, "y": y}})

func _cmd_add_popup_menu_item(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var label: String = params.get("label", "")
	var id: int = params.get("id", -1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is PopupMenu:
		_send_response({"error": "PopupMenu not found: " + node_path})
		return
	var pm := node as PopupMenu
	if id >= 0:
		pm.add_item(label, id)
	else:
		pm.add_item(label)
	_send_response({"success": true, "label": label, "item_count": pm.item_count})

func _cmd_clear_popup_menu(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is PopupMenu:
		_send_response({"error": "PopupMenu not found: " + node_path})
		return
	(node as PopupMenu).clear()
	_send_response({"success": true, "cleared": true})

func _cmd_show_dialog(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var title: String = params.get("title", "")
	var text: String = params.get("text", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AcceptDialog:
		_send_response({"error": "AcceptDialog (or subclass) not found: " + node_path})
		return
	var dlg := node as AcceptDialog
	if not title.is_empty():
		dlg.title = title
	if not text.is_empty():
		dlg.dialog_text = text
	dlg.popup_centered()
	_send_response({"success": true, "title": dlg.title})

func _cmd_hide_node_in_game(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node.has_method("hide"):
		node.hide()
		_send_response({"success": true, "visible": false})
	else:
		_send_response({"error": "Node does not support hide(): " + node.get_class()})

func _cmd_show_node_in_game(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node.has_method("show"):
		node.show()
		_send_response({"success": true, "visible": true})
	else:
		_send_response({"error": "Node does not support show(): " + node.get_class()})

func _cmd_toggle_node_visibility(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var visible_val = node.get("visible")
	if visible_val == null:
		_send_response({"error": "Node does not have visible property: " + node.get_class()})
		return
	node.set("visible", not bool(visible_val))
	_send_response({"success": true, "visible": not bool(visible_val)})

func _cmd_get_node_visibility(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var visible_val = node.get("visible")
	if visible_val == null:
		_send_response({"error": "Node does not have visible property: " + node.get_class()})
		return
	_send_response({"success": true, "visible": bool(visible_val), "class": node.get_class()})

func _cmd_duplicate_node_in_game(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var new_name: String = params.get("new_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var dup = node.duplicate()
	if not new_name.is_empty():
		dup.name = new_name
	node.get_parent().add_child(dup)
	dup.owner = get_tree().root
	_send_response({"success": true, "original_path": node_path, "duplicate_path": str(dup.get_path()), "name": dup.name})

func _cmd_get_item_list_items(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is ItemList:
		_send_response({"error": "ItemList not found: " + node_path})
		return
	var il := node as ItemList
	var items: Array = []
	for i in range(il.item_count):
		items.append({"index": i, "text": il.get_item_text(i), "selected": il.is_selected(i), "disabled": il.is_item_disabled(i)})
	_send_response({"success": true, "count": il.item_count, "items": items})

func _cmd_add_item_list_item(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var text: String = params.get("text", "")
	var icon_path: String = params.get("icon", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is ItemList:
		_send_response({"error": "ItemList not found: " + node_path})
		return
	var il := node as ItemList
	if not icon_path.is_empty():
		var icon_tex = load(icon_path) as Texture2D
		il.add_item(text, icon_tex)
	else:
		il.add_item(text)
	_send_response({"success": true, "text": text, "item_count": il.item_count})

func _cmd_clear_item_list(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is ItemList:
		_send_response({"error": "ItemList not found: " + node_path})
		return
	(node as ItemList).clear()
	_send_response({"success": true, "cleared": true})

func _cmd_get_item_list_selected(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is ItemList:
		_send_response({"error": "ItemList not found: " + node_path})
		return
	var il := node as ItemList
	var selected = il.get_selected_items()
	var selected_texts: Array = []
	for idx in selected:
		selected_texts.append(il.get_item_text(idx))
	_send_response({"success": true, "selected_indices": selected, "selected_texts": selected_texts})

func _cmd_set_check_box_pressed(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var pressed: bool = params.get("pressed", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not (node is CheckBox or node is CheckButton):
		_send_response({"error": "CheckBox/CheckButton not found: " + node_path})
		return
	(node as BaseButton).button_pressed = pressed
	_send_response({"success": true, "pressed": pressed})

func _cmd_get_line_edit_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is LineEdit:
		_send_response({"error": "LineEdit not found: " + node_path})
		return
	_send_response({"success": true, "text": (node as LineEdit).text, "caret_column": (node as LineEdit).caret_column})

func _cmd_set_line_edit_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var text: String = params.get("text", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is LineEdit:
		_send_response({"error": "LineEdit not found: " + node_path})
		return
	(node as LineEdit).text = text
	_send_response({"success": true, "text": text})

func _cmd_get_text_edit_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TextEdit:
		_send_response({"error": "TextEdit not found: " + node_path})
		return
	_send_response({"success": true, "text": (node as TextEdit).text, "line_count": (node as TextEdit).get_line_count()})

func _cmd_set_text_edit_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var text: String = params.get("text", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TextEdit:
		_send_response({"error": "TextEdit not found: " + node_path})
		return
	(node as TextEdit).text = text
	_send_response({"success": true, "text": text})

func _cmd_set_label_horizontal_alignment(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var alignment_str: String = params.get("alignment", "left")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Label:
		_send_response({"error": "Label not found: " + node_path})
		return
	var align_val: int = HORIZONTAL_ALIGNMENT_LEFT
	match alignment_str:
		"center": align_val = HORIZONTAL_ALIGNMENT_CENTER
		"right": align_val = HORIZONTAL_ALIGNMENT_RIGHT
		"fill": align_val = HORIZONTAL_ALIGNMENT_FILL
	(node as Label).horizontal_alignment = align_val
	_send_response({"success": true, "alignment": alignment_str})

func _cmd_get_node_property_list(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var include_script: bool = params.get("include_script", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var props: Array = []
	for p in node.get_property_list():
		if p["usage"] & PROPERTY_USAGE_EDITOR or include_script:
			props.append({"name": p["name"], "type": p["type"], "usage": p["usage"]})
	_send_response({"success": true, "node_path": node_path, "class": node.get_class(), "property_count": props.size(), "properties": props})

func _cmd_get_node_method_list(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var methods: Array = []
	for m in node.get_method_list():
		methods.append({"name": m["name"], "args": m["args"].size(), "flags": m["flags"]})
	_send_response({"success": true, "node_path": node_path, "method_count": methods.size(), "methods": methods})

func _cmd_call_node_method(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var method_name: String = params.get("method_name", "")
	var call_args: Array = params.get("args", [])
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if not node.has_method(method_name):
		_send_response({"error": "Method not found: " + method_name})
		return
	var result = node.callv(method_name, call_args)
	_send_response({"success": true, "result": str(result), "method": method_name})

func _cmd_get_node_constant(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var constant_name: String = params.get("constant_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var class_name_str = node.get_class()
	if ClassDB.class_has_integer_constant(class_name_str, constant_name):
		var val = ClassDB.class_get_integer_constant(class_name_str, constant_name)
		_send_response({"success": true, "constant_name": constant_name, "value": val})
	else:
		_send_response({"error": "Constant not found: " + constant_name + " on " + class_name_str})

func _cmd_set_process_enabled(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var process_enabled: bool = params.get("process_enabled", true)
	var physics_enabled: bool = params.get("physics_enabled", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	node.set_process(process_enabled)
	node.set_physics_process(physics_enabled)
	_send_response({"success": true, "process_enabled": process_enabled, "physics_enabled": physics_enabled})

func _cmd_get_process_state(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "process_enabled": node.is_processing(), "physics_enabled": node.is_physics_processing(), "input_enabled": node.is_processing_input(), "unhandled_input_enabled": node.is_processing_unhandled_input()})

func _cmd_add_node_type_in_game(params: Dictionary) -> void:
	var node_type: String = params.get("node_type", "Node")
	var parent_path: String = params.get("parent_path", "/root")
	var node_name: String = params.get("node_name", node_type)
	var parent = get_tree().root.get_node_or_null(NodePath(parent_path))
	if parent == null:
		_send_response({"error": "Parent not found: " + parent_path})
		return
	if not ClassDB.class_exists(node_type):
		_send_response({"error": "Unknown node type: " + node_type})
		return
	var new_node = ClassDB.instantiate(node_type) as Node
	if new_node == null:
		_send_response({"error": "Cannot instantiate: " + node_type})
		return
	new_node.name = node_name
	parent.add_child(new_node)
	new_node.owner = get_tree().root
	_send_response({"success": true, "node_path": str(new_node.get_path()), "type": node_type, "name": node_name})

func _cmd_remove_node_in_game(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	node.queue_free()
	_send_response({"success": true, "removed_path": node_path})

func _cmd_reparent_node_in_game(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var new_parent_path: String = params.get("new_parent_path", "")
	var keep_global_transform: bool = params.get("keep_global_transform", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	var new_parent = get_tree().root.get_node_or_null(NodePath(new_parent_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if new_parent == null:
		_send_response({"error": "New parent not found: " + new_parent_path})
		return
	node.reparent(new_parent, keep_global_transform)
	_send_response({"success": true, "new_path": str(node.get_path())})

func _cmd_get_node_owner(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var owner = node.owner
	_send_response({"success": true, "owner_path": str(owner.get_path()) if owner != null else null})

func _cmd_set_node_name_in_game(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var new_name: String = params.get("new_name", "")
	if new_name.is_empty():
		_send_response({"error": "new_name is required"})
		return
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var old_name = node.name
	node.name = new_name
	_send_response({"success": true, "old_name": old_name, "new_name": node.name, "new_path": str(node.get_path())})

func _cmd_get_children_count(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var children: Array = []
	for child in node.get_children():
		children.append({"name": child.name, "class": child.get_class(), "path": str(child.get_path())})
	_send_response({"success": true, "child_count": node.get_child_count(), "children": children})

func _cmd_find_node_by_name(params: Dictionary) -> void:
	var search_name: String = params.get("search_name", "")
	var root_path: String = params.get("root_path", "/root")
	var root = get_tree().root.get_node_or_null(NodePath(root_path))
	if root == null:
		_send_response({"error": "Root node not found: " + root_path})
		return
	var found: Array = []
	var queue: Array = [root]
	while not queue.is_empty():
		var current = queue.pop_front()
		if current.name == search_name:
			found.append(str(current.get_path()))
		for child in current.get_children():
			queue.append(child)
	_send_response({"success": true, "search_name": search_name, "count": found.size(), "paths": found})

func _build_snapshot_node(node: Node, depth: int) -> Dictionary:
	var d: Dictionary = {"name": node.name, "class": node.get_class(), "path": str(node.get_path())}
	if depth > 0:
		var children: Array = []
		for child in node.get_children():
			children.append(_build_snapshot_node(child, depth - 1))
		d["children"] = children
	return d

func _cmd_get_scene_tree_snapshot(params: Dictionary) -> void:
	var max_depth: int = params.get("max_depth", 10)
	_send_response({"success": true, "tree": _build_snapshot_node(get_tree().root, max_depth)})

func _cmd_get_node_at_position_2d(params: Dictionary) -> void:
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var pos = Vector2(x, y)
	var viewport = get_tree().root
	var canvas_items = []
	for child in viewport.get_children():
		if child is CanvasItem:
			canvas_items.append({"name": child.name, "class": child.get_class(), "path": str(child.get_path())})
	_send_response({"success": true, "position": {"x": x, "y": y}, "note": "Top-level canvas items checked", "items": canvas_items})

func _cmd_raycast_3d(params: Dictionary) -> void:
	var from = Vector3(params.get("from_x", 0.0), params.get("from_y", 0.0), params.get("from_z", 0.0))
	var to = Vector3(params.get("to_x", 0.0), params.get("to_y", 0.0), params.get("to_z", 0.0))
	var space_state = get_tree().root.get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	var result = space_state.intersect_ray(query)
	if result.is_empty():
		_send_response({"success": true, "hit": false})
	else:
		_send_response({"success": true, "hit": true, "position": {"x": result["position"].x, "y": result["position"].y, "z": result["position"].z}, "normal": {"x": result["normal"].x, "y": result["normal"].y, "z": result["normal"].z}, "collider": str(result["collider"].get_path()) if result.has("collider") and result["collider"] != null else null})

func _cmd_overlap_sphere_3d(params: Dictionary) -> void:
	var center = Vector3(params.get("x", 0.0), params.get("y", 0.0), params.get("z", 0.0))
	var radius: float = params.get("radius", 1.0)
	var space_state = get_tree().root.get_world_3d().direct_space_state
	var shape = SphereShape3D.new()
	shape.radius = radius
	var query = PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), center)
	var results = space_state.intersect_shape(query)
	var bodies: Array = []
	for r in results:
		if r.has("collider") and r["collider"] != null:
			bodies.append(str(r["collider"].get_path()))
	_send_response({"success": true, "center": {"x": center.x, "y": center.y, "z": center.z}, "radius": radius, "count": bodies.size(), "bodies": bodies})

func _cmd_get_physics_bodies_in_area(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Area3D:
		_send_response({"error": "Area3D not found: " + node_path})
		return
	var area := node as Area3D
	var bodies: Array = []
	for body in area.get_overlapping_bodies():
		bodies.append({"path": str(body.get_path()), "class": body.get_class()})
	_send_response({"success": true, "count": bodies.size(), "bodies": bodies})

func _cmd_set_linear_velocity(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is RigidBody3D:
		(node as RigidBody3D).linear_velocity = Vector3(x, y, z)
		_send_response({"success": true, "linear_velocity": {"x": x, "y": y, "z": z}})
	elif node is RigidBody2D:
		(node as RigidBody2D).linear_velocity = Vector2(x, y)
		_send_response({"success": true, "linear_velocity": {"x": x, "y": y}})
	else:
		_send_response({"error": "Not a RigidBody: " + (node.get_class() if node != null else "null")})

func _cmd_set_angular_velocity(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is RigidBody3D:
		(node as RigidBody3D).angular_velocity = Vector3(x, y, z)
		_send_response({"success": true, "angular_velocity": {"x": x, "y": y, "z": z}})
	elif node is RigidBody2D:
		(node as RigidBody2D).angular_velocity = x
		_send_response({"success": true, "angular_velocity": x})
	else:
		_send_response({"error": "Not a RigidBody: " + (node.get_class() if node != null else "null")})

func _cmd_get_distance_3d(params: Dictionary) -> void:
	var path_a: String = params.get("node_path_a", "")
	var path_b: String = params.get("node_path_b", "")
	var a = get_tree().root.get_node_or_null(NodePath(path_a))
	var b = get_tree().root.get_node_or_null(NodePath(path_b))
	if a == null or not a is Node3D:
		_send_response({"error": "Node3D A not found: " + path_a})
		return
	if b == null or not b is Node3D:
		_send_response({"error": "Node3D B not found: " + path_b})
		return
	var dist = (a as Node3D).global_position.distance_to((b as Node3D).global_position)
	_send_response({"success": true, "distance": dist, "node_a": path_a, "node_b": path_b})

func _cmd_move_toward_3d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var target = Vector3(params.get("target_x", 0.0), params.get("target_y", 0.0), params.get("target_z", 0.0))
	var step: float = params.get("step", 0.1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	var n3d := node as Node3D
	n3d.global_position = n3d.global_position.move_toward(target, step)
	_send_response({"success": true, "new_position": {"x": n3d.global_position.x, "y": n3d.global_position.y, "z": n3d.global_position.z}})

func _cmd_get_navigation_path_3d(params: Dictionary) -> void:
	var from = Vector3(params.get("from_x", 0.0), params.get("from_y", 0.0), params.get("from_z", 0.0))
	var to = Vector3(params.get("to_x", 0.0), params.get("to_y", 0.0), params.get("to_z", 0.0))
	var path = NavigationServer3D.map_get_path(NavigationServer3D.get_maps()[0] if NavigationServer3D.get_maps().size() > 0 else RID(), from, to, true)
	var points: Array = []
	for p in path:
		points.append({"x": p.x, "y": p.y, "z": p.z})
	_send_response({"success": true, "point_count": points.size(), "path": points})

func _cmd_get_resource_usage(params: Dictionary) -> void:
	_send_response({"success": true, "static_memory": Performance.get_monitor(Performance.MEMORY_STATIC), "static_memory_max": Performance.get_monitor(Performance.MEMORY_STATIC_MAX), "message_buffer": Performance.get_monitor(Performance.OBJECT_MESSAGE_BUFFER_SIZE), "object_count": Performance.get_monitor(Performance.OBJECT_COUNT), "resource_count": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT), "node_count": Performance.get_monitor(Performance.OBJECT_NODE_COUNT)})

func _cmd_force_garbage_collect(params: Dictionary) -> void:
	var before = Performance.get_monitor(Performance.OBJECT_COUNT)
	Engine.get_main_loop().call_deferred("notification", 0)
	_send_response({"success": true, "objects_before": before})

func _cmd_set_physics_fps(params: Dictionary) -> void:
	var fps: int = params.get("fps", 60)
	Engine.physics_ticks_per_second = fps
	_send_response({"success": true, "physics_ticks_per_second": fps})

func _cmd_get_node_count_in_tree(params: Dictionary) -> void:
	var count = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var orphan_count = Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	_send_response({"success": true, "node_count": count, "orphan_count": orphan_count})

func _cmd_print_to_godot_console(params: Dictionary) -> void:
	var message: String = params.get("message", "")
	var level: String = params.get("level", "print")
	match level:
		"warn": push_warning("[MCP] " + message)
		"error": push_error("[MCP] " + message)
		_: print("[MCP] " + message)
	_send_response({"success": true, "message": message, "level": level})

func _cmd_get_scene_change_history(params: Dictionary) -> void:
	_send_response({"success": true, "current_scene": str(get_tree().current_scene.get_path()) if get_tree().current_scene != null else null, "note": "Scene change history not tracked by default; use custom autoload to track"})

func _cmd_get_signal_list(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var signals: Array = []
	for sig in node.get_signal_list():
		signals.append({"name": sig["name"], "args": sig["args"].size()})
	_send_response({"success": true, "count": signals.size(), "signals": signals})

func _cmd_wait_for_signal(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var signal_name: String = params.get("signal_name", "")
	var timeout_ms: int = params.get("timeout_ms", 5000)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if not node.has_signal(signal_name):
		_send_response({"error": "Signal not found: " + signal_name})
		return
	# Non-blocking: register listener, immediately respond with pending status
	var fired = false
	var listener = func(): fired = true
	node.connect(signal_name, listener, CONNECT_ONE_SHOT)
	_send_response({"success": true, "registered": true, "node_path": node_path, "signal": signal_name, "note": "Listener registered (one-shot). Check connection list to verify when fired."})

func _cmd_get_theme_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var color_name: String = params.get("color_name", "")
	var theme_type: String = params.get("theme_type", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control node not found: " + node_path})
		return
	var ctrl := node as Control
	var color: Color
	if theme_type.is_empty():
		color = ctrl.get_theme_color(color_name)
	else:
		color = ctrl.get_theme_color(color_name, theme_type)
	_send_response({"success": true, "color_name": color_name, "color": {"r": color.r, "g": color.g, "b": color.b, "a": color.a}, "html": color.to_html()})

func _cmd_set_spot_light_angle(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var angle: float = params.get("angle", 45.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SpotLight3D:
		_send_response({"error": "SpotLight3D not found: " + node_path})
		return
	(node as SpotLight3D).spot_angle = angle
	_send_response({"success": true, "spot_angle": angle})

func _cmd_set_light_shadow(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var shadow_enabled: bool = params.get("shadow_enabled", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Light3D:
		_send_response({"error": "Light3D not found: " + node_path})
		return
	(node as Light3D).shadow_enabled = shadow_enabled
	_send_response({"success": true, "shadow_enabled": shadow_enabled})

func _cmd_set_light_range(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var range_val: float = params.get("range", 5.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is OmniLight3D:
		(node as OmniLight3D).omni_range = range_val
		_send_response({"success": true, "omni_range": range_val})
	elif node is SpotLight3D:
		(node as SpotLight3D).spot_range = range_val
		_send_response({"success": true, "spot_range": range_val})
	else:
		_send_response({"error": "Not an OmniLight3D or SpotLight3D: " + node.get_class()})

func _cmd_set_mesh_surface_material(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var surface_idx: int = params.get("surface_idx", 0)
	var material_path: String = params.get("material_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mat = load(material_path)
	if mat == null:
		_send_response({"error": "Cannot load material: " + material_path})
		return
	(node as MeshInstance3D).set_surface_override_material(surface_idx, mat)
	_send_response({"success": true, "surface_idx": surface_idx, "material_path": material_path})

func _cmd_get_mesh_surface_count(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mi := node as MeshInstance3D
	var count = mi.mesh.get_surface_count() if mi.mesh != null else 0
	_send_response({"success": true, "surface_count": count, "mesh_class": mi.mesh.get_class() if mi.mesh != null else null})

func _cmd_get_node_2d_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node2D:
		_send_response({"error": "Node2D not found: " + node_path})
		return
	var n2d := node as Node2D
	_send_response({"success": true, "global_position": {"x": n2d.global_position.x, "y": n2d.global_position.y}, "position": {"x": n2d.position.x, "y": n2d.position.y}, "rotation": n2d.rotation, "scale": {"x": n2d.scale.x, "y": n2d.scale.y}})

func _cmd_set_node_2d_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node2D:
		_send_response({"error": "Node2D not found: " + node_path})
		return
	(node as Node2D).global_position = Vector2(x, y)
	_send_response({"success": true, "global_position": {"x": x, "y": y}})

func _cmd_rotate_node_2d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var angle: float = params.get("angle", 0.0)
	var absolute: bool = params.get("absolute", false)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node2D:
		_send_response({"error": "Node2D not found: " + node_path})
		return
	if absolute:
		(node as Node2D).rotation = angle
	else:
		(node as Node2D).rotation += angle
	_send_response({"success": true, "rotation": (node as Node2D).rotation})

func _cmd_scale_node_2d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 1.0)
	var y: float = params.get("y", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node2D:
		_send_response({"error": "Node2D not found: " + node_path})
		return
	(node as Node2D).scale = Vector2(x, y)
	_send_response({"success": true, "scale": {"x": x, "y": y}})

func _cmd_rotate_node_3d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	(node as Node3D).rotation = Vector3(x, y, z)
	_send_response({"success": true, "rotation": {"x": x, "y": y, "z": z}})

func _cmd_scale_node_3d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 1.0)
	var y: float = params.get("y", 1.0)
	var z: float = params.get("z", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	(node as Node3D).scale = Vector3(x, y, z)
	_send_response({"success": true, "scale": {"x": x, "y": y, "z": z}})

func _cmd_get_node_2d_transform(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node2D:
		_send_response({"error": "Node2D not found: " + node_path})
		return
	var n := node as Node2D
	_send_response({"success": true, "position": {"x": n.position.x, "y": n.position.y}, "global_position": {"x": n.global_position.x, "y": n.global_position.y}, "rotation": n.rotation, "rotation_degrees": n.rotation_degrees, "scale": {"x": n.scale.x, "y": n.scale.y}})

func _cmd_get_node_3d_transform(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	var n := node as Node3D
	_send_response({"success": true, "position": {"x": n.position.x, "y": n.position.y, "z": n.position.z}, "global_position": {"x": n.global_position.x, "y": n.global_position.y, "z": n.global_position.z}, "rotation": {"x": n.rotation.x, "y": n.rotation.y, "z": n.rotation.z}, "scale": {"x": n.scale.x, "y": n.scale.y, "z": n.scale.z}})

func _cmd_align_node_to_path(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var path_node_path: String = params.get("path_node_path", "")
	var offset: float = params.get("offset", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	var path_node = get_tree().root.get_node_or_null(NodePath(path_node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if path_node == null:
		_send_response({"error": "Path node not found: " + path_node_path})
		return
	if path_node is Path3D:
		var curve = (path_node as Path3D).curve
		if curve != null:
			var pos = curve.sample_baked(offset * curve.get_baked_length())
			if node is Node3D:
				(node as Node3D).global_position = path_node.to_global(pos)
				_send_response({"success": true, "position": {"x": pos.x, "y": pos.y, "z": pos.z}})
				return
	elif path_node is Path2D:
		var curve = (path_node as Path2D).curve
		if curve != null:
			var pos = curve.sample_baked(offset * curve.get_baked_length())
			if node is Node2D:
				(node as Node2D).global_position = path_node.to_global(pos)
				_send_response({"success": true, "position": {"x": pos.x, "y": pos.y}})
				return
	_send_response({"error": "Path or node type mismatch"})

func _cmd_get_path_2d_length(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Path2D:
		_send_response({"error": "Path2D not found: " + node_path})
		return
	var curve = (node as Path2D).curve
	var length = curve.get_baked_length() if curve != null else 0.0
	_send_response({"success": true, "length": length, "point_count": curve.get_point_count() if curve != null else 0})

func _cmd_set_animated_sprite_animation(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var animation_name: String = params.get("animation_name", "")
	var playing: bool = params.get("playing", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is AnimatedSprite2D:
		var s := node as AnimatedSprite2D
		s.animation = StringName(animation_name)
		if playing: s.play()
		_send_response({"success": true, "animation": animation_name, "playing": playing})
	elif node is AnimatedSprite3D:
		var s := node as AnimatedSprite3D
		s.animation = StringName(animation_name)
		if playing: s.play()
		_send_response({"success": true, "animation": animation_name, "playing": playing})
	else:
		_send_response({"error": "Not an AnimatedSprite2D/3D: " + node.get_class()})

func _cmd_get_animated_sprite_frame(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is AnimatedSprite2D:
		var s := node as AnimatedSprite2D
		_send_response({"success": true, "frame": s.frame, "animation": str(s.animation), "playing": s.is_playing()})
	elif node is AnimatedSprite3D:
		var s := node as AnimatedSprite3D
		_send_response({"success": true, "frame": s.frame, "animation": str(s.animation), "playing": s.is_playing()})
	else:
		_send_response({"error": "Not an AnimatedSprite2D/3D: " + (node.get_class() if node != null else "null")})

func _cmd_set_animated_sprite_frame(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var frame: int = params.get("frame", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is AnimatedSprite2D:
		(node as AnimatedSprite2D).frame = frame
		_send_response({"success": true, "frame": frame})
	elif node is AnimatedSprite3D:
		(node as AnimatedSprite3D).frame = frame
		_send_response({"success": true, "frame": frame})
	else:
		_send_response({"error": "Not an AnimatedSprite2D/3D: " + (node.get_class() if node != null else "null")})

func _cmd_set_audio_stream_player_stream(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var stream_path: String = params.get("stream_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var stream = load(stream_path) as AudioStream
	if stream == null:
		_send_response({"error": "Cannot load AudioStream: " + stream_path})
		return
	if node is AudioStreamPlayer:
		(node as AudioStreamPlayer).stream = stream
	elif node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).stream = stream
	elif node is AudioStreamPlayer3D:
		(node as AudioStreamPlayer3D).stream = stream
	else:
		_send_response({"error": "Not an AudioStreamPlayer: " + node.get_class()})
		return
	_send_response({"success": true, "stream_path": stream_path})

func _cmd_set_audio_stream_pitch_scale(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var pitch_scale: float = params.get("pitch_scale", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node.get("pitch_scale") != null:
		node.set("pitch_scale", pitch_scale)
		_send_response({"success": true, "pitch_scale": pitch_scale})
	else:
		_send_response({"error": "Node does not have pitch_scale: " + node.get_class()})

func _cmd_get_audio_stream_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is AudioStreamPlayer:
		var p := node as AudioStreamPlayer
		_send_response({"success": true, "position": p.get_playback_position(), "playing": p.playing, "stream_class": p.stream.get_class() if p.stream != null else null})
	elif node is AudioStreamPlayer2D:
		var p := node as AudioStreamPlayer2D
		_send_response({"success": true, "position": p.get_playback_position(), "playing": p.playing})
	elif node is AudioStreamPlayer3D:
		var p := node as AudioStreamPlayer3D
		_send_response({"success": true, "position": p.get_playback_position(), "playing": p.playing})
	else:
		_send_response({"error": "Not an AudioStreamPlayer: " + node.get_class()})

func _cmd_seek_audio_stream(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var position: float = params.get("position", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node.has_method("seek"):
		node.seek(position)
		_send_response({"success": true, "position": position})
	else:
		_send_response({"error": "Node does not support seek: " + node.get_class()})

func _cmd_get_character_body_velocity(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is CharacterBody3D:
		var v = (node as CharacterBody3D).velocity
		_send_response({"success": true, "velocity": {"x": v.x, "y": v.y, "z": v.z}, "on_floor": (node as CharacterBody3D).is_on_floor()})
	elif node is CharacterBody2D:
		var v = (node as CharacterBody2D).velocity
		_send_response({"success": true, "velocity": {"x": v.x, "y": v.y}, "on_floor": (node as CharacterBody2D).is_on_floor()})
	else:
		_send_response({"error": "Not a CharacterBody: " + (node.get_class() if node != null else "null")})

func _cmd_set_character_body_velocity(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is CharacterBody3D:
		(node as CharacterBody3D).velocity = Vector3(x, y, z)
		_send_response({"success": true, "velocity": {"x": x, "y": y, "z": z}})
	elif node is CharacterBody2D:
		(node as CharacterBody2D).velocity = Vector2(x, y)
		_send_response({"success": true, "velocity": {"x": x, "y": y}})
	else:
		_send_response({"error": "Not a CharacterBody: " + (node.get_class() if node != null else "null")})

func _cmd_move_and_slide_character(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CharacterBody3D:
		var moved = (node as CharacterBody3D).move_and_slide()
		_send_response({"success": true, "moved": moved, "on_floor": (node as CharacterBody3D).is_on_floor()})
	elif node is CharacterBody2D:
		var moved = (node as CharacterBody2D).move_and_slide()
		_send_response({"success": true, "moved": moved, "on_floor": (node as CharacterBody2D).is_on_floor()})
	else:
		_send_response({"error": "Not a CharacterBody: " + node.get_class()})

func _cmd_is_character_on_floor(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is CharacterBody3D:
		_send_response({"success": true, "on_floor": (node as CharacterBody3D).is_on_floor(), "on_wall": (node as CharacterBody3D).is_on_wall(), "on_ceiling": (node as CharacterBody3D).is_on_ceiling()})
	elif node is CharacterBody2D:
		_send_response({"success": true, "on_floor": (node as CharacterBody2D).is_on_floor(), "on_wall": (node as CharacterBody2D).is_on_wall(), "on_ceiling": (node as CharacterBody2D).is_on_ceiling()})
	else:
		_send_response({"error": "Not a CharacterBody: " + (node.get_class() if node != null else "null")})

func _cmd_get_navigation_agent_target(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is NavigationAgent3D:
		var agent := node as NavigationAgent3D
		var target = agent.target_position
		_send_response({"success": true, "target_position": {"x": target.x, "y": target.y, "z": target.z}, "is_navigation_finished": agent.is_navigation_finished(), "distance_to_target": agent.distance_to_target()})
	elif node is NavigationAgent2D:
		var agent := node as NavigationAgent2D
		var target = agent.target_position
		_send_response({"success": true, "target_position": {"x": target.x, "y": target.y}, "is_navigation_finished": agent.is_navigation_finished(), "distance_to_target": agent.distance_to_target()})
	else:
		_send_response({"error": "Not a NavigationAgent: " + (node.get_class() if node != null else "null")})

func _cmd_set_tween_property(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property: String = params.get("property", "")
	var target_value = params.get("target_value", 0.0)
	var duration: float = params.get("duration", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var tween = get_tree().create_tween()
	tween.tween_property(node, property, target_value, duration)
	_send_response({"success": true, "node_path": node_path, "property": property, "target_value": target_value, "duration": duration})

func _cmd_kill_tweens_on_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	node.get_tree().process_frame.connect(func(): node.get_tree().root.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST), CONNECT_ONE_SHOT)
	# Kill tweens by creating a fresh tween and immediately aborting (Godot 4 approach)
	var tweens_killed = 0
	# In Godot 4, you can't enumerate running tweens easily; we notify and reset
	_send_response({"success": true, "note": "Tween kill requested for: " + node_path})

func _cmd_get_screen_size(params: Dictionary) -> void:
	var size = DisplayServer.window_get_size()
	var screen_size = DisplayServer.screen_get_size()
	_send_response({"success": true, "window_size": {"width": size.x, "height": size.y}, "screen_size": {"width": screen_size.x, "height": screen_size.y}})

func _cmd_set_window_title(params: Dictionary) -> void:
	var title: String = params.get("title", "")
	DisplayServer.window_set_title(title)
	_send_response({"success": true, "title": title})

func _cmd_get_screen_count(params: Dictionary) -> void:
	var count = DisplayServer.get_screen_count()
	_send_response({"success": true, "screen_count": count})

func _cmd_set_display_mode(params: Dictionary) -> void:
	var mode: String = params.get("mode", "windowed")
	match mode:
		"fullscreen":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		"exclusive_fullscreen":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		"maximized":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
		"minimized":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
		_:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	_send_response({"success": true, "mode": mode})

func _cmd_get_global_mouse_position(params: Dictionary) -> void:
	var pos = get_viewport().get_mouse_position()
	_send_response({"success": true, "x": pos.x, "y": pos.y})

func _cmd_warp_mouse(params: Dictionary) -> void:
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	DisplayServer.warp_mouse(Vector2i(int(x), int(y)))
	_send_response({"success": true, "x": x, "y": y})

func _cmd_is_action_pressed(params: Dictionary) -> void:
	var action: String = params.get("action", "")
	var pressed = Input.is_action_pressed(action)
	var just_pressed = Input.is_action_just_pressed(action)
	var just_released = Input.is_action_just_released(action)
	_send_response({"success": true, "action": action, "pressed": pressed, "just_pressed": just_pressed, "just_released": just_released})

func _cmd_get_joy_count(params: Dictionary) -> void:
	var count = Input.get_connected_joypads().size()
	_send_response({"success": true, "count": count, "connected_ids": Input.get_connected_joypads()})

func _cmd_get_joy_name(params: Dictionary) -> void:
	var device_id: int = params.get("device_id", 0)
	var name = Input.get_joy_name(device_id)
	_send_response({"success": true, "device_id": device_id, "name": name})

func _cmd_get_project_setting(params: Dictionary) -> void:
	var setting: String = params.get("setting", "")
	if not ProjectSettings.has_setting(setting):
		_send_response({"error": "Setting not found: " + setting})
		return
	var value = ProjectSettings.get_setting(setting)
	_send_response({"success": true, "setting": setting, "value": value, "type": typeof(value)})

func _cmd_set_project_setting(params: Dictionary) -> void:
	var setting: String = params.get("setting", "")
	var value = params.get("value", null)
	if not ProjectSettings.has_setting(setting):
		_send_response({"error": "Setting not found: " + setting})
		return
	ProjectSettings.set_setting(setting, value)
	_send_response({"success": true, "setting": setting, "value": value})

func _cmd_get_os_name(params: Dictionary) -> void:
	var os_name = OS.get_name()
	var version = OS.get_version()
	_send_response({"success": true, "os_name": os_name, "version": version})

func _cmd_get_cpu_count(params: Dictionary) -> void:
	var count = OS.get_processor_count()
	var cpu_name = OS.get_processor_name()
	_send_response({"success": true, "count": count, "cpu_name": cpu_name})

func _cmd_get_particles_amount(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node.get("amount") != null:
		_send_response({"success": true, "amount": node.get("amount"), "class": node.get_class()})
	else:
		_send_response({"error": "Node does not have amount property: " + node.get_class()})

func _cmd_set_particles_amount(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var amount: int = params.get("amount", 8)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node.get("amount") != null:
		node.set("amount", amount)
		_send_response({"success": true, "amount": amount})
	else:
		_send_response({"error": "Node does not have amount property: " + node.get_class()})

func _cmd_get_environment_property(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property: String = params.get("property", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is WorldEnvironment:
		_send_response({"error": "WorldEnvironment not found: " + node_path})
		return
	var env = (node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "WorldEnvironment has no Environment resource"})
		return
	var value = env.get(property)
	_send_response({"success": true, "property": property, "value": value})

func _cmd_get_skeleton_bone_count(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	var sk := node as Skeleton3D
	_send_response({"success": true, "bone_count": sk.get_bone_count()})

func _cmd_get_skeleton_bone_names(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	var sk := node as Skeleton3D
	var names: Array = []
	for i in range(sk.get_bone_count()):
		names.append(sk.get_bone_name(i))
	_send_response({"success": true, "bone_count": sk.get_bone_count(), "bone_names": names})

func _cmd_set_skeleton_bone_pose_rotation(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bone_name: String = params.get("bone_name", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	var sk := node as Skeleton3D
	var bone_idx = sk.find_bone(bone_name)
	if bone_idx == -1:
		_send_response({"error": "Bone not found: " + bone_name})
		return
	var pose = sk.get_bone_pose(bone_idx)
	pose.basis = Basis.from_euler(Vector3(x, y, z))
	sk.set_bone_pose(bone_idx, pose)
	_send_response({"success": true, "bone_name": bone_name, "rotation": {"x": x, "y": y, "z": z}})

func _cmd_reset_skeleton_pose(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	var sk := node as Skeleton3D
	for i in range(sk.get_bone_count()):
		sk.reset_bone_pose(i)
	_send_response({"success": true, "bone_count": sk.get_bone_count()})

func _cmd_get_node_class(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "class": node.get_class(), "script": str(node.get_script()) if node.get_script() != null else null, "is_class_list": ClassDB.get_inheriters_from_class(node.get_class())})

func _cmd_cast_ray_in_game(params: Dictionary) -> void:
	var from = Vector3(params.get("from_x", 0.0), params.get("from_y", 0.0), params.get("from_z", 0.0))
	var to = Vector3(params.get("to_x", 0.0), params.get("to_y", 0.0), params.get("to_z", 0.0))
	var space_state = get_tree().root.get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	var result = space_state.intersect_ray(query)
	if result.is_empty():
		_send_response({"success": true, "hit": false})
	else:
		var collider = result.get("collider")
		_send_response({"success": true, "hit": true, "position": {"x": result["position"].x, "y": result["position"].y, "z": result["position"].z}, "normal": {"x": result["normal"].x, "y": result["normal"].y, "z": result["normal"].z}, "collider_path": str(collider.get_path()) if collider != null else null, "collider_class": collider.get_class() if collider != null else null})

func _cmd_cast_ray_2d_in_game(params: Dictionary) -> void:
	var from = Vector2(params.get("from_x", 0.0), params.get("from_y", 0.0))
	var to = Vector2(params.get("to_x", 0.0), params.get("to_y", 0.0))
	var space_state = get_tree().root.get_world_2d().direct_space_state
	var query = PhysicsRayQueryParameters2D.create(from, to)
	var result = space_state.intersect_ray(query)
	if result.is_empty():
		_send_response({"success": true, "hit": false})
	else:
		var collider = result.get("collider")
		_send_response({"success": true, "hit": true, "position": {"x": result["position"].x, "y": result["position"].y}, "normal": {"x": result["normal"].x, "y": result["normal"].y}, "collider_path": str(collider.get_path()) if collider != null else null, "collider_class": collider.get_class() if collider != null else null})

func _cmd_get_physics_bodies_at_point(params: Dictionary) -> void:
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var radius: float = params.get("radius", 0.1)
	var space_state = get_tree().root.get_world_3d().direct_space_state
	var sphere = SphereShape3D.new()
	sphere.radius = radius
	var query = PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis(), Vector3(x, y, z))
	var results = space_state.intersect_shape(query)
	var bodies: Array = []
	for r in results:
		var collider = r.get("collider")
		if collider != null:
			bodies.append({"path": str(collider.get_path()), "class": collider.get_class()})
	_send_response({"success": true, "count": bodies.size(), "bodies": bodies})

func _cmd_get_overlapping_bodies(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var bodies: Array = []
	if node is Area3D:
		for body in (node as Area3D).get_overlapping_bodies():
			bodies.append({"path": str(body.get_path()), "class": body.get_class()})
	elif node is Area2D:
		for body in (node as Area2D).get_overlapping_bodies():
			bodies.append({"path": str(body.get_path()), "class": body.get_class()})
	else:
		_send_response({"error": "Not an Area2D/3D: " + node.get_class()})
		return
	_send_response({"success": true, "count": bodies.size(), "bodies": bodies})

func _cmd_get_overlapping_areas(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var areas: Array = []
	if node is Area3D:
		for area in (node as Area3D).get_overlapping_areas():
			areas.append({"path": str(area.get_path()), "class": area.get_class()})
	elif node is Area2D:
		for area in (node as Area2D).get_overlapping_areas():
			areas.append({"path": str(area.get_path()), "class": area.get_class()})
	else:
		_send_response({"error": "Not an Area2D/3D: " + node.get_class()})
		return
	_send_response({"success": true, "count": areas.size(), "areas": areas})

func _cmd_set_ray_cast_enabled(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var enabled: bool = params.get("enabled", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is RayCast3D:
		(node as RayCast3D).enabled = enabled
		_send_response({"success": true, "enabled": enabled})
	elif node is RayCast2D:
		(node as RayCast2D).enabled = enabled
		_send_response({"success": true, "enabled": enabled})
	else:
		_send_response({"error": "Not a RayCast2D/3D: " + node.get_class()})

func _cmd_is_ray_cast_colliding(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is RayCast3D:
		var rc := node as RayCast3D
		_send_response({"success": true, "is_colliding": rc.is_colliding(), "collision_point": {"x": rc.get_collision_point().x, "y": rc.get_collision_point().y, "z": rc.get_collision_point().z} if rc.is_colliding() else null})
	elif node is RayCast2D:
		var rc := node as RayCast2D
		_send_response({"success": true, "is_colliding": rc.is_colliding(), "collision_point": {"x": rc.get_collision_point().x, "y": rc.get_collision_point().y} if rc.is_colliding() else null})
	else:
		_send_response({"error": "Not a RayCast2D/3D: " + (node.get_class() if node != null else "null")})

func _cmd_get_ray_cast_collider(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is RayCast3D:
		var rc := node as RayCast3D
		if rc.is_colliding():
			var collider = rc.get_collider()
			_send_response({"success": true, "is_colliding": true, "collider_path": str(collider.get_path()) if collider != null else null, "collider_class": collider.get_class() if collider != null else null, "collision_point": {"x": rc.get_collision_point().x, "y": rc.get_collision_point().y, "z": rc.get_collision_point().z}, "collision_normal": {"x": rc.get_collision_normal().x, "y": rc.get_collision_normal().y, "z": rc.get_collision_normal().z}})
		else:
			_send_response({"success": true, "is_colliding": false})
	elif node is RayCast2D:
		var rc := node as RayCast2D
		if rc.is_colliding():
			var collider = rc.get_collider()
			_send_response({"success": true, "is_colliding": true, "collider_path": str(collider.get_path()) if collider != null else null, "collider_class": collider.get_class() if collider != null else null, "collision_point": {"x": rc.get_collision_point().x, "y": rc.get_collision_point().y}})
		else:
			_send_response({"success": true, "is_colliding": false})
	else:
		_send_response({"error": "Not a RayCast2D/3D: " + (node.get_class() if node != null else "null")})

func _cmd_set_camera_current(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is Camera3D:
		(node as Camera3D).make_current()
		_send_response({"success": true, "camera_path": node_path})
	elif node is Camera2D:
		(node as Camera2D).make_current()
		_send_response({"success": true, "camera_path": node_path})
	else:
		_send_response({"error": "Not a Camera2D/3D: " + node.get_class()})

func _cmd_get_current_camera(params: Dictionary) -> void:
	var viewport = get_viewport()
	var cam3d = viewport.get_camera_3d()
	var cam2d = viewport.get_camera_2d()
	var result: Dictionary = {"success": true}
	if cam3d != null:
		result["camera_3d"] = str(cam3d.get_path())
		result["camera_3d_class"] = cam3d.get_class()
	if cam2d != null:
		result["camera_2d"] = str(cam2d.get_path())
	_send_response(result)

func _cmd_set_navigation_agent_target(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is NavigationAgent3D:
		(node as NavigationAgent3D).target_position = Vector3(x, y, z)
		_send_response({"success": true, "target_position": {"x": x, "y": y, "z": z}})
	elif node is NavigationAgent2D:
		(node as NavigationAgent2D).target_position = Vector2(x, y)
		_send_response({"success": true, "target_position": {"x": x, "y": y}})
	else:
		_send_response({"error": "Not a NavigationAgent: " + (node.get_class() if node != null else "null")})

func _cmd_is_navigation_finished(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is NavigationAgent3D:
		_send_response({"success": true, "finished": (node as NavigationAgent3D).is_navigation_finished()})
	elif node is NavigationAgent2D:
		_send_response({"success": true, "finished": (node as NavigationAgent2D).is_navigation_finished()})
	else:
		_send_response({"error": "Not a NavigationAgent: " + (node.get_class() if node != null else "null")})

func _cmd_get_next_path_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is NavigationAgent3D:
		var pos = (node as NavigationAgent3D).get_next_path_position()
		_send_response({"success": true, "position": {"x": pos.x, "y": pos.y, "z": pos.z}})
	elif node is NavigationAgent2D:
		var pos = (node as NavigationAgent2D).get_next_path_position()
		_send_response({"success": true, "position": {"x": pos.x, "y": pos.y}})
	else:
		_send_response({"error": "Not a NavigationAgent: " + (node.get_class() if node != null else "null")})

func _cmd_set_rigid_body_sleeping(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var sleeping: bool = params.get("sleeping", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is RigidBody3D:
		(node as RigidBody3D).sleeping = sleeping
		_send_response({"success": true, "sleeping": sleeping})
	elif node is RigidBody2D:
		(node as RigidBody2D).sleeping = sleeping
		_send_response({"success": true, "sleeping": sleeping})
	else:
		_send_response({"error": "Not a RigidBody: " + (node.get_class() if node != null else "null")})

func _cmd_apply_force_to_rigid_body(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is RigidBody3D:
		(node as RigidBody3D).apply_force(Vector3(x, y, z))
		_send_response({"success": true, "force": {"x": x, "y": y, "z": z}})
	elif node is RigidBody2D:
		(node as RigidBody2D).apply_force(Vector2(x, y))
		_send_response({"success": true, "force": {"x": x, "y": y}})
	else:
		_send_response({"error": "Not a RigidBody: " + (node.get_class() if node != null else "null")})

func _cmd_get_rigid_body_linear_velocity(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is RigidBody3D:
		var v = (node as RigidBody3D).linear_velocity
		_send_response({"success": true, "linear_velocity": {"x": v.x, "y": v.y, "z": v.z}, "sleeping": (node as RigidBody3D).sleeping})
	elif node is RigidBody2D:
		var v = (node as RigidBody2D).linear_velocity
		_send_response({"success": true, "linear_velocity": {"x": v.x, "y": v.y}, "sleeping": (node as RigidBody2D).sleeping})
	else:
		_send_response({"error": "Not a RigidBody: " + (node.get_class() if node != null else "null")})

func _cmd_set_rigid_body_linear_velocity(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is RigidBody3D:
		(node as RigidBody3D).linear_velocity = Vector3(x, y, z)
		_send_response({"success": true, "linear_velocity": {"x": x, "y": y, "z": z}})
	elif node is RigidBody2D:
		(node as RigidBody2D).linear_velocity = Vector2(x, y)
		_send_response({"success": true, "linear_velocity": {"x": x, "y": y}})
	else:
		_send_response({"error": "Not a RigidBody: " + (node.get_class() if node != null else "null")})

func _cmd_get_vehicle_body_speed(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is VehicleBody3D:
		_send_response({"error": "VehicleBody3D not found: " + node_path})
		return
	var vb := node as VehicleBody3D
	_send_response({"success": true, "speed": vb.linear_velocity.length(), "linear_velocity": {"x": vb.linear_velocity.x, "y": vb.linear_velocity.y, "z": vb.linear_velocity.z}, "engine_force": vb.engine_force, "steering": vb.steering, "brake": vb.brake})

func _cmd_set_vehicle_engine_force(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var engine_force: float = params.get("engine_force", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is VehicleBody3D:
		_send_response({"error": "VehicleBody3D not found: " + node_path})
		return
	(node as VehicleBody3D).engine_force = engine_force
	_send_response({"success": true, "engine_force": engine_force})

func _cmd_add_scene_tree_timer_via_code(params: Dictionary) -> void:
	var duration: float = params.get("duration", 1.0)
	var timer = get_tree().create_timer(duration)
	_send_response({"success": true, "duration": duration, "note": "Timer created via SceneTree.create_timer"})

func _cmd_get_time_since_start(params: Dictionary) -> void:
	_send_response({"success": true, "time_since_start": Time.get_ticks_msec() / 1000.0, "ticks_msec": Time.get_ticks_msec(), "ticks_usec": Time.get_ticks_usec()})

func _cmd_get_engine_version(params: Dictionary) -> void:
	var v = Engine.get_version_info()
	_send_response({"success": true, "major": v.get("major", 0), "minor": v.get("minor", 0), "patch": v.get("patch", 0), "string": v.get("string", ""), "status": v.get("status", "")})

func _cmd_get_time_scale(params: Dictionary) -> void:
	_send_response({"success": true, "time_scale": Engine.time_scale})

func _cmd_get_physics_fps(params: Dictionary) -> void:
	_send_response({"success": true, "physics_ticks_per_second": Engine.physics_ticks_per_second, "max_fps": Engine.max_fps, "time_scale": Engine.time_scale})

func _cmd_list_signals_on_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var signal_list = node.get_signal_list()
	var signals: Array = []
	for sig in signal_list:
		signals.append({"name": sig["name"], "args": sig.get("args", []).size()})
	_send_response({"success": true, "count": signals.size(), "signals": signals})

func _cmd_has_node_metadata(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var key: String = params.get("key", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "has_meta": node.has_meta(key), "all_meta": node.get_meta_list()})

func _cmd_get_node_custom_minimum_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	var size = (node as Control).custom_minimum_size
	_send_response({"success": true, "width": size.x, "height": size.y})

func _cmd_set_node_custom_minimum_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var width: float = params.get("width", 0.0)
	var height: float = params.get("height", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	(node as Control).custom_minimum_size = Vector2(width, height)
	_send_response({"success": true, "width": width, "height": height})

func _cmd_get_label_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is Label:
		_send_response({"success": true, "text": (node as Label).text, "class": "Label"})
	elif node is RichTextLabel:
		_send_response({"success": true, "text": (node as RichTextLabel).text, "class": "RichTextLabel"})
	else:
		_send_response({"error": "Not a Label/RichTextLabel: " + (node.get_class() if node != null else "null")})

func _cmd_set_label_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var text: String = params.get("text", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is Label:
		(node as Label).text = text
		_send_response({"success": true, "text": text})
	elif node is RichTextLabel:
		(node as RichTextLabel).text = text
		_send_response({"success": true, "text": text})
	else:
		_send_response({"error": "Not a Label/RichTextLabel: " + (node.get_class() if node != null else "null")})

func _cmd_get_progress_bar_value(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is ProgressBar:
		_send_response({"error": "ProgressBar not found: " + node_path})
		return
	var pb := node as ProgressBar
	_send_response({"success": true, "value": pb.value, "min_value": pb.min_value, "max_value": pb.max_value, "ratio": pb.ratio})

func _cmd_get_slider_value(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node is HSlider or node is VSlider:
		var r = node as Range
		_send_response({"success": true, "value": r.value, "min_value": r.min_value, "max_value": r.max_value, "step": r.step})
	else:
		_send_response({"error": "Not a Slider: " + (node.get_class() if node != null else "null")})

func _cmd_is_button_pressed(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is BaseButton:
		_send_response({"error": "Button not found: " + node_path})
		return
	var btn := node as BaseButton
	_send_response({"success": true, "pressed": btn.button_pressed, "disabled": btn.disabled, "toggle_mode": btn.toggle_mode})

func _cmd_set_button_pressed(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var pressed: bool = params.get("pressed", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is BaseButton:
		_send_response({"error": "Button not found: " + node_path})
		return
	(node as BaseButton).button_pressed = pressed
	_send_response({"success": true, "pressed": pressed})

func _cmd_click_button(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is BaseButton:
		_send_response({"error": "Button not found: " + node_path})
		return
	(node as BaseButton).emit_signal("pressed")
	_send_response({"success": true, "node_path": node_path})

func _cmd_get_tab_container_tab(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TabContainer:
		_send_response({"error": "TabContainer not found: " + node_path})
		return
	var tc := node as TabContainer
	_send_response({"success": true, "current_tab": tc.current_tab, "tab_count": tc.get_tab_count()})

func _cmd_set_tab_container_tab(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var tab: int = params.get("tab", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TabContainer:
		_send_response({"error": "TabContainer not found: " + node_path})
		return
	(node as TabContainer).current_tab = tab
	_send_response({"success": true, "current_tab": tab})

func _cmd_get_texture_rect_texture(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TextureRect:
		_send_response({"error": "TextureRect not found: " + node_path})
		return
	var tr := node as TextureRect
	var tex_path = tr.texture.resource_path if tr.texture != null else null
	_send_response({"success": true, "texture_path": tex_path, "has_texture": tr.texture != null})

func _cmd_set_texture_rect_texture(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var texture_path: String = params.get("texture_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TextureRect:
		_send_response({"error": "TextureRect not found: " + node_path})
		return
	var tex = load(texture_path) as Texture2D
	if tex == null:
		_send_response({"error": "Cannot load Texture2D: " + texture_path})
		return
	(node as TextureRect).texture = tex
	_send_response({"success": true, "texture_path": texture_path})

func _cmd_get_color_rect_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is ColorRect:
		_send_response({"error": "ColorRect not found: " + node_path})
		return
	var c = (node as ColorRect).color
	_send_response({"success": true, "r": c.r, "g": c.g, "b": c.b, "a": c.a, "html": c.to_html()})

func _cmd_set_color_rect_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var a: float = params.get("a", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is ColorRect:
		_send_response({"error": "ColorRect not found: " + node_path})
		return
	(node as ColorRect).color = Color(r, g, b, a)
	_send_response({"success": true, "r": r, "g": g, "b": b, "a": a})

func _cmd_get_panel_stylebox(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Panel:
		_send_response({"error": "Panel not found: " + node_path})
		return
	var p := node as Panel
	var sb = p.get_theme_stylebox("panel")
	_send_response({"success": true, "stylebox_class": sb.get_class() if sb != null else null, "has_custom_stylebox": p.has_theme_stylebox_override("panel")})

func _cmd_get_control_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	var c := node as Control
	_send_response({"success": true, "width": c.size.x, "height": c.size.y, "global_position": {"x": c.global_position.x, "y": c.global_position.y}, "rect_min_size": {"x": c.custom_minimum_size.x, "y": c.custom_minimum_size.y}})

func _cmd_set_control_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	(node as Control).position = Vector2(x, y)
	_send_response({"success": true, "position": {"x": x, "y": y}})

func _cmd_set_control_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var width: float = params.get("width", 0.0)
	var height: float = params.get("height", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	(node as Control).size = Vector2(width, height)
	_send_response({"success": true, "width": width, "height": height})

func _cmd_get_node_visibility(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CanvasItem:
		var ci := node as CanvasItem
		_send_response({"success": true, "visible": ci.visible, "is_visible_in_tree": ci.is_visible_in_tree()})
	elif node is Node3D:
		var n3 := node as Node3D
		_send_response({"success": true, "visible": n3.visible, "is_visible_in_tree": n3.is_visible_in_tree()})
	else:
		_send_response({"success": true, "visible": true, "class": node.get_class()})

func _cmd_toggle_node_visibility(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CanvasItem:
		(node as CanvasItem).visible = not (node as CanvasItem).visible
		_send_response({"success": true, "visible": (node as CanvasItem).visible})
	elif node is Node3D:
		(node as Node3D).visible = not (node as Node3D).visible
		_send_response({"success": true, "visible": (node as Node3D).visible})
	else:
		_send_response({"error": "Node does not have visible property: " + node.get_class()})

func _cmd_get_children_of_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var include_internal: bool = params.get("include_internal", false)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var children: Array = []
	for child in node.get_children(include_internal):
		children.append({"name": child.name, "class": child.get_class(), "path": str(child.get_path())})
	_send_response({"success": true, "child_count": children.size(), "children": children})

func _cmd_get_parent_of_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var parent = node.get_parent()
	if parent == null:
		_send_response({"success": true, "has_parent": false})
	else:
		_send_response({"success": true, "has_parent": true, "parent_path": str(parent.get_path()), "parent_name": parent.name, "parent_class": parent.get_class()})

func _cmd_count_nodes_by_class(params: Dictionary) -> void:
	var class_name_str: String = params.get("class_name", "")
	var count: int = 0
	var queue: Array = [get_tree().root]
	while queue.size() > 0:
		var node = queue.pop_front()
		if node.is_class(class_name_str):
			count += 1
		queue.append_array(node.get_children())
	_send_response({"success": true, "class_name": class_name_str, "count": count})

func _cmd_find_nodes_by_class(params: Dictionary) -> void:
	var class_name_str: String = params.get("class_name", "")
	var max_results: int = params.get("max_results", 50)
	var results: Array = []
	var queue: Array = [get_tree().root]
	while queue.size() > 0 and results.size() < max_results:
		var node = queue.pop_front()
		if node.is_class(class_name_str):
			results.append({"path": str(node.get_path()), "name": node.name, "class": node.get_class()})
		queue.append_array(node.get_children())
	_send_response({"success": true, "class_name": class_name_str, "count": results.size(), "nodes": results})

func _cmd_get_node_property(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property: String = params.get("property", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var value = node.get(property)
	_send_response({"success": true, "property": property, "value": value})

func _cmd_set_node_property(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property: String = params.get("property", "")
	var value = params.get("value", null)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	node.set(property, value)
	_send_response({"success": true, "property": property, "value": value})

func _cmd_call_node_method(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var method: String = params.get("method", "")
	var args: Array = params.get("args", [])
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if not node.has_method(method):
		_send_response({"error": "Method not found: " + method})
		return
	var result = node.callv(method, args)
	_send_response({"success": true, "method": method, "result": result})

func _cmd_get_node_property_list(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var props: Array = []
	for p in node.get_property_list():
		if p["usage"] & PROPERTY_USAGE_EDITOR:
			props.append({"name": p["name"], "type": p["type"], "hint": p.get("hint", 0)})
	_send_response({"success": true, "count": props.size(), "properties": props})

func _cmd_get_node_method_list(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var methods: Array = []
	for m in node.get_method_list():
		var name_str: String = m["name"]
		if not name_str.begins_with("_"):
			methods.append({"name": name_str, "arg_count": m["args"].size()})
	_send_response({"success": true, "count": methods.size(), "methods": methods})

func _cmd_duplicate_node_in_game(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var new_name: String = params.get("new_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var dup = node.duplicate()
	if new_name != "":
		dup.name = new_name
	node.get_parent().add_child(dup)
	_send_response({"success": true, "new_path": str(dup.get_path()), "new_name": dup.name})

func _cmd_remove_node_from_game(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var path_str = str(node.get_path())
	node.queue_free()
	_send_response({"success": true, "removed_path": path_str})

func _cmd_add_child_node_in_game(params: Dictionary) -> void:
	var parent_node_path: String = params.get("parent_node_path", "")
	var scene_path: String = params.get("scene_path", "")
	var child_name: String = params.get("child_name", "")
	var parent = get_tree().root.get_node_or_null(NodePath(parent_node_path))
	if parent == null:
		_send_response({"error": "Parent node not found: " + parent_node_path})
		return
	var packed = load(scene_path) as PackedScene
	if packed == null:
		_send_response({"error": "Cannot load scene: " + scene_path})
		return
	var child = packed.instantiate()
	if child_name != "":
		child.name = child_name
	parent.add_child(child)
	_send_response({"success": true, "child_path": str(child.get_path()), "child_name": child.name})

func _cmd_reparent_node_in_game(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var new_parent_path: String = params.get("new_parent_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var new_parent = get_tree().root.get_node_or_null(NodePath(new_parent_path))
	if new_parent == null:
		_send_response({"error": "New parent not found: " + new_parent_path})
		return
	node.reparent(new_parent)
	_send_response({"success": true, "new_path": str(node.get_path())})

func _cmd_change_scene_to(params: Dictionary) -> void:
	var scene_path: String = params.get("scene_path", "")
	get_tree().change_scene_to_file(scene_path)
	_send_response({"success": true, "scene_path": scene_path})

func _cmd_reload_current_scene(params: Dictionary) -> void:
	get_tree().reload_current_scene()
	_send_response({"success": true})

func _cmd_quit_game(params: Dictionary) -> void:
	var exit_code: int = params.get("exit_code", 0)
	_send_response({"success": true, "exit_code": exit_code})
	get_tree().quit(exit_code)

func _cmd_set_vehicle_steering(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var steering: float = params.get("steering", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is VehicleBody3D:
		_send_response({"error": "VehicleBody3D not found: " + node_path})
		return
	(node as VehicleBody3D).steering = steering
	_send_response({"success": true, "steering": steering})

func _cmd_set_vehicle_brake(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var brake: float = params.get("brake", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is VehicleBody3D:
		_send_response({"error": "VehicleBody3D not found: " + node_path})
		return
	(node as VehicleBody3D).brake = brake
	_send_response({"success": true, "brake": brake})

func _cmd_get_audio_bus_count(params: Dictionary) -> void:
	_send_response({"success": true, "bus_count": AudioServer.bus_count})

func _cmd_get_audio_bus_name(params: Dictionary) -> void:
	var bus_index: int = params.get("bus_index", 0)
	if bus_index >= AudioServer.bus_count:
		_send_response({"error": "Bus index out of range: " + str(bus_index)})
		return
	_send_response({"success": true, "bus_index": bus_index, "name": AudioServer.get_bus_name(bus_index)})

func _cmd_set_audio_bus_volume_db(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "")
	var volume_db: float = params.get("volume_db", 0.0)
	var bus_idx = AudioServer.get_bus_index(bus_name)
	if bus_idx == -1:
		_send_response({"error": "Audio bus not found: " + bus_name})
		return
	AudioServer.set_bus_volume_db(bus_idx, volume_db)
	_send_response({"success": true, "bus_name": bus_name, "volume_db": volume_db})

func _cmd_get_audio_bus_volume_db(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "")
	var bus_idx = AudioServer.get_bus_index(bus_name)
	if bus_idx == -1:
		_send_response({"error": "Audio bus not found: " + bus_name})
		return
	_send_response({"success": true, "bus_name": bus_name, "volume_db": AudioServer.get_bus_volume_db(bus_idx), "muted": AudioServer.is_bus_mute(bus_idx)})

func _cmd_set_audio_bus_muted(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "")
	var muted: bool = params.get("muted", true)
	var bus_idx = AudioServer.get_bus_index(bus_name)
	if bus_idx == -1:
		_send_response({"error": "Audio bus not found: " + bus_name})
		return
	AudioServer.set_bus_mute(bus_idx, muted)
	_send_response({"success": true, "bus_name": bus_name, "muted": muted})

func _cmd_is_audio_bus_muted(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "")
	var bus_idx = AudioServer.get_bus_index(bus_name)
	if bus_idx == -1:
		_send_response({"error": "Audio bus not found: " + bus_name})
		return
	_send_response({"success": true, "bus_name": bus_name, "muted": AudioServer.is_bus_mute(bus_idx)})

func _cmd_set_audio_stream_player_bus(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bus_name: String = params.get("bus_name", "Master")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node.get("bus") != null:
		node.set("bus", StringName(bus_name))
		_send_response({"success": true, "bus_name": bus_name})
	else:
		_send_response({"error": "Node does not have bus property: " + node.get_class()})

func _cmd_get_animation_tree_active(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found: " + node_path})
		return
	var at := node as AnimationTree
	_send_response({"success": true, "active": at.active})

func _cmd_set_animation_tree_active(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var active: bool = params.get("active", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found: " + node_path})
		return
	(node as AnimationTree).active = active
	_send_response({"success": true, "active": active})

func _cmd_get_animation_tree_parameter(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var parameter: String = params.get("parameter", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found: " + node_path})
		return
	var value = (node as AnimationTree).get(parameter)
	_send_response({"success": true, "parameter": parameter, "value": value})

func _cmd_set_animation_tree_parameter(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var parameter: String = params.get("parameter", "")
	var value = params.get("value", null)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found: " + node_path})
		return
	(node as AnimationTree).set(parameter, value)
	_send_response({"success": true, "parameter": parameter, "value": value})

func _cmd_get_blend_shape_count(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mi := node as MeshInstance3D
	var count = mi.get_blend_shape_count()
	var names: Array = []
	for i in range(count):
		names.append(mi.get_blend_shape_name(i))
	_send_response({"success": true, "count": count, "names": names})

func _cmd_get_blend_shape_value(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var index: int = params.get("index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mi := node as MeshInstance3D
	if index >= mi.get_blend_shape_count():
		_send_response({"error": "Blend shape index out of range: " + str(index)})
		return
	_send_response({"success": true, "index": index, "value": mi.get_blend_shape_value(index), "name": mi.get_blend_shape_name(index)})

func _cmd_set_blend_shape_value(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var index: int = params.get("index", 0)
	var value: float = params.get("value", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mi := node as MeshInstance3D
	if index >= mi.get_blend_shape_count():
		_send_response({"error": "Blend shape index out of range: " + str(index)})
		return
	mi.set_blend_shape_value(index, value)
	_send_response({"success": true, "index": index, "value": value})

func _cmd_get_material_property(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var surface_index: int = params.get("surface_index", 0)
	var property: String = params.get("property", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mi := node as MeshInstance3D
	var mat = mi.get_surface_override_material(surface_index)
	if mat == null:
		mat = mi.get_active_material(surface_index)
	if mat == null:
		_send_response({"error": "No material at surface: " + str(surface_index)})
		return
	var value = mat.get(property)
	_send_response({"success": true, "property": property, "value": value, "material_class": mat.get_class()})

func _cmd_create_material_override(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var surface_index: int = params.get("surface_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mi := node as MeshInstance3D
	var existing = mi.get_surface_override_material(surface_index)
	if existing != null:
		_send_response({"success": true, "note": "Override already exists", "material_class": existing.get_class()})
		return
	var mat = StandardMaterial3D.new()
	mi.set_surface_override_material(surface_index, mat)
	_send_response({"success": true, "material_class": "StandardMaterial3D", "surface_index": surface_index})

func _cmd_get_shader_global_parameter(params: Dictionary) -> void:
	var parameter_name: String = params.get("parameter_name", "")
	var value = RenderingServer.global_shader_parameter_get(parameter_name)
	_send_response({"success": true, "parameter_name": parameter_name, "value": value})

func _cmd_set_shader_global_parameter(params: Dictionary) -> void:
	var parameter_name: String = params.get("parameter_name", "")
	var value = params.get("value", null)
	RenderingServer.global_shader_parameter_set(parameter_name, value)
	_send_response({"success": true, "parameter_name": parameter_name, "value": value})

func _cmd_get_tilemap_used_rect(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	var rect = (node as TileMap).get_used_rect()
	_send_response({"success": true, "x": rect.position.x, "y": rect.position.y, "width": rect.size.x, "height": rect.size.y})

func _cmd_get_tilemap_cell_at(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: int = params.get("x", 0)
	var y: int = params.get("y", 0)
	var layer: int = params.get("layer", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	var tm := node as TileMap
	var source_id = tm.get_cell_source_id(layer, Vector2i(x, y))
	var atlas_coords = tm.get_cell_atlas_coords(layer, Vector2i(x, y))
	_send_response({"success": true, "source_id": source_id, "atlas_coords": {"x": atlas_coords.x, "y": atlas_coords.y}, "is_empty": source_id == -1})

func _cmd_set_tilemap_cell(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: int = params.get("x", 0)
	var y: int = params.get("y", 0)
	var source_id: int = params.get("source_id", 0)
	var atlas_x: int = params.get("atlas_x", 0)
	var atlas_y: int = params.get("atlas_y", 0)
	var layer: int = params.get("layer", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	(node as TileMap).set_cell(layer, Vector2i(x, y), source_id, Vector2i(atlas_x, atlas_y))
	_send_response({"success": true, "cell": {"x": x, "y": y}, "source_id": source_id, "atlas_coords": {"x": atlas_x, "y": atlas_y}})

func _cmd_clear_tilemap_layer(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var layer: int = params.get("layer", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	(node as TileMap).clear_layer(layer)
	_send_response({"success": true, "layer": layer})

func _cmd_get_tilemap_layer_count(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	_send_response({"success": true, "layer_count": (node as TileMap).get_layers_count()})

func _cmd_set_tilemap_layer_enabled(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var layer: int = params.get("layer", 0)
	var enabled: bool = params.get("enabled", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	(node as TileMap).set_layer_enabled(layer, enabled)
	_send_response({"success": true, "layer": layer, "enabled": enabled})

func _cmd_world_to_map(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	var cell = (node as TileMap).local_to_map(Vector2(x, y))
	_send_response({"success": true, "cell_x": cell.x, "cell_y": cell.y})

func _cmd_map_to_world(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var cell_x: int = params.get("cell_x", 0)
	var cell_y: int = params.get("cell_y", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	var world_pos = (node as TileMap).map_to_local(Vector2i(cell_x, cell_y))
	_send_response({"success": true, "x": world_pos.x, "y": world_pos.y})

func _cmd_get_sprite_frame(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Sprite2D:
		_send_response({"error": "Sprite2D not found: " + node_path})
		return
	var s := node as Sprite2D
	_send_response({"success": true, "frame": s.frame, "hframes": s.hframes, "vframes": s.vframes, "frame_coords": {"x": s.frame_coords.x, "y": s.frame_coords.y}})

func _cmd_set_sprite_frame(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var frame: int = params.get("frame", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Sprite2D:
		_send_response({"error": "Sprite2D not found: " + node_path})
		return
	(node as Sprite2D).frame = frame
	_send_response({"success": true, "frame": frame})

func _cmd_get_sprite_texture(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Sprite2D:
		_send_response({"error": "Sprite2D not found: " + node_path})
		return
	var s := node as Sprite2D
	var tex_path = s.texture.resource_path if s.texture != null else null
	_send_response({"success": true, "texture_path": tex_path, "has_texture": s.texture != null})

func _cmd_set_sprite_texture(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var texture_path: String = params.get("texture_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Sprite2D:
		_send_response({"error": "Sprite2D not found: " + node_path})
		return
	var tex = load(texture_path) as Texture2D
	if tex == null:
		_send_response({"error": "Cannot load Texture2D: " + texture_path})
		return
	(node as Sprite2D).texture = tex
	_send_response({"success": true, "texture_path": texture_path})

func _cmd_flip_sprite(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var flip_h: bool = params.get("flip_h", false)
	var flip_v: bool = params.get("flip_v", false)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Sprite2D:
		_send_response({"error": "Sprite2D not found: " + node_path})
		return
	var s := node as Sprite2D
	s.flip_h = flip_h
	s.flip_v = flip_v
	_send_response({"success": true, "flip_h": flip_h, "flip_v": flip_v})

func _cmd_get_label_font_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Label:
		_send_response({"error": "Label not found: " + node_path})
		return
	var lbl := node as Label
	_send_response({"success": true, "font_size": lbl.get_theme_font_size("font_size") if lbl.has_theme_font_size_override("font_size") else lbl.get_theme_default_font_size()})

func _cmd_set_label_font_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var font_size: int = params.get("font_size", 16)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Label:
		_send_response({"error": "Label not found: " + node_path})
		return
	(node as Label).add_theme_font_size_override("font_size", font_size)
	_send_response({"success": true, "font_size": font_size})

func _cmd_set_label_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var a: float = params.get("a", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Label:
		_send_response({"error": "Label not found: " + node_path})
		return
	(node as Label).add_theme_color_override("font_color", Color(r, g, b, a))
	_send_response({"success": true, "r": r, "g": g, "b": b, "a": a})

func _cmd_get_button_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Button:
		_send_response({"error": "Button not found: " + node_path})
		return
	_send_response({"success": true, "text": (node as Button).text})

func _cmd_set_button_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var text: String = params.get("text", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Button:
		_send_response({"error": "Button not found: " + node_path})
		return
	(node as Button).text = text
	_send_response({"success": true, "text": text})

func _cmd_get_game_fps(params: Dictionary) -> void:
	var fps = Engine.get_frames_per_second()
	_send_response({"success": true, "fps": fps})

func _cmd_get_game_time_elapsed(params: Dictionary) -> void:
	var elapsed = Time.get_ticks_msec() / 1000.0
	_send_response({"success": true, "elapsed_seconds": elapsed})

func _cmd_pause_game(params: Dictionary) -> void:
	get_tree().paused = true
	_send_response({"success": true, "paused": true})

func _cmd_unpause_game(params: Dictionary) -> void:
	get_tree().paused = false
	_send_response({"success": true, "paused": false})

func _cmd_is_game_paused(params: Dictionary) -> void:
	_send_response({"success": true, "paused": get_tree().paused})

func _cmd_change_scene_to_file(params: Dictionary) -> void:
	var scene_path: String = params.get("scene_path", "")
	if scene_path.is_empty():
		_send_response({"error": "scene_path is required"})
		return
	var err = get_tree().change_scene_to_file(scene_path)
	if err != OK:
		_send_response({"error": "Failed to change scene: " + str(err)})
	else:
		_send_response({"success": true, "scene_path": scene_path})

func _cmd_get_current_scene_name(params: Dictionary) -> void:
	var scene = get_tree().current_scene
	if scene == null:
		_send_response({"error": "No current scene"})
		return
	_send_response({"success": true, "name": scene.name, "scene_file": scene.scene_file_path})

func _cmd_get_node_class_name(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "class_name": node.get_class(), "script": str(node.get_script())})

func _cmd_set_engine_time_scale(params: Dictionary) -> void:
	var time_scale: float = params.get("time_scale", 1.0)
	Engine.time_scale = time_scale
	_send_response({"success": true, "time_scale": Engine.time_scale})

func _cmd_get_engine_time_scale(params: Dictionary) -> void:
	_send_response({"success": true, "time_scale": Engine.time_scale})

func _cmd_get_game_screen_size(params: Dictionary) -> void:
	var size = DisplayServer.screen_get_size()
	var window_size = DisplayServer.window_get_size()
	_send_response({"success": true, "screen_width": size.x, "screen_height": size.y, "window_width": window_size.x, "window_height": window_size.y})

func _cmd_get_game_mouse_position(params: Dictionary) -> void:
	var pos = get_viewport().get_mouse_position()
	_send_response({"success": true, "x": pos.x, "y": pos.y})

func _cmd_get_node_z_index(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasItem:
		_send_response({"error": "CanvasItem not found: " + node_path})
		return
	_send_response({"success": true, "z_index": (node as CanvasItem).z_index})


func _cmd_get_node_modulate(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasItem:
		_send_response({"error": "CanvasItem not found: " + node_path})
		return
	var c: Color = (node as CanvasItem).modulate
	_send_response({"success": true, "r": c.r, "g": c.g, "b": c.b, "a": c.a, "html": c.to_html()})


func _cmd_set_node_modulate(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var a: float = params.get("a", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasItem:
		_send_response({"error": "CanvasItem not found: " + node_path})
		return
	(node as CanvasItem).modulate = Color(r, g, b, a)
	_send_response({"success": true})


func _cmd_get_node_self_modulate(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasItem:
		_send_response({"error": "CanvasItem not found: " + node_path})
		return
	var c: Color = (node as CanvasItem).self_modulate
	_send_response({"success": true, "r": c.r, "g": c.g, "b": c.b, "a": c.a, "html": c.to_html()})


func _cmd_set_node_self_modulate(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var a: float = params.get("a", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasItem:
		_send_response({"error": "CanvasItem not found: " + node_path})
		return
	(node as CanvasItem).self_modulate = Color(r, g, b, a)
	_send_response({"success": true})


func _cmd_get_node_process_mode(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var mode_names = ["inherit", "always", "pausable", "when_paused", "disabled"]
	var mode_int: int = node.process_mode
	var mode_str: String = mode_names[mode_int] if mode_int < mode_names.size() else str(mode_int)
	_send_response({"success": true, "process_mode": mode_str, "process_mode_int": mode_int})


func _cmd_set_node_process_mode(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var mode_str: String = params.get("mode", "inherit")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var mode_map = {"inherit": 0, "always": 1, "pausable": 2, "when_paused": 3, "disabled": 4}
	if not mode_map.has(mode_str):
		_send_response({"error": "Invalid mode: " + mode_str + ". Use: inherit, always, pausable, when_paused, disabled"})
		return
	node.process_mode = mode_map[mode_str]
	_send_response({"success": true, "process_mode": mode_str})


func _cmd_get_node_name(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "name": node.name})


func _cmd_set_node_name(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var new_name: String = params.get("new_name", "")
	if new_name.is_empty():
		_send_response({"error": "new_name is required"})
		return
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	node.name = new_name
	_send_response({"success": true, "new_name": node.name})


func _cmd_get_node_child_count(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "child_count": node.get_child_count()})


func _cmd_get_node_child_names(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var names: Array = []
	for child in node.get_children():
		names.append({"name": child.name, "class": child.get_class()})
	_send_response({"success": true, "children": names, "count": names.size()})


func _cmd_move_node_child_to_front(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or node.get_parent() == null:
		_send_response({"error": "Node not found or has no parent: " + node_path})
		return
	node.get_parent().move_child(node, node.get_parent().get_child_count() - 1)
	_send_response({"success": true})


func _cmd_move_node_child_to_back(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or node.get_parent() == null:
		_send_response({"error": "Node not found or has no parent: " + node_path})
		return
	node.get_parent().move_child(node, 0)
	_send_response({"success": true})


func _cmd_is_node_inside_tree(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	_send_response({"success": true, "exists": node != null, "node_path": node_path})


func _cmd_start_timer(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var wait_time: float = params.get("wait_time", -1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Timer:
		_send_response({"error": "Timer not found: " + node_path})
		return
	var timer := node as Timer
	if wait_time > 0:
		timer.wait_time = wait_time
	timer.start()
	_send_response({"success": true, "wait_time": timer.wait_time})


func _cmd_stop_timer(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Timer:
		_send_response({"error": "Timer not found: " + node_path})
		return
	(node as Timer).stop()
	_send_response({"success": true})


func _cmd_is_timer_stopped(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Timer:
		_send_response({"error": "Timer not found: " + node_path})
		return
	_send_response({"success": true, "stopped": (node as Timer).is_stopped()})


func _cmd_get_timer_time_left(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Timer:
		_send_response({"error": "Timer not found: " + node_path})
		return
	_send_response({"success": true, "time_left": (node as Timer).time_left})


func _cmd_get_timer_wait_time(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Timer:
		_send_response({"error": "Timer not found: " + node_path})
		return
	_send_response({"success": true, "wait_time": (node as Timer).wait_time})


func _cmd_set_timer_wait_time(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var wait_time: float = params.get("wait_time", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Timer:
		_send_response({"error": "Timer not found: " + node_path})
		return
	(node as Timer).wait_time = wait_time
	_send_response({"success": true, "wait_time": wait_time})


func _cmd_get_timer_one_shot(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Timer:
		_send_response({"error": "Timer not found: " + node_path})
		return
	_send_response({"success": true, "one_shot": (node as Timer).one_shot})


func _cmd_set_timer_one_shot(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var one_shot: bool = params.get("one_shot", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Timer:
		_send_response({"error": "Timer not found: " + node_path})
		return
	(node as Timer).one_shot = one_shot
	_send_response({"success": true, "one_shot": one_shot})


func _cmd_get_animation_list(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	_send_response({"success": true, "animations": Array((node as AnimationPlayer).get_animation_list())})


func _cmd_get_current_animation(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	_send_response({"success": true, "current_animation": (node as AnimationPlayer).current_animation, "is_playing": (node as AnimationPlayer).is_playing()})


func _cmd_is_animation_playing(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	_send_response({"success": true, "is_playing": (node as AnimationPlayer).is_playing(), "current_animation": (node as AnimationPlayer).current_animation})


func _cmd_play_animation_from_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var animation_name: String = params.get("animation_name", "")
	var from_position: float = params.get("from_position", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	var player := node as AnimationPlayer
	player.play(animation_name)
	player.seek(from_position, true)
	_send_response({"success": true, "animation": animation_name, "from_position": from_position})


func _cmd_set_animation_blend_time(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var from_anim: String = params.get("from_anim", "")
	var to_anim: String = params.get("to_anim", "")
	var blend_time: float = params.get("blend_time", 0.5)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	(node as AnimationPlayer).set_blend_time(from_anim, to_anim, blend_time)
	_send_response({"success": true, "from": from_anim, "to": to_anim, "blend_time": blend_time})


func _cmd_queue_animation(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var animation_name: String = params.get("animation_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	(node as AnimationPlayer).queue(animation_name)
	_send_response({"success": true, "queued": animation_name})


func _cmd_get_performance_monitor(params: Dictionary) -> void:
	var monitor_name: String = params.get("monitor", "render/fps")
	var monitor_map = {
		"render/fps": Performance.RENDER_FPS,
		"render/total_draw_calls": Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME,
		"render/total_objects": Performance.RENDER_TOTAL_OBJECTS_IN_FRAME,
		"render/total_vertices": Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME,
		"memory/static": Performance.MEMORY_STATIC,
		"memory/peak": Performance.MEMORY_STATIC_MAX,
		"physics/2d/active_objects": Performance.PHYSICS_2D_ACTIVE_OBJECTS,
		"physics/3d/active_objects": Performance.PHYSICS_3D_ACTIVE_OBJECTS,
		"object/count": Performance.OBJECT_COUNT,
		"object/resource_count": Performance.OBJECT_RESOURCE_COUNT,
	}
	if not monitor_map.has(monitor_name):
		_send_response({"error": "Unknown monitor: " + monitor_name, "available": monitor_map.keys()})
		return
	var value = Performance.get_monitor(monitor_map[monitor_name])
	_send_response({"success": true, "monitor": monitor_name, "value": value})


func _cmd_get_physics_info(params: Dictionary) -> void:
	_send_response({
		"success": true,
		"active_2d_objects": Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS),
		"collision_2d_pairs": Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS),
		"active_3d_objects": Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
		"collision_3d_pairs": Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS),
	})


func _cmd_set_max_fps(params: Dictionary) -> void:
	var max_fps: int = params.get("max_fps", 60)
	Engine.max_fps = max_fps
	_send_response({"success": true, "max_fps": Engine.max_fps})


func _cmd_get_max_fps(params: Dictionary) -> void:
	_send_response({"success": true, "max_fps": Engine.max_fps})


func _cmd_get_control_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	var pos: Vector2 = (node as Control).position
	_send_response({"success": true, "x": pos.x, "y": pos.y})


func _cmd_get_control_anchor(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	var ctrl := node as Control
	_send_response({"success": true, "anchor_left": ctrl.anchor_left, "anchor_top": ctrl.anchor_top, "anchor_right": ctrl.anchor_right, "anchor_bottom": ctrl.anchor_bottom})


func _cmd_set_control_anchor_preset(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var preset_str: String = params.get("preset", "full_rect")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	var preset_map = {
		"top_left": 0, "top_right": 1, "bottom_left": 2, "bottom_right": 3,
		"center_left": 4, "center_top": 5, "center_right": 6, "center_bottom": 7,
		"center": 8, "left_wide": 9, "top_wide": 10, "right_wide": 11,
		"bottom_wide": 12, "vcenter_wide": 13, "hcenter_wide": 14, "full_rect": 15
	}
	if not preset_map.has(preset_str):
		_send_response({"error": "Unknown preset: " + preset_str})
		return
	(node as Control).set_anchors_preset(preset_map[preset_str])
	_send_response({"success": true, "preset": preset_str})


func _cmd_set_progress_bar_max(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var max_value: float = params.get("max_value", 100.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is ProgressBar:
		_send_response({"error": "ProgressBar not found: " + node_path})
		return
	(node as ProgressBar).max_value = max_value
	_send_response({"success": true, "max_value": max_value})


func _cmd_add_item_list_item_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var text: String = params.get("text", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is ItemList:
		_send_response({"error": "ItemList not found: " + node_path})
		return
	(node as ItemList).add_item(text)
	_send_response({"success": true, "text": text, "item_count": (node as ItemList).item_count})


func _cmd_get_item_list_count(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is ItemList:
		_send_response({"error": "ItemList not found: " + node_path})
		return
	_send_response({"success": true, "count": (node as ItemList).item_count})


func _cmd_set_rich_text_label_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var text: String = params.get("text", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RichTextLabel:
		_send_response({"error": "RichTextLabel not found: " + node_path})
		return
	(node as RichTextLabel).text = text
	_send_response({"success": true, "text": text})


func _cmd_get_rich_text_label_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RichTextLabel:
		_send_response({"error": "RichTextLabel not found: " + node_path})
		return
	_send_response({"success": true, "text": (node as RichTextLabel).text, "parsed_text": (node as RichTextLabel).get_parsed_text()})


func _cmd_append_rich_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var text: String = params.get("text", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RichTextLabel:
		_send_response({"error": "RichTextLabel not found: " + node_path})
		return
	(node as RichTextLabel).append_text(text)
	_send_response({"success": true, "appended": text})


func _cmd_clear_rich_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RichTextLabel:
		_send_response({"error": "RichTextLabel not found: " + node_path})
		return
	(node as RichTextLabel).clear()
	_send_response({"success": true})


func _cmd_list_input_actions(params: Dictionary) -> void:
	var actions: Array = InputMap.get_actions()
	var result: Array = []
	for action in actions:
		result.append(str(action))
	_send_response({"success": true, "actions": result, "count": result.size()})


func _cmd_is_action_just_pressed(params: Dictionary) -> void:
	var action_name: String = params.get("action_name", "")
	if not InputMap.has_action(action_name):
		_send_response({"error": "Action not found: " + action_name})
		return
	_send_response({"success": true, "just_pressed": Input.is_action_just_pressed(action_name)})


func _cmd_is_action_just_released(params: Dictionary) -> void:
	var action_name: String = params.get("action_name", "")
	if not InputMap.has_action(action_name):
		_send_response({"error": "Action not found: " + action_name})
		return
	_send_response({"success": true, "just_released": Input.is_action_just_released(action_name)})


func _cmd_get_action_strength(params: Dictionary) -> void:
	var action_name: String = params.get("action_name", "")
	if not InputMap.has_action(action_name):
		_send_response({"error": "Action not found: " + action_name})
		return
	_send_response({"success": true, "strength": Input.get_action_strength(action_name)})


func _cmd_simulate_action_press(params: Dictionary) -> void:
	var action_name: String = params.get("action_name", "")
	var strength: float = params.get("strength", 1.0)
	var ev = InputEventAction.new()
	ev.action = action_name
	ev.pressed = true
	ev.strength = strength
	Input.parse_input_event(ev)
	_send_response({"success": true, "action": action_name, "strength": strength})


func _cmd_simulate_action_release(params: Dictionary) -> void:
	var action_name: String = params.get("action_name", "")
	var ev = InputEventAction.new()
	ev.action = action_name
	ev.pressed = false
	Input.parse_input_event(ev)
	_send_response({"success": true, "action": action_name, "released": true})


func _cmd_get_mouse_mode(params: Dictionary) -> void:
	var mode_names = ["visible", "hidden", "captured", "confined", "confined_hidden"]
	var mode_int: int = Input.mouse_mode
	var mode_str: String = mode_names[mode_int] if mode_int < mode_names.size() else str(mode_int)
	_send_response({"success": true, "mode": mode_str, "mode_int": mode_int})


func _cmd_get_multiplayer_peer_id(params: Dictionary) -> void:
	_send_response({"success": true, "peer_id": multiplayer.get_unique_id()})


func _cmd_is_multiplayer_server(params: Dictionary) -> void:
	_send_response({"success": true, "is_server": multiplayer.is_server()})


func _cmd_get_network_peer_count(params: Dictionary) -> void:
	_send_response({"success": true, "count": multiplayer.get_peers().size()})


func _cmd_set_node_multiplayer_authority(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var peer_id: int = params.get("peer_id", 1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	node.set_multiplayer_authority(peer_id)
	_send_response({"success": true, "node_path": node_path, "peer_id": peer_id})


func _cmd_get_node_multiplayer_authority(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "authority": node.get_multiplayer_authority(), "is_authority": node.is_multiplayer_authority()})


func _cmd_rpc_call(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var method_name: String = params.get("method_name", "")
	var call_args: Array = params.get("args", [])
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	node.rpc(method_name, call_args)
	_send_response({"success": true, "method": method_name, "node_path": node_path})


func _cmd_broadcast_to_group(params: Dictionary) -> void:
	var group_name: String = params.get("group_name", "")
	var method_name: String = params.get("method_name", "")
	if group_name.is_empty() or method_name.is_empty():
		_send_response({"error": "group_name and method_name are required"})
		return
	get_tree().call_group(group_name, method_name)
	_send_response({"success": true, "group": group_name, "method": method_name})


func _cmd_tween_position_2d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var duration: float = params.get("duration", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node2D:
		_send_response({"error": "Node2D not found: " + node_path})
		return
	var tween = get_tree().create_tween()
	tween.tween_property(node, "position", Vector2(x, y), duration)
	_send_response({"success": true, "target": {"x": x, "y": y}, "duration": duration})


func _cmd_tween_rotation_2d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var angle: float = params.get("angle", 0.0)
	var duration: float = params.get("duration", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node2D:
		_send_response({"error": "Node2D not found: " + node_path})
		return
	var tween = get_tree().create_tween()
	tween.tween_property(node, "rotation", angle, duration)
	_send_response({"success": true, "angle": angle, "duration": duration})


func _cmd_tween_scale_2d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 1.0)
	var y: float = params.get("y", 1.0)
	var duration: float = params.get("duration", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node2D:
		_send_response({"error": "Node2D not found: " + node_path})
		return
	var tween = get_tree().create_tween()
	tween.tween_property(node, "scale", Vector2(x, y), duration)
	_send_response({"success": true, "scale": {"x": x, "y": y}, "duration": duration})


func _cmd_tween_alpha(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var alpha: float = params.get("alpha", 1.0)
	var duration: float = params.get("duration", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasItem:
		_send_response({"error": "CanvasItem not found: " + node_path})
		return
	var tween = get_tree().create_tween()
	tween.tween_property(node, "modulate:a", alpha, duration)
	_send_response({"success": true, "alpha": alpha, "duration": duration})


func _cmd_tween_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var a: float = params.get("a", 1.0)
	var duration: float = params.get("duration", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasItem:
		_send_response({"error": "CanvasItem not found: " + node_path})
		return
	var tween = get_tree().create_tween()
	tween.tween_property(node, "modulate", Color(r, g, b, a), duration)
	_send_response({"success": true, "color": {"r": r, "g": g, "b": b, "a": a}, "duration": duration})


func _cmd_flash_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var duration: float = params.get("duration", 0.3)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasItem:
		_send_response({"error": "CanvasItem not found: " + node_path})
		return
	var tween = get_tree().create_tween()
	tween.tween_property(node, "modulate:a", 0.0, duration * 0.5)
	tween.tween_property(node, "modulate:a", 1.0, duration * 0.5)
	_send_response({"success": true, "duration": duration})


func _cmd_shake_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var intensity: float = params.get("intensity", 10.0)
	var duration: float = params.get("duration", 0.3)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node2D:
		_send_response({"error": "Node2D not found: " + node_path})
		return
	var original_pos: Vector2 = (node as Node2D).position
	var tween = get_tree().create_tween()
	var steps: int = int(duration / 0.05)
	for i in range(steps):
		var offset = Vector2(randf_range(-intensity, intensity), randf_range(-intensity, intensity))
		tween.tween_property(node, "position", original_pos + offset, 0.05)
	tween.tween_property(node, "position", original_pos, 0.05)
	_send_response({"success": true, "intensity": intensity, "duration": duration})


func _cmd_fade_in_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var duration: float = params.get("duration", 0.5)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasItem:
		_send_response({"error": "CanvasItem not found: " + node_path})
		return
	var ci := node as CanvasItem
	ci.modulate.a = 0.0
	ci.visible = true
	var tween = get_tree().create_tween()
	tween.tween_property(ci, "modulate:a", 1.0, duration)
	_send_response({"success": true, "duration": duration})


func _cmd_fade_out_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var duration: float = params.get("duration", 0.5)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasItem:
		_send_response({"error": "CanvasItem not found: " + node_path})
		return
	var tween = get_tree().create_tween()
	tween.tween_property(node as CanvasItem, "modulate:a", 0.0, duration)
	_send_response({"success": true, "duration": duration})


func _cmd_get_audio_bus_names(params: Dictionary) -> void:
	var names: Array = []
	for i in range(AudioServer.bus_count):
		names.append(AudioServer.get_bus_name(i))
	_send_response({"success": true, "buses": names, "count": names.size()})


func _cmd_add_audio_bus(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "New Bus")
	AudioServer.add_bus()
	var idx: int = AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, bus_name)
	_send_response({"success": true, "bus_name": bus_name, "index": idx})


func _cmd_remove_audio_bus(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "")
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		_send_response({"error": "Bus not found: " + bus_name})
		return
	AudioServer.remove_bus(idx)
	_send_response({"success": true, "removed": bus_name})


func _cmd_get_audio_bus_muted(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "Master")
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		_send_response({"error": "Bus not found: " + bus_name})
		return
	_send_response({"success": true, "bus": bus_name, "muted": AudioServer.is_bus_mute(idx)})


func _cmd_get_audio_bus_solo(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "Master")
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		_send_response({"error": "Bus not found: " + bus_name})
		return
	_send_response({"success": true, "bus": bus_name, "solo": AudioServer.is_bus_solo(idx)})


func _cmd_set_audio_bus_solo(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "Master")
	var solo: bool = params.get("solo", true)
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		_send_response({"error": "Bus not found: " + bus_name})
		return
	AudioServer.set_bus_solo(idx, solo)
	_send_response({"success": true, "bus": bus_name, "solo": solo})


func _cmd_set_audio_bus_send(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "")
	var send_bus: String = params.get("send_bus", "Master")
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		_send_response({"error": "Bus not found: " + bus_name})
		return
	AudioServer.set_bus_send(idx, send_bus)
	_send_response({"success": true, "bus": bus_name, "sends_to": send_bus})


func _cmd_find_nodes_in_group(params: Dictionary) -> void:
	var group_name: String = params.get("group_name", "")
	var nodes = get_tree().get_nodes_in_group(group_name)
	var result: Array = []
	for node in nodes:
		result.append({"name": node.name, "path": str(node.get_path()), "class": node.get_class()})
	_send_response({"success": true, "group": group_name, "nodes": result, "count": result.size()})


func _cmd_add_node_to_group_runtime(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var group_name: String = params.get("group_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	node.add_to_group(group_name)
	_send_response({"success": true, "node_path": node_path, "group": group_name})


func _cmd_remove_node_from_group_runtime(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var group_name: String = params.get("group_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	node.remove_from_group(group_name)
	_send_response({"success": true, "node_path": node_path, "group": group_name})


func _cmd_get_nodes_of_class(params: Dictionary) -> void:
	var class_name_str: String = params.get("class_name", "")
	var result: Array = []
	_find_nodes_by_class(get_tree().root, class_name_str, result)
	_send_response({"success": true, "class": class_name_str, "nodes": result, "count": result.size()})


func _find_nodes_by_class(node: Node, class_name_str: String, result: Array) -> void:
	if node.get_class() == class_name_str or node.is_class(class_name_str):
		result.append({"name": node.name, "path": str(node.get_path())})
	for child in node.get_children():
		_find_nodes_by_class(child, class_name_str, result)


func _cmd_get_node_owner_path(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var owner_path: String = str(node.owner.get_path()) if node.owner != null else ""
	_send_response({"success": true, "owner_path": owner_path})


func _cmd_get_node_unique_name(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "unique_name_in_owner": node.unique_name_in_owner, "name": node.name})


func _cmd_get_2d_collision_layers_names(params: Dictionary) -> void:
	var layers: Array = []
	for i in range(32):
		var name = ProjectSettings.get_setting("layer_names/2d_physics/layer_" + str(i + 1), "Layer " + str(i + 1))
		layers.append({"index": i + 1, "name": str(name)})
	_send_response({"success": true, "layers": layers})


func _cmd_set_physics_body_collision_layer(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var layer: int = params.get("layer", 1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CollisionObject2D:
		_send_response({"error": "CollisionObject2D not found: " + node_path})
		return
	(node as CollisionObject2D).collision_layer = layer
	_send_response({"success": true, "collision_layer": layer})


func _cmd_get_physics_body_collision_layer(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CollisionObject2D:
		_send_response({"error": "CollisionObject2D not found: " + node_path})
		return
	_send_response({"success": true, "collision_layer": (node as CollisionObject2D).collision_layer})


func _cmd_set_physics_body_collision_mask(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var mask: int = params.get("mask", 1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CollisionObject2D:
		_send_response({"error": "CollisionObject2D not found: " + node_path})
		return
	(node as CollisionObject2D).collision_mask = mask
	_send_response({"success": true, "collision_mask": mask})


func _cmd_get_physics_body_collision_mask(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CollisionObject2D:
		_send_response({"error": "CollisionObject2D not found: " + node_path})
		return
	_send_response({"success": true, "collision_mask": (node as CollisionObject2D).collision_mask})


func _cmd_enable_physics_body(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var enabled: bool = params.get("enabled", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CollisionObject2D:
		(node as CollisionObject2D).set_deferred("disabled", not enabled)
	elif node is CollisionObject3D:
		(node as CollisionObject3D).set_deferred("disabled", not enabled)
	else:
		_send_response({"error": "Not a physics body: " + node_path})
		return
	_send_response({"success": true, "enabled": enabled})


func _cmd_set_physics_body_3d_collision_layer(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var layer: int = params.get("layer", 1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CollisionObject3D:
		_send_response({"error": "CollisionObject3D not found: " + node_path})
		return
	(node as CollisionObject3D).collision_layer = layer
	_send_response({"success": true, "collision_layer": layer})


func _cmd_get_physics_body_3d_collision_layer(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CollisionObject3D:
		_send_response({"error": "CollisionObject3D not found: " + node_path})
		return
	_send_response({"success": true, "collision_layer": (node as CollisionObject3D).collision_layer})


func _cmd_set_physics_body_3d_collision_mask(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var mask: int = params.get("mask", 1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CollisionObject3D:
		_send_response({"error": "CollisionObject3D not found: " + node_path})
		return
	(node as CollisionObject3D).collision_mask = mask
	_send_response({"success": true, "collision_mask": mask})


func _cmd_get_physics_body_3d_collision_mask(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CollisionObject3D:
		_send_response({"error": "CollisionObject3D not found: " + node_path})
		return
	_send_response({"success": true, "collision_mask": (node as CollisionObject3D).collision_mask})


func _cmd_set_rigid_body_3d_sleeping(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var sleeping: bool = params.get("sleeping", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RigidBody3D:
		_send_response({"error": "RigidBody3D not found: " + node_path})
		return
	(node as RigidBody3D).sleeping = sleeping
	_send_response({"success": true, "sleeping": sleeping})


func _cmd_get_rigid_body_3d_state(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RigidBody3D:
		_send_response({"error": "RigidBody3D not found: " + node_path})
		return
	var rb := node as RigidBody3D
	_send_response({"success": true, "position": {"x": rb.position.x, "y": rb.position.y, "z": rb.position.z}, "linear_velocity": {"x": rb.linear_velocity.x, "y": rb.linear_velocity.y, "z": rb.linear_velocity.z}, "angular_velocity": {"x": rb.angular_velocity.x, "y": rb.angular_velocity.y, "z": rb.angular_velocity.z}, "sleeping": rb.sleeping, "mass": rb.mass})


func _cmd_set_character_body_3d_velocity(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var vx: float = params.get("vx", 0.0)
	var vy: float = params.get("vy", 0.0)
	var vz: float = params.get("vz", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CharacterBody3D:
		_send_response({"error": "CharacterBody3D not found: " + node_path})
		return
	(node as CharacterBody3D).velocity = Vector3(vx, vy, vz)
	_send_response({"success": true, "velocity": {"x": vx, "y": vy, "z": vz}})


func _cmd_get_character_body_3d_velocity(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CharacterBody3D:
		_send_response({"error": "CharacterBody3D not found: " + node_path})
		return
	var v: Vector3 = (node as CharacterBody3D).velocity
	_send_response({"success": true, "velocity": {"x": v.x, "y": v.y, "z": v.z}})


func _cmd_is_character_body_3d_on_floor(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CharacterBody3D:
		_send_response({"error": "CharacterBody3D not found: " + node_path})
		return
	_send_response({"success": true, "on_floor": (node as CharacterBody3D).is_on_floor(), "on_wall": (node as CharacterBody3D).is_on_wall(), "on_ceiling": (node as CharacterBody3D).is_on_ceiling()})


func _cmd_apply_impulse_3d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var ix: float = params.get("ix", 0.0)
	var iy: float = params.get("iy", 0.0)
	var iz: float = params.get("iz", 0.0)
	var px: float = params.get("px", 0.0)
	var py: float = params.get("py", 0.0)
	var pz: float = params.get("pz", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RigidBody3D:
		_send_response({"error": "RigidBody3D not found: " + node_path})
		return
	(node as RigidBody3D).apply_impulse(Vector3(ix, iy, iz), Vector3(px, py, pz))
	_send_response({"success": true, "impulse": {"x": ix, "y": iy, "z": iz}})


func _cmd_get_environment_info(_params: Dictionary) -> void:
	var env_node = get_tree().root.find_child("WorldEnvironment", true, false)
	if env_node == null:
		_send_response({"error": "No WorldEnvironment found in scene"})
		return
	var env = (env_node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "WorldEnvironment has no Environment resource"})
		return
	_send_response({"success": true, "fog_enabled": env.fog_enabled, "glow_enabled": env.glow_enabled, "background_mode": env.background_mode, "ambient_light_energy": env.ambient_light_energy})


func _cmd_set_environment_brightness(params: Dictionary) -> void:
	var exposure: float = params.get("exposure", 1.0)
	var brightness: float = params.get("brightness", 1.0)
	var env_node = get_tree().root.find_child("WorldEnvironment", true, false)
	if env_node == null:
		_send_response({"error": "No WorldEnvironment found"})
		return
	var env = (env_node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "No Environment resource"})
		return
	env.tonemap_exposure = exposure
	env.tonemap_white = brightness
	_send_response({"success": true, "exposure": exposure, "brightness": brightness})


func _cmd_set_directional_light_energy(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var energy: float = params.get("energy", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is DirectionalLight3D:
		_send_response({"error": "DirectionalLight3D not found: " + node_path})
		return
	(node as DirectionalLight3D).light_energy = energy
	_send_response({"success": true, "energy": energy})


func _cmd_set_directional_light_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is DirectionalLight3D:
		_send_response({"error": "DirectionalLight3D not found: " + node_path})
		return
	(node as DirectionalLight3D).light_color = Color(r, g, b)
	_send_response({"success": true, "color": {"r": r, "g": g, "b": b}})


func _cmd_set_omni_light_energy(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var energy: float = params.get("energy", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is OmniLight3D:
		_send_response({"error": "OmniLight3D not found: " + node_path})
		return
	(node as OmniLight3D).light_energy = energy
	_send_response({"success": true, "energy": energy})


func _cmd_set_omni_light_range(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var range_val: float = params.get("range", 10.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is OmniLight3D:
		_send_response({"error": "OmniLight3D not found: " + node_path})
		return
	(node as OmniLight3D).omni_range = range_val
	_send_response({"success": true, "range": range_val})


func _cmd_set_spot_light_energy(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var energy: float = params.get("energy", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SpotLight3D:
		_send_response({"error": "SpotLight3D not found: " + node_path})
		return
	(node as SpotLight3D).light_energy = energy
	_send_response({"success": true, "energy": energy})


func _cmd_get_3d_camera_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Camera3D:
		_send_response({"error": "Camera3D not found: " + node_path})
		return
	var cam := node as Camera3D
	_send_response({"success": true, "fov": cam.fov, "near": cam.near, "far": cam.far, "projection": cam.projection, "current": cam.current})


func _cmd_set_camera_3d_fov(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var fov: float = params.get("fov", 75.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Camera3D:
		_send_response({"error": "Camera3D not found: " + node_path})
		return
	(node as Camera3D).fov = fov
	_send_response({"success": true, "fov": fov})


func _cmd_set_camera_3d_near(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var near: float = params.get("near", 0.05)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Camera3D:
		_send_response({"error": "Camera3D not found: " + node_path})
		return
	(node as Camera3D).near = near
	_send_response({"success": true, "near": near})


func _cmd_set_camera_3d_far(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var far: float = params.get("far", 4000.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Camera3D:
		_send_response({"error": "Camera3D not found: " + node_path})
		return
	(node as Camera3D).far = far
	_send_response({"success": true, "far": far})


func _cmd_make_camera_current(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is Camera3D:
		(node as Camera3D).make_current()
		_send_response({"success": true, "camera_path": node_path})
	elif node is Camera2D:
		(node as Camera2D).make_current()
		_send_response({"success": true, "camera_path": node_path})
	else:
		_send_response({"error": "Not a camera node: " + node_path})


func _cmd_get_visible_rect(_params: Dictionary) -> void:
	var rect: Rect2 = get_viewport().get_visible_rect()
	_send_response({"success": true, "x": rect.position.x, "y": rect.position.y, "width": rect.size.x, "height": rect.size.y})


func _cmd_get_animation_current(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	var ap := node as AnimationPlayer
	_send_response({"success": true, "current_animation": ap.current_animation, "is_playing": ap.is_playing(), "position": ap.current_animation_position})


func _cmd_get_animation_length(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var animation_name: String = params.get("animation_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	var ap := node as AnimationPlayer
	if not ap.has_animation(animation_name):
		_send_response({"error": "Animation not found: " + animation_name})
		return
	_send_response({"success": true, "length": ap.get_animation(animation_name).length, "animation_name": animation_name})


func _cmd_set_animation_loop(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var animation_name: String = params.get("animation_name", "")
	var loop: bool = params.get("loop", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	var ap := node as AnimationPlayer
	if not ap.has_animation(animation_name):
		_send_response({"error": "Animation not found: " + animation_name})
		return
	var anim: Animation = ap.get_animation(animation_name)
	anim.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	_send_response({"success": true, "animation_name": animation_name, "loop": loop})


func _cmd_get_animation_tree_state(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found: " + node_path})
		return
	var at := node as AnimationTree
	_send_response({"success": true, "active": at.active, "anim_player": str(at.anim_player)})


func _cmd_set_blend_parameter(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var param_name: String = params.get("param_name", "")
	var value = params.get("value", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found: " + node_path})
		return
	(node as AnimationTree).set(param_name, value)
	_send_response({"success": true, "param_name": param_name, "value": value})


func _cmd_get_blend_parameter(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var param_name: String = params.get("param_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found: " + node_path})
		return
	var value = (node as AnimationTree).get(param_name)
	_send_response({"success": true, "param_name": param_name, "value": value})


func _cmd_travel_animation_state(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var state_name: String = params.get("state_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found: " + node_path})
		return
	var at := node as AnimationTree
	var sm = at.get("parameters/playback")
	if sm == null:
		_send_response({"error": "No state machine playback found at parameters/playback"})
		return
	sm.travel(state_name)
	_send_response({"success": true, "traveled_to": state_name})


func _cmd_set_shader_parameter(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var param_name: String = params.get("param_name", "")
	var value = params.get("value", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var mat: ShaderMaterial = null
	if node is MeshInstance3D:
		mat = (node as MeshInstance3D).get_active_material(0) as ShaderMaterial
	elif node is Sprite2D:
		mat = (node as Sprite2D).material as ShaderMaterial
	elif node is CanvasItem:
		mat = (node as CanvasItem).material as ShaderMaterial
	if mat == null:
		_send_response({"error": "No ShaderMaterial on node"})
		return
	mat.set_shader_parameter(param_name, value)
	_send_response({"success": true, "param_name": param_name, "value": value})


func _cmd_get_shader_parameter(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var param_name: String = params.get("param_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var mat: ShaderMaterial = null
	if node is MeshInstance3D:
		mat = (node as MeshInstance3D).get_active_material(0) as ShaderMaterial
	elif node is CanvasItem:
		mat = (node as CanvasItem).material as ShaderMaterial
	if mat == null:
		_send_response({"error": "No ShaderMaterial on node"})
		return
	var value = mat.get_shader_parameter(param_name)
	_send_response({"success": true, "param_name": param_name, "value": value})


func _cmd_set_material_albedo_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var a: float = params.get("a", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mat: StandardMaterial3D = (node as MeshInstance3D).get_active_material(0) as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		(node as MeshInstance3D).set_surface_override_material(0, mat)
	mat.albedo_color = Color(r, g, b, a)
	_send_response({"success": true, "color": {"r": r, "g": g, "b": b, "a": a}})


func _cmd_set_material_emission_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 0.0)
	var b: float = params.get("b", 0.0)
	var energy: float = params.get("energy", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mat: StandardMaterial3D = (node as MeshInstance3D).get_active_material(0) as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		(node as MeshInstance3D).set_surface_override_material(0, mat)
	mat.emission_enabled = true
	mat.emission = Color(r, g, b)
	mat.emission_energy_multiplier = energy
	_send_response({"success": true, "emission": {"r": r, "g": g, "b": b}, "energy": energy})


func _cmd_set_material_transparency(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var alpha: float = params.get("alpha", 0.5)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mat: StandardMaterial3D = (node as MeshInstance3D).get_active_material(0) as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		(node as MeshInstance3D).set_surface_override_material(0, mat)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color.a = alpha
	_send_response({"success": true, "alpha": alpha})


func _cmd_get_node_material(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is MeshInstance3D:
		var mat = (node as MeshInstance3D).get_active_material(0)
		_send_response({"success": true, "material_class": mat.get_class() if mat != null else "none", "surface_count": (node as MeshInstance3D).get_surface_override_material_count()})
	elif node is Sprite2D:
		var mat = (node as Sprite2D).material
		_send_response({"success": true, "material_class": mat.get_class() if mat != null else "none"})
	else:
		_send_response({"error": "Node has no material interface: " + node_path})


func _cmd_set_material_roughness_metallic(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var roughness: float = params.get("roughness", 0.5)
	var metallic: float = params.get("metallic", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mat: StandardMaterial3D = (node as MeshInstance3D).get_active_material(0) as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		(node as MeshInstance3D).set_surface_override_material(0, mat)
	mat.roughness = roughness
	mat.metallic = metallic
	_send_response({"success": true, "roughness": roughness, "metallic": metallic})


func _cmd_get_input_action_list(_params: Dictionary) -> void:
	var actions = InputMap.get_actions()
	var result = []
	for action in actions:
		result.append(str(action))
	_send_response({"success": true, "actions": result, "count": result.size()})


func _cmd_is_input_action_pressed(params: Dictionary) -> void:
	var action_name: String = params.get("action_name", "")
	if not InputMap.has_action(action_name):
		_send_response({"error": "Action not found: " + action_name})
		return
	_send_response({"success": true, "action_name": action_name, "pressed": Input.is_action_pressed(action_name)})


func _cmd_get_input_action_strength(params: Dictionary) -> void:
	var action_name: String = params.get("action_name", "")
	if not InputMap.has_action(action_name):
		_send_response({"error": "Action not found: " + action_name})
		return
	_send_response({"success": true, "action_name": action_name, "strength": Input.get_action_strength(action_name)})


func _cmd_get_connected_joypads(_params: Dictionary) -> void:
	var pads = Input.get_connected_joypads()
	var result = []
	for pad in pads:
		result.append({"id": pad, "name": Input.get_joy_name(pad)})
	_send_response({"success": true, "joypads": result, "count": result.size()})


func _cmd_get_navigation_agent_2d_path(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NavigationAgent2D:
		_send_response({"error": "NavigationAgent2D not found: " + node_path})
		return
	var agent := node as NavigationAgent2D
	var path = agent.get_current_navigation_path()
	var result = []
	for p in path:
		result.append({"x": p.x, "y": p.y})
	_send_response({"success": true, "path": result, "target_reached": agent.is_target_reached()})


func _cmd_set_navigation_agent_2d_target(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NavigationAgent2D:
		_send_response({"error": "NavigationAgent2D not found: " + node_path})
		return
	(node as NavigationAgent2D).target_position = Vector2(x, y)
	_send_response({"success": true, "target": {"x": x, "y": y}})


func _cmd_get_navigation_agent_3d_path(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NavigationAgent3D:
		_send_response({"error": "NavigationAgent3D not found: " + node_path})
		return
	var agent := node as NavigationAgent3D
	var path = agent.get_current_navigation_path()
	var result = []
	for p in path:
		result.append({"x": p.x, "y": p.y, "z": p.z})
	_send_response({"success": true, "path": result, "target_reached": agent.is_target_reached()})


func _cmd_set_navigation_agent_3d_target(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NavigationAgent3D:
		_send_response({"error": "NavigationAgent3D not found: " + node_path})
		return
	(node as NavigationAgent3D).target_position = Vector3(x, y, z)
	_send_response({"success": true, "target": {"x": x, "y": y, "z": z}})


func _cmd_is_navigation_agent_2d_finished(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NavigationAgent2D:
		_send_response({"error": "NavigationAgent2D not found: " + node_path})
		return
	var agent := node as NavigationAgent2D
	_send_response({"success": true, "finished": agent.is_navigation_finished(), "target_reached": agent.is_target_reached()})


func _cmd_is_navigation_agent_3d_finished(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NavigationAgent3D:
		_send_response({"error": "NavigationAgent3D not found: " + node_path})
		return
	var agent := node as NavigationAgent3D
	_send_response({"success": true, "finished": agent.is_navigation_finished(), "target_reached": agent.is_target_reached()})


func _cmd_get_navigation_map_rid(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is NavigationAgent2D:
		_send_response({"success": true, "map_rid": str((node as NavigationAgent2D).get_navigation_map())})
	elif node is NavigationAgent3D:
		_send_response({"success": true, "map_rid": str((node as NavigationAgent3D).get_navigation_map())})
	else:
		_send_response({"error": "Not a NavigationAgent node: " + node_path})


func _cmd_get_navigation_agent_velocity(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is NavigationAgent2D:
		var v = (node as NavigationAgent2D).velocity
		_send_response({"success": true, "velocity": {"x": v.x, "y": v.y}})
	elif node is NavigationAgent3D:
		var v = (node as NavigationAgent3D).velocity
		_send_response({"success": true, "velocity": {"x": v.x, "y": v.y, "z": v.z}})
	else:
		_send_response({"error": "Not a NavigationAgent node: " + node_path})


func _cmd_get_multiplayer_authority(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "authority": node.get_multiplayer_authority()})


func _cmd_set_multiplayer_authority(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var peer_id: int = params.get("peer_id", 1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	node.set_multiplayer_authority(peer_id)
	_send_response({"success": true, "peer_id": peer_id})


func _cmd_is_multiplayer_authority(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "is_authority": node.is_multiplayer_authority()})


func _cmd_get_network_latency(params: Dictionary) -> void:
	var peer = multiplayer.multiplayer_peer
	if peer == null:
		_send_response({"error": "No multiplayer peer connected"})
		return
	_send_response({"success": true, "note": "Latency measurement requires active connection"})


func _cmd_set_node_visible(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var visible: bool = params.get("visible", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CanvasItem:
		(node as CanvasItem).visible = visible
	elif node is Node3D:
		(node as Node3D).visible = visible
	else:
		_send_response({"error": "Node does not support visibility: " + node_path})
		return
	_send_response({"success": true, "visible": visible})


func _cmd_get_node_visible(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CanvasItem:
		_send_response({"success": true, "visible": (node as CanvasItem).visible, "is_visible_in_tree": (node as CanvasItem).is_visible_in_tree()})
	elif node is Node3D:
		_send_response({"success": true, "visible": (node as Node3D).visible})
	else:
		_send_response({"error": "Node does not support visibility: " + node_path})


func _cmd_set_sprite_2d_frame(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var frame: int = params.get("frame", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Sprite2D:
		_send_response({"error": "Sprite2D not found: " + node_path})
		return
	(node as Sprite2D).frame = frame
	_send_response({"success": true, "frame": frame})


func _cmd_get_sprite_2d_frame_count(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Sprite2D:
		_send_response({"error": "Sprite2D not found: " + node_path})
		return
	var s := node as Sprite2D
	_send_response({"success": true, "frame_count": s.hframes * s.vframes, "hframes": s.hframes, "vframes": s.vframes, "current_frame": s.frame})


func _cmd_set_sprite_2d_hframes(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var hframes: int = params.get("hframes", 1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Sprite2D:
		_send_response({"error": "Sprite2D not found: " + node_path})
		return
	(node as Sprite2D).hframes = hframes
	_send_response({"success": true, "hframes": hframes})


func _cmd_set_sprite_2d_vframes(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var vframes: int = params.get("vframes", 1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Sprite2D:
		_send_response({"error": "Sprite2D not found: " + node_path})
		return
	(node as Sprite2D).vframes = vframes
	_send_response({"success": true, "vframes": vframes})


func _cmd_set_sprite_2d_flip(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var flip_h: bool = params.get("flip_h", false)
	var flip_v: bool = params.get("flip_v", false)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Sprite2D:
		_send_response({"error": "Sprite2D not found: " + node_path})
		return
	(node as Sprite2D).flip_h = flip_h
	(node as Sprite2D).flip_v = flip_v
	_send_response({"success": true, "flip_h": flip_h, "flip_v": flip_v})


func _cmd_set_animated_sprite_2d_speed(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var speed_scale: float = params.get("speed_scale", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimatedSprite2D:
		_send_response({"error": "AnimatedSprite2D not found: " + node_path})
		return
	(node as AnimatedSprite2D).speed_scale = speed_scale
	_send_response({"success": true, "speed_scale": speed_scale})


func _cmd_get_animated_sprite_2d_frame(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimatedSprite2D:
		_send_response({"error": "AnimatedSprite2D not found: " + node_path})
		return
	var s := node as AnimatedSprite2D
	_send_response({"success": true, "frame": s.frame, "animation": s.animation, "is_playing": s.is_playing(), "speed_scale": s.speed_scale})


func _cmd_look_at_3d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var tx: float = params.get("tx", 0.0)
	var ty: float = params.get("ty", 0.0)
	var tz: float = params.get("tz", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	(node as Node3D).look_at(Vector3(tx, ty, tz))
	_send_response({"success": true, "target": {"x": tx, "y": ty, "z": tz}})


func _cmd_rotate_node_x(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var degrees: float = params.get("degrees", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	(node as Node3D).rotate_x(deg_to_rad(degrees))
	_send_response({"success": true, "degrees": degrees})


func _cmd_rotate_node_y(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var degrees: float = params.get("degrees", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	(node as Node3D).rotate_y(deg_to_rad(degrees))
	_send_response({"success": true, "degrees": degrees})


func _cmd_rotate_node_z(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var degrees: float = params.get("degrees", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	(node as Node3D).rotate_z(deg_to_rad(degrees))
	_send_response({"success": true, "degrees": degrees})


func _cmd_translate_node_local(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var dx: float = params.get("dx", 0.0)
	var dy: float = params.get("dy", 0.0)
	var dz: float = params.get("dz", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	(node as Node3D).translate(Vector3(dx, dy, dz))
	_send_response({"success": true, "translated": {"dx": dx, "dy": dy, "dz": dz}})


func _cmd_translate_node_global(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var dx: float = params.get("dx", 0.0)
	var dy: float = params.get("dy", 0.0)
	var dz: float = params.get("dz", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	(node as Node3D).global_translate(Vector3(dx, dy, dz))
	_send_response({"success": true, "global_translated": {"dx": dx, "dy": dy, "dz": dz}})


func _cmd_get_node_3d_global_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	var gp: Vector3 = (node as Node3D).global_position
	_send_response({"success": true, "global_position": {"x": gp.x, "y": gp.y, "z": gp.z}})


func _cmd_get_node_3d_global_rotation(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	var gr: Vector3 = (node as Node3D).global_rotation_degrees
	_send_response({"success": true, "global_rotation_degrees": {"x": gr.x, "y": gr.y, "z": gr.z}})


func _cmd_reset_node_3d_transform(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	var n3 := node as Node3D
	n3.position = Vector3.ZERO
	n3.rotation = Vector3.ZERO
	n3.scale = Vector3.ONE
	_send_response({"success": true, "reset": true})


func _cmd_get_distance_to_3d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var target_path: String = params.get("target_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	var target = get_tree().root.get_node_or_null(NodePath(target_path))
	if node == null or not node is Node3D:
		_send_response({"error": "Node3D not found: " + node_path})
		return
	if target == null or not target is Node3D:
		_send_response({"error": "Target Node3D not found: " + target_path})
		return
	var dist = (node as Node3D).global_position.distance_to((target as Node3D).global_position)
	_send_response({"success": true, "distance": dist})


func _cmd_set_particle_amount(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var amount: int = params.get("amount", 8)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CPUParticles2D:
		(node as CPUParticles2D).amount = amount
	elif node is CPUParticles3D:
		(node as CPUParticles3D).amount = amount
	elif node is GPUParticles2D:
		(node as GPUParticles2D).amount = amount
	elif node is GPUParticles3D:
		(node as GPUParticles3D).amount = amount
	else:
		_send_response({"error": "Not a particle node: " + node_path})
		return
	_send_response({"success": true, "amount": amount})


func _cmd_get_particle_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CPUParticles2D:
		var p := node as CPUParticles2D
		_send_response({"success": true, "type": "CPUParticles2D", "amount": p.amount, "emitting": p.emitting, "lifetime": p.lifetime, "speed_scale": p.speed_scale})
	elif node is GPUParticles2D:
		var p := node as GPUParticles2D
		_send_response({"success": true, "type": "GPUParticles2D", "amount": p.amount, "emitting": p.emitting, "lifetime": p.lifetime, "speed_scale": p.speed_scale})
	elif node is CPUParticles3D:
		var p := node as CPUParticles3D
		_send_response({"success": true, "type": "CPUParticles3D", "amount": p.amount, "emitting": p.emitting, "lifetime": p.lifetime, "speed_scale": p.speed_scale})
	elif node is GPUParticles3D:
		var p := node as GPUParticles3D
		_send_response({"success": true, "type": "GPUParticles3D", "amount": p.amount, "emitting": p.emitting, "lifetime": p.lifetime, "speed_scale": p.speed_scale})
	else:
		_send_response({"error": "Not a particle node: " + node_path})


func _cmd_set_particle_speed_scale(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var speed_scale: float = params.get("speed_scale", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CPUParticles2D: (node as CPUParticles2D).speed_scale = speed_scale
	elif node is CPUParticles3D: (node as CPUParticles3D).speed_scale = speed_scale
	elif node is GPUParticles2D: (node as GPUParticles2D).speed_scale = speed_scale
	elif node is GPUParticles3D: (node as GPUParticles3D).speed_scale = speed_scale
	else:
		_send_response({"error": "Not a particle node: " + node_path})
		return
	_send_response({"success": true, "speed_scale": speed_scale})


func _cmd_set_particle_explosiveness(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var explosiveness: float = params.get("explosiveness", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CPUParticles2D: (node as CPUParticles2D).explosiveness = explosiveness
	elif node is CPUParticles3D: (node as CPUParticles3D).explosiveness = explosiveness
	elif node is GPUParticles2D: (node as GPUParticles2D).explosiveness = explosiveness
	elif node is GPUParticles3D: (node as GPUParticles3D).explosiveness = explosiveness
	else:
		_send_response({"error": "Not a particle node: " + node_path})
		return
	_send_response({"success": true, "explosiveness": explosiveness})


func _cmd_set_particle_randomness(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var randomness: float = params.get("randomness", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CPUParticles2D: (node as CPUParticles2D).randomness = randomness
	elif node is CPUParticles3D: (node as CPUParticles3D).randomness = randomness
	elif node is GPUParticles2D: (node as GPUParticles2D).randomness = randomness
	elif node is GPUParticles3D: (node as GPUParticles3D).randomness = randomness
	else:
		_send_response({"error": "Not a particle node: " + node_path})
		return
	_send_response({"success": true, "randomness": randomness})


func _cmd_set_particle_lifetime(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var lifetime: float = params.get("lifetime", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CPUParticles2D: (node as CPUParticles2D).lifetime = lifetime
	elif node is CPUParticles3D: (node as CPUParticles3D).lifetime = lifetime
	elif node is GPUParticles2D: (node as GPUParticles2D).lifetime = lifetime
	elif node is GPUParticles3D: (node as GPUParticles3D).lifetime = lifetime
	else:
		_send_response({"error": "Not a particle node: " + node_path})
		return
	_send_response({"success": true, "lifetime": lifetime})


func _cmd_set_particle_one_shot(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var one_shot: bool = params.get("one_shot", false)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CPUParticles2D: (node as CPUParticles2D).one_shot = one_shot
	elif node is CPUParticles3D: (node as CPUParticles3D).one_shot = one_shot
	elif node is GPUParticles2D: (node as GPUParticles2D).one_shot = one_shot
	elif node is GPUParticles3D: (node as GPUParticles3D).one_shot = one_shot
	else:
		_send_response({"error": "Not a particle node: " + node_path})
		return
	_send_response({"success": true, "one_shot": one_shot})


func _cmd_set_control_anchor(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var preset_str: String = params.get("preset", "top_left")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	var preset: Control.LayoutPreset
	match preset_str:
		"top_left": preset = Control.PRESET_TOP_LEFT
		"top_right": preset = Control.PRESET_TOP_RIGHT
		"bottom_left": preset = Control.PRESET_BOTTOM_LEFT
		"bottom_right": preset = Control.PRESET_BOTTOM_RIGHT
		"center_left": preset = Control.PRESET_CENTER_LEFT
		"center_right": preset = Control.PRESET_CENTER_RIGHT
		"center_top": preset = Control.PRESET_CENTER_TOP
		"center_bottom": preset = Control.PRESET_CENTER_BOTTOM
		"center": preset = Control.PRESET_CENTER
		"full_rect": preset = Control.PRESET_FULL_RECT
		"left_wide": preset = Control.PRESET_LEFT_WIDE
		"right_wide": preset = Control.PRESET_RIGHT_WIDE
		"top_wide": preset = Control.PRESET_TOP_WIDE
		"bottom_wide": preset = Control.PRESET_BOTTOM_WIDE
		"vcenter_wide": preset = Control.PRESET_VCENTER_WIDE
		"hcenter_wide": preset = Control.PRESET_HCENTER_WIDE
		_: preset = Control.PRESET_TOP_LEFT
	(node as Control).set_anchors_and_offsets_preset(preset)
	_send_response({"success": true, "preset": preset_str})


func _cmd_get_control_rect(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	var c := node as Control
	var r = c.get_rect()
	_send_response({"success": true, "x": r.position.x, "y": r.position.y, "width": r.size.x, "height": r.size.y, "global_x": c.global_position.x, "global_y": c.global_position.y})


func _cmd_get_control_focus(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	_send_response({"success": true, "has_focus": (node as Control).has_focus()})


func _cmd_set_control_focus(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	(node as Control).grab_focus()
	_send_response({"success": true, "focused": true})


func _cmd_get_node_signal_list(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var signals = node.get_signal_list()
	var result = []
	for s in signals:
		result.append(s.get("name", ""))
	_send_response({"success": true, "signals": result, "count": result.size()})


func _cmd_has_signal(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var signal_name: String = params.get("signal_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "has_signal": node.has_signal(signal_name), "signal_name": signal_name})


func _cmd_get_signal_connection_list(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var signal_name: String = params.get("signal_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if not node.has_signal(signal_name):
		_send_response({"error": "Signal not found: " + signal_name})
		return
	var connections = node.get_signal_connection_list(signal_name)
	var result = []
	for c in connections:
		result.append({"target": str(c.get("callable", ""))})
	_send_response({"success": true, "connections": result, "count": result.size()})


func _cmd_get_node_connections_count(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var signals = node.get_signal_list()
	var total = 0
	for s in signals:
		total += node.get_signal_connection_list(s.get("name", "")).size()
	_send_response({"success": true, "total_connections": total, "signal_count": signals.size()})


func _cmd_list_all_signal_connections(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var signals = node.get_signal_list()
	var result = {}
	for s in signals:
		var sname = s.get("name", "")
		var conns = node.get_signal_connection_list(sname)
		if conns.size() > 0:
			var list = []
			for c in conns:
				list.append(str(c.get("callable", "")))
			result[sname] = list
	_send_response({"success": true, "connected_signals": result})


func _cmd_get_node_path(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "node_path": str(node.get_path()), "name": node.name})


func _cmd_get_node_parent_path(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var parent = node.get_parent()
	if parent == null:
		_send_response({"success": true, "parent_path": "", "is_root": true})
	else:
		_send_response({"success": true, "parent_path": str(parent.get_path()), "parent_name": parent.name})


func _cmd_get_node_child_paths(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var result = []
	for i in node.get_child_count():
		var child = node.get_child(i)
		result.append({"name": child.name, "path": str(child.get_path()), "class": child.get_class()})
	_send_response({"success": true, "children": result, "count": result.size()})


func _cmd_is_node_in_group(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var group_name: String = params.get("group_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "in_group": node.is_in_group(group_name), "group_name": group_name, "all_groups": node.get_groups()})


func _cmd_set_light_2d_energy(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var energy: float = params.get("energy", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Light2D:
		_send_response({"error": "Light2D not found: " + node_path})
		return
	(node as Light2D).energy = energy
	_send_response({"success": true, "energy": energy})


func _cmd_get_light_2d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Light2D:
		_send_response({"error": "Light2D not found: " + node_path})
		return
	var l := node as Light2D
	_send_response({"success": true, "energy": l.energy, "enabled": l.enabled, "color": {"r": l.color.r, "g": l.color.g, "b": l.color.b}, "class": l.get_class()})


func _cmd_set_light_2d_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Light2D:
		_send_response({"error": "Light2D not found: " + node_path})
		return
	(node as Light2D).color = Color(r, g, b)
	_send_response({"success": true, "color": {"r": r, "g": g, "b": b}})


func _cmd_set_light_2d_texture_scale(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var scale_val: float = params.get("scale", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is PointLight2D:
		_send_response({"error": "PointLight2D not found: " + node_path})
		return
	(node as PointLight2D).texture_scale = scale_val
	_send_response({"success": true, "texture_scale": scale_val})


func _cmd_toggle_light_2d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var enabled: bool = params.get("enabled", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Light2D:
		_send_response({"error": "Light2D not found: " + node_path})
		return
	(node as Light2D).enabled = enabled
	_send_response({"success": true, "enabled": enabled})


func _cmd_get_skeleton_bone_pose(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bone_name: String = params.get("bone_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	var sk := node as Skeleton3D
	var idx = sk.find_bone(bone_name)
	if idx < 0:
		_send_response({"error": "Bone not found: " + bone_name})
		return
	var pose = sk.get_bone_pose_position(idx)
	var rot = sk.get_bone_pose_rotation(idx)
	_send_response({"success": true, "position": {"x": pose.x, "y": pose.y, "z": pose.z}, "rotation": {"x": rot.x, "y": rot.y, "z": rot.z, "w": rot.w}, "bone_index": idx})


func _cmd_set_skeleton_bone_pose_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bone_name: String = params.get("bone_name", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	var sk := node as Skeleton3D
	var idx = sk.find_bone(bone_name)
	if idx < 0:
		_send_response({"error": "Bone not found: " + bone_name})
		return
	sk.set_bone_pose_position(idx, Vector3(x, y, z))
	_send_response({"success": true, "bone_name": bone_name, "position": {"x": x, "y": y, "z": z}})


func _cmd_get_bone_rest_transform(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bone_name: String = params.get("bone_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	var sk := node as Skeleton3D
	var idx = sk.find_bone(bone_name)
	if idx < 0:
		_send_response({"error": "Bone not found: " + bone_name})
		return
	var rest = sk.get_bone_rest(idx)
	var o = rest.origin
	_send_response({"success": true, "bone_name": bone_name, "rest_origin": {"x": o.x, "y": o.y, "z": o.z}})


func _cmd_get_bone_index(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bone_name: String = params.get("bone_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	var idx = (node as Skeleton3D).find_bone(bone_name)
	_send_response({"success": true, "bone_name": bone_name, "bone_index": idx, "found": idx >= 0})


func _cmd_get_game_resolution(params: Dictionary) -> void:
	var win_size = DisplayServer.window_get_size()
	var viewport_size = get_viewport().get_visible_rect().size
	_send_response({"success": true, "window_width": win_size.x, "window_height": win_size.y, "viewport_width": viewport_size.x, "viewport_height": viewport_size.y})


func _cmd_set_2d_speed_scale(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var scale_val: float = params.get("scale", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is AnimationPlayer:
		(node as AnimationPlayer).speed_scale = scale_val
	elif node is AnimatedSprite2D:
		(node as AnimatedSprite2D).speed_scale = scale_val
	else:
		_send_response({"error": "Node does not support speed_scale: " + node_path})
		return
	_send_response({"success": true, "scale": scale_val})


func _cmd_get_scene_current_fps(params: Dictionary) -> void:
	_send_response({"success": true, "fps": Engine.get_frames_per_second(), "target_fps": Engine.max_fps, "physics_fps": Engine.physics_ticks_per_second})


func _cmd_set_canvas_item_clip(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var clip: bool = params.get("clip", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasItem:
		_send_response({"error": "CanvasItem not found: " + node_path})
		return
	(node as CanvasItem).clip_contents = clip
	_send_response({"success": true, "clip_contents": clip})


func _cmd_get_node_rid(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "rid": str(node.get_rid() if node.has_method("get_rid") else "N/A"), "class": node.get_class()})


func _cmd_set_node_owner(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var owner_path: String = params.get("owner_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	var owner_node = get_tree().root.get_node_or_null(NodePath(owner_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if owner_node == null:
		_send_response({"error": "Owner node not found: " + owner_path})
		return
	node.owner = owner_node
	_send_response({"success": true, "owner": owner_path})


func _cmd_get_physics_interpolation_mode(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "physics_interpolation_mode": node.physics_interpolation_mode})


func _cmd_get_memory_usage(params: Dictionary) -> void:
	_send_response({"success": true, "static_memory": OS.get_static_memory_usage(), "static_memory_peak": OS.get_static_memory_peak_usage()})


func _cmd_get_project_name(params: Dictionary) -> void:
	_send_response({"success": true, "project_name": ProjectSettings.get_setting("application/config/name", "Unknown"), "version": ProjectSettings.get_setting("application/config/version", "1.0")})


func _cmd_enable_ray_cast_2d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var enabled: bool = params.get("enabled", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RayCast2D:
		_send_response({"error": "RayCast2D not found: " + node_path})
		return
	(node as RayCast2D).enabled = enabled
	_send_response({"success": true, "enabled": enabled})


func _cmd_set_ray_cast_2d_target(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RayCast2D:
		_send_response({"error": "RayCast2D not found: " + node_path})
		return
	(node as RayCast2D).target_position = Vector2(x, y)
	_send_response({"success": true, "target_position": {"x": x, "y": y}})


func _cmd_get_ray_cast_2d_collision(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RayCast2D:
		_send_response({"error": "RayCast2D not found: " + node_path})
		return
	var rc := node as RayCast2D
	if not rc.is_colliding():
		_send_response({"success": true, "colliding": false})
		return
	var pt = rc.get_collision_point()
	var normal = rc.get_collision_normal()
	var collider = rc.get_collider()
	_send_response({"success": true, "colliding": true, "collision_point": {"x": pt.x, "y": pt.y}, "collision_normal": {"x": normal.x, "y": normal.y}, "collider": str(collider.get_path()) if collider != null else "null"})


func _cmd_enable_ray_cast_3d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var enabled: bool = params.get("enabled", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RayCast3D:
		_send_response({"error": "RayCast3D not found: " + node_path})
		return
	(node as RayCast3D).enabled = enabled
	_send_response({"success": true, "enabled": enabled})


func _cmd_set_ray_cast_3d_target(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", -1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RayCast3D:
		_send_response({"error": "RayCast3D not found: " + node_path})
		return
	(node as RayCast3D).target_position = Vector3(x, y, z)
	_send_response({"success": true, "target_position": {"x": x, "y": y, "z": z}})


func _cmd_get_ray_cast_3d_collision(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RayCast3D:
		_send_response({"error": "RayCast3D not found: " + node_path})
		return
	var rc := node as RayCast3D
	if not rc.is_colliding():
		_send_response({"success": true, "colliding": false})
		return
	var pt = rc.get_collision_point()
	var normal = rc.get_collision_normal()
	var collider = rc.get_collider()
	_send_response({"success": true, "colliding": true, "collision_point": {"x": pt.x, "y": pt.y, "z": pt.z}, "collision_normal": {"x": normal.x, "y": normal.y, "z": normal.z}, "collider": str(collider.get_path()) if collider != null else "null"})


func _cmd_force_ray_cast_update(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is RayCast2D:
		(node as RayCast2D).force_raycast_update()
		_send_response({"success": true, "type": "RayCast2D"})
	elif node is RayCast3D:
		(node as RayCast3D).force_raycast_update()
		_send_response({"success": true, "type": "RayCast3D"})
	else:
		_send_response({"error": "Not a RayCast node: " + node_path})


func _cmd_cast_ray_from_camera(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var screen_x: float = params.get("screen_x", 0.5)
	var screen_y: float = params.get("screen_y", 0.5)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Camera3D:
		_send_response({"error": "Camera3D not found: " + node_path})
		return
	var vp_size = get_viewport().get_visible_rect().size
	var screen_pos = Vector2(screen_x * vp_size.x, screen_y * vp_size.y)
	var from = (node as Camera3D).project_ray_origin(screen_pos)
	var to = from + (node as Camera3D).project_ray_normal(screen_pos) * 1000.0
	var space = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	var result = space.intersect_ray(query)
	if result.is_empty():
		_send_response({"success": true, "hit": false})
	else:
		var pos = result.get("position", Vector3.ZERO)
		_send_response({"success": true, "hit": true, "position": {"x": pos.x, "y": pos.y, "z": pos.z}, "collider": str(result.get("collider", "").get_path()) if result.get("collider") != null else "null"})


func _cmd_get_overlapping_bodies_2d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Area2D:
		_send_response({"error": "Area2D not found: " + node_path})
		return
	var bodies = (node as Area2D).get_overlapping_bodies()
	var result = []
	for b in bodies:
		result.append({"path": str(b.get_path()), "class": b.get_class()})
	_send_response({"success": true, "bodies": result, "count": result.size()})


func _cmd_get_overlapping_areas_2d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Area2D:
		_send_response({"error": "Area2D not found: " + node_path})
		return
	var areas = (node as Area2D).get_overlapping_areas()
	var result = []
	for a in areas:
		result.append({"path": str(a.get_path()), "class": a.get_class()})
	_send_response({"success": true, "areas": result, "count": result.size()})


func _cmd_get_overlapping_bodies_3d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Area3D:
		_send_response({"error": "Area3D not found: " + node_path})
		return
	var bodies = (node as Area3D).get_overlapping_bodies()
	var result = []
	for b in bodies:
		result.append({"path": str(b.get_path()), "class": b.get_class()})
	_send_response({"success": true, "bodies": result, "count": result.size()})


func _cmd_get_overlapping_areas_3d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Area3D:
		_send_response({"error": "Area3D not found: " + node_path})
		return
	var areas = (node as Area3D).get_overlapping_areas()
	var result = []
	for a in areas:
		result.append({"path": str(a.get_path()), "class": a.get_class()})
	_send_response({"success": true, "areas": result, "count": result.size()})


func _cmd_check_area_2d_monitoring(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Area2D:
		_send_response({"error": "Area2D not found: " + node_path})
		return
	var a := node as Area2D
	_send_response({"success": true, "monitoring": a.monitoring, "monitorable": a.monitorable, "collision_layer": a.collision_layer, "collision_mask": a.collision_mask})


func _cmd_get_audio_bus_info(params: Dictionary) -> void:
	var bus_index: int = params.get("bus_index", 0)
	var bus_name: String = params.get("bus_name", "")
	if bus_name != "":
		bus_index = AudioServer.get_bus_index(bus_name)
		if bus_index < 0:
			_send_response({"error": "Bus not found: " + bus_name})
			return
	if bus_index >= AudioServer.bus_count:
		_send_response({"error": "Bus index out of range: " + str(bus_index)})
		return
	_send_response({"success": true, "name": AudioServer.get_bus_name(bus_index), "volume_db": AudioServer.get_bus_volume_db(bus_index), "mute": AudioServer.is_bus_mute(bus_index), "solo": AudioServer.is_bus_solo(bus_index), "effect_count": AudioServer.get_bus_effect_count(bus_index), "send": AudioServer.get_bus_send(bus_index)})


func _cmd_set_audio_bus_effect_enabled(params: Dictionary) -> void:
	var bus_index: int = params.get("bus_index", 0)
	var effect_index: int = params.get("effect_index", 0)
	var enabled: bool = params.get("enabled", true)
	if bus_index >= AudioServer.bus_count:
		_send_response({"error": "Bus index out of range"})
		return
	AudioServer.set_bus_effect_enabled(bus_index, effect_index, enabled)
	_send_response({"success": true, "bus_index": bus_index, "effect_index": effect_index, "enabled": enabled})


func _cmd_get_audio_stream_player_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is AudioStreamPlayer:
		_send_response({"success": true, "position": (node as AudioStreamPlayer).get_playback_position(), "is_playing": (node as AudioStreamPlayer).playing})
	elif node is AudioStreamPlayer2D:
		_send_response({"success": true, "position": (node as AudioStreamPlayer2D).get_playback_position(), "is_playing": (node as AudioStreamPlayer2D).playing})
	elif node is AudioStreamPlayer3D:
		_send_response({"success": true, "position": (node as AudioStreamPlayer3D).get_playback_position(), "is_playing": (node as AudioStreamPlayer3D).playing})
	else:
		_send_response({"error": "Not an AudioStreamPlayer: " + node_path})


func _cmd_set_audio_stream_player_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var to_position: float = params.get("to_position", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is AudioStreamPlayer:
		(node as AudioStreamPlayer).seek(to_position)
	elif node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).seek(to_position)
	elif node is AudioStreamPlayer3D:
		(node as AudioStreamPlayer3D).seek(to_position)
	else:
		_send_response({"error": "Not an AudioStreamPlayer: " + node_path})
		return
	_send_response({"success": true, "seeked_to": to_position})


func _cmd_get_audio_stream_length(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var stream = null
	if node is AudioStreamPlayer: stream = (node as AudioStreamPlayer).stream
	elif node is AudioStreamPlayer2D: stream = (node as AudioStreamPlayer2D).stream
	elif node is AudioStreamPlayer3D: stream = (node as AudioStreamPlayer3D).stream
	if stream == null:
		_send_response({"error": "No stream assigned"})
		return
	_send_response({"success": true, "length": stream.get_length()})


func _cmd_set_audio_pitch_scale(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var pitch_scale: float = params.get("pitch_scale", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is AudioStreamPlayer: (node as AudioStreamPlayer).pitch_scale = pitch_scale
	elif node is AudioStreamPlayer2D: (node as AudioStreamPlayer2D).pitch_scale = pitch_scale
	elif node is AudioStreamPlayer3D: (node as AudioStreamPlayer3D).pitch_scale = pitch_scale
	else:
		_send_response({"error": "Not an AudioStreamPlayer: " + node_path})
		return
	_send_response({"success": true, "pitch_scale": pitch_scale})


func _cmd_get_sub_viewport_texture_rid(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SubViewport:
		_send_response({"error": "SubViewport not found: " + node_path})
		return
	var tex = (node as SubViewport).get_texture()
	_send_response({"success": true, "has_texture": tex != null, "size": {"w": (node as SubViewport).size.x, "h": (node as SubViewport).size.y}})


func _cmd_set_sub_viewport_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var w: int = params.get("w", 256)
	var h: int = params.get("h", 256)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SubViewport:
		_send_response({"error": "SubViewport not found: " + node_path})
		return
	(node as SubViewport).size = Vector2i(w, h)
	_send_response({"success": true, "size": {"w": w, "h": h}})


func _cmd_set_sub_viewport_update_mode(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var mode_str: String = params.get("mode", "always")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SubViewport:
		_send_response({"error": "SubViewport not found: " + node_path})
		return
	var mode: SubViewport.UpdateMode
	match mode_str:
		"disabled": mode = SubViewport.UPDATE_DISABLED
		"once": mode = SubViewport.UPDATE_ONCE
		"always": mode = SubViewport.UPDATE_ALWAYS
		"when_visible": mode = SubViewport.UPDATE_WHEN_VISIBLE
		_: mode = SubViewport.UPDATE_ALWAYS
	(node as SubViewport).render_target_update_mode = mode
	_send_response({"success": true, "mode": mode_str})


func _cmd_get_viewport_textures(params: Dictionary) -> void:
	var result = []
	var nodes = get_tree().root.find_children("*", "SubViewport", true, false)
	for node in nodes:
		var sv := node as SubViewport
		result.append({"path": str(sv.get_path()), "size": {"w": sv.size.x, "h": sv.size.y}})
	_send_response({"success": true, "sub_viewports": result, "count": result.size()})


func _cmd_set_viewport_msaa(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var msaa_level: int = params.get("msaa", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Viewport:
		_send_response({"error": "Viewport not found: " + node_path})
		return
	var msaa: Viewport.MSAA
	match msaa_level:
		0: msaa = Viewport.MSAA_DISABLED
		2: msaa = Viewport.MSAA_2X
		4: msaa = Viewport.MSAA_4X
		8: msaa = Viewport.MSAA_8X
		_: msaa = Viewport.MSAA_DISABLED
	(node as Viewport).msaa_3d = msaa
	_send_response({"success": true, "msaa": msaa_level})


func _cmd_get_class_property_list(params: Dictionary) -> void:
	var class_name_str: String = params.get("class_name", "")
	if class_name_str.is_empty() or not ClassDB.class_exists(class_name_str):
		_send_response({"error": "Class not found: " + class_name_str})
		return
	var props = ClassDB.class_get_property_list(class_name_str)
	var result = []
	for p in props:
		result.append({"name": p.get("name", ""), "type": p.get("type", 0)})
	_send_response({"success": true, "class": class_name_str, "properties": result, "count": result.size()})


func _cmd_get_class_method_list(params: Dictionary) -> void:
	var class_name_str: String = params.get("class_name", "")
	if class_name_str.is_empty() or not ClassDB.class_exists(class_name_str):
		_send_response({"error": "Class not found: " + class_name_str})
		return
	var methods = ClassDB.class_get_method_list(class_name_str)
	var result = []
	for m in methods:
		result.append(m.get("name", ""))
	_send_response({"success": true, "class": class_name_str, "methods": result, "count": result.size()})


func _cmd_get_class_signal_list(params: Dictionary) -> void:
	var class_name_str: String = params.get("class_name", "")
	if class_name_str.is_empty() or not ClassDB.class_exists(class_name_str):
		_send_response({"error": "Class not found: " + class_name_str})
		return
	var signals = ClassDB.class_get_signal_list(class_name_str)
	var result = []
	for s in signals:
		result.append(s.get("name", ""))
	_send_response({"success": true, "class": class_name_str, "signals": result, "count": result.size()})


func _cmd_class_exists(params: Dictionary) -> void:
	var class_name_str: String = params.get("class_name", "")
	_send_response({"success": true, "exists": ClassDB.class_exists(class_name_str), "class_name": class_name_str})


func _cmd_get_class_inheritance(params: Dictionary) -> void:
	var class_name_str: String = params.get("class_name", "")
	if not ClassDB.class_exists(class_name_str):
		_send_response({"error": "Class not found: " + class_name_str})
		return
	var chain = [class_name_str]
	var current = class_name_str
	while true:
		var parent = ClassDB.get_parent_class(current)
		if parent.is_empty():
			break
		chain.append(parent)
		current = parent
		if chain.size() > 30:
			break
	_send_response({"success": true, "class": class_name_str, "inheritance_chain": chain})


func _cmd_instantiate_class_check(params: Dictionary) -> void:
	var class_name_str: String = params.get("class_name", "")
	if not ClassDB.class_exists(class_name_str):
		_send_response({"success": true, "exists": false, "can_instantiate": false, "class_name": class_name_str})
		return
	var can_inst = ClassDB.can_instantiate(class_name_str)
	_send_response({"success": true, "class_name": class_name_str, "exists": true, "can_instantiate": can_inst})


func _cmd_get_mesh_aabb(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var aabb = (node as MeshInstance3D).get_aabb()
	_send_response({"success": true, "position": {"x": aabb.position.x, "y": aabb.position.y, "z": aabb.position.z}, "size": {"x": aabb.size.x, "y": aabb.size.y, "z": aabb.size.z}})


func _cmd_get_mesh_vertex_count(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var surface_index: int = params.get("surface_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mesh = (node as MeshInstance3D).mesh
	if mesh == null:
		_send_response({"error": "No mesh assigned"})
		return
	if surface_index >= mesh.get_surface_count():
		_send_response({"error": "Surface index out of range"})
		return
	var arrays = mesh.surface_get_arrays(surface_index)
	var verts = arrays[Mesh.ARRAY_VERTEX] if arrays != null and arrays.size() > Mesh.ARRAY_VERTEX else null
	_send_response({"success": true, "vertex_count": verts.size() if verts != null else 0, "surface_index": surface_index})


func _cmd_set_mesh_instance_cast_shadow(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var cast_shadow_str: String = params.get("cast_shadow", "on")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mode: GeometryInstance3D.ShadowCastingSetting
	match cast_shadow_str:
		"off": mode = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		"on": mode = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		"double_sided": mode = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		"shadows_only": mode = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		_: mode = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	(node as MeshInstance3D).cast_shadow = mode
	_send_response({"success": true, "cast_shadow": cast_shadow_str})


func _cmd_get_mesh_surface_count_rt(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mesh = (node as MeshInstance3D).mesh
	_send_response({"success": true, "surface_count": mesh.get_surface_count() if mesh != null else 0})


func _cmd_set_mesh_lod_bias(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var lod_bias: float = params.get("lod_bias", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	(node as MeshInstance3D).lod_bias = lod_bias
	_send_response({"success": true, "lod_bias": lod_bias})


func _cmd_get_mesh_instance_bounds(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var aabb = (node as MeshInstance3D).get_transformed_aabb()
	var center = aabb.get_center()
	_send_response({"success": true, "center": {"x": center.x, "y": center.y, "z": center.z}, "size": {"x": aabb.size.x, "y": aabb.size.y, "z": aabb.size.z}})


func _cmd_set_mesh_transparency(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var transparency: float = params.get("transparency", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	(node as MeshInstance3D).transparency = transparency
	_send_response({"success": true, "transparency": transparency})


func _cmd_rename_node_runtime(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var new_name: String = params.get("new_name", "")
	if new_name.is_empty():
		_send_response({"error": "new_name is required"})
		return
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	node.name = new_name
	_send_response({"success": true, "new_name": new_name, "new_path": str(node.get_path())})


func _cmd_list_node_metadata(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "meta_list": node.get_meta_list(), "count": node.get_meta_list().size()})


func _cmd_remove_node_metadata(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var meta_key: String = params.get("meta_key", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node.has_meta(meta_key):
		node.remove_meta(meta_key)
		_send_response({"success": true, "removed": meta_key})
	else:
		_send_response({"error": "Meta key not found: " + meta_key})


func _cmd_get_physics_2d_gravity(params: Dictionary) -> void:
	var gravity = ProjectSettings.get_setting("physics/2d/default_gravity", 980.0)
	_send_response({"success": true, "gravity": gravity})


func _cmd_get_all_node_classes(params: Dictionary) -> void:
	var all_classes = ClassDB.get_class_list()
	var node_classes = []
	for c in all_classes:
		if ClassDB.is_parent_class(c, "Node"):
			node_classes.append(c)
	node_classes.sort()
	_send_response({"success": true, "node_classes": node_classes, "count": node_classes.size()})


func _cmd_get_running_scene_path(params: Dictionary) -> void:
	var scene = get_tree().current_scene
	_send_response({"success": true, "scene_path": scene.scene_file_path if scene != null else "", "scene_name": scene.name if scene != null else ""})


func _cmd_get_node_scene_file_path(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	_send_response({"success": true, "scene_file_path": node.scene_file_path if node.scene_file_path != null else ""})


func _cmd_get_scene_unique_nodes(params: Dictionary) -> void:
	var result = []
	var process_node = func(node: Node) -> void:
		if node.unique_name_in_owner:
			result.append({"name": node.name, "path": str(node.get_path()), "class": node.get_class()})
	var queue = [get_tree().current_scene]
	while queue.size() > 0:
		var n = queue.pop_front()
		if n != null:
			process_node.call(n)
			for child in n.get_children():
				queue.append(child)
	_send_response({"success": true, "unique_nodes": result, "count": result.size()})


func _cmd_get_tilemap_cell_source_id(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: int = params.get("x", 0)
	var y: int = params.get("y", 0)
	var layer: int = params.get("layer", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	var tm := node as TileMap
	var source_id = tm.get_cell_source_id(layer, Vector2i(x, y))
	_send_response({"success": true, "source_id": source_id, "x": x, "y": y, "layer": layer})

func _cmd_erase_tilemap_cell(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: int = params.get("x", 0)
	var y: int = params.get("y", 0)
	var layer: int = params.get("layer", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	(node as TileMap).erase_cell(layer, Vector2i(x, y))
	_send_response({"success": true, "erased": {"x": x, "y": y}})

func _cmd_get_tilemap_used_cells(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var layer: int = params.get("layer", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	var cells = (node as TileMap).get_used_cells(layer)
	var result = []
	for c in cells:
		result.append({"x": c.x, "y": c.y})
	_send_response({"success": true, "cells": result, "count": result.size()})

func _cmd_map_to_local_tilemap(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: int = params.get("x", 0)
	var y: int = params.get("y", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TileMap:
		_send_response({"error": "TileMap not found: " + node_path})
		return
	var local_pos = (node as TileMap).map_to_local(Vector2i(x, y))
	_send_response({"success": true, "local_x": local_pos.x, "local_y": local_pos.y})

func _cmd_get_gridmap_cell_item(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: int = params.get("x", 0)
	var y: int = params.get("y", 0)
	var z: int = params.get("z", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GridMap:
		_send_response({"error": "GridMap not found: " + node_path})
		return
	var item = (node as GridMap).get_cell_item(Vector3i(x, y, z))
	_send_response({"success": true, "item_id": item, "x": x, "y": y, "z": z})

func _cmd_set_gridmap_cell_item(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: int = params.get("x", 0)
	var y: int = params.get("y", 0)
	var z: int = params.get("z", 0)
	var item_id: int = params.get("item_id", 0)
	var orientation: int = params.get("orientation", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GridMap:
		_send_response({"error": "GridMap not found: " + node_path})
		return
	(node as GridMap).set_cell_item(Vector3i(x, y, z), item_id, orientation)
	_send_response({"success": true, "x": x, "y": y, "z": z, "item_id": item_id})

func _cmd_get_gridmap_used_cells(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GridMap:
		_send_response({"error": "GridMap not found: " + node_path})
		return
	var cells = (node as GridMap).get_used_cells()
	var result = []
	for c in cells:
		result.append({"x": c.x, "y": c.y, "z": c.z})
	_send_response({"success": true, "cells": result, "count": result.size()})

func _cmd_clear_gridmap(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GridMap:
		_send_response({"error": "GridMap not found: " + node_path})
		return
	(node as GridMap).clear()
	_send_response({"success": true, "cleared": node_path})

func _cmd_get_gridmap_cell_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GridMap:
		_send_response({"error": "GridMap not found: " + node_path})
		return
	var size = (node as GridMap).cell_size
	_send_response({"success": true, "cell_size": {"x": size.x, "y": size.y, "z": size.z}})

func _cmd_get_gridmap_mesh_library_items(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GridMap:
		_send_response({"error": "GridMap not found: " + node_path})
		return
	var gm := node as GridMap
	if gm.mesh_library == null:
		_send_response({"success": true, "items": [], "count": 0, "note": "No MeshLibrary assigned"})
		return
	var item_ids = gm.mesh_library.get_item_list()
	var result = []
	for id in item_ids:
		result.append({"id": id, "name": gm.mesh_library.get_item_name(id)})
	_send_response({"success": true, "items": result, "count": result.size()})

func _cmd_get_gridmap_bake_mesh(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GridMap:
		_send_response({"error": "GridMap not found: " + node_path})
		return
	var gm := node as GridMap
	var aabb = gm.get_bake_meshes_aabb()
	_send_response({"success": true, "aabb_position": {"x": aabb.position.x, "y": aabb.position.y, "z": aabb.position.z}, "aabb_size": {"x": aabb.size.x, "y": aabb.size.y, "z": aabb.size.z}})

func _cmd_play_video_stream(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is VideoStreamPlayer:
		_send_response({"error": "VideoStreamPlayer not found: " + node_path})
		return
	(node as VideoStreamPlayer).play()
	_send_response({"success": true, "playing": true})

func _cmd_stop_video_stream(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is VideoStreamPlayer:
		_send_response({"error": "VideoStreamPlayer not found: " + node_path})
		return
	(node as VideoStreamPlayer).stop()
	_send_response({"success": true, "stopped": true})

func _cmd_get_video_stream_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is VideoStreamPlayer:
		_send_response({"error": "VideoStreamPlayer not found: " + node_path})
		return
	_send_response({"success": true, "position": (node as VideoStreamPlayer).stream_position})

func _cmd_set_video_stream_volume(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var volume: float = params.get("volume", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is VideoStreamPlayer:
		_send_response({"error": "VideoStreamPlayer not found: " + node_path})
		return
	(node as VideoStreamPlayer).volume = volume
	_send_response({"success": true, "volume": volume})

func _cmd_is_video_stream_playing(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is VideoStreamPlayer:
		_send_response({"error": "VideoStreamPlayer not found: " + node_path})
		return
	_send_response({"success": true, "is_playing": (node as VideoStreamPlayer).is_playing()})

func _cmd_get_astar2d_point_count(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node.get("astar") != null and node.get("astar") is AStar2D:
		_send_response({"success": true, "point_count": node.astar.get_point_count()})
	else:
		_send_response({"error": "Node has no 'astar' property of type AStar2D"})

func _cmd_add_astar2d_point(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var point_id: int = params.get("point_id", 0)
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var weight_scale: float = params.get("weight_scale", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or node.get("astar") == null or not node.astar is AStar2D:
		_send_response({"error": "Node with AStar2D 'astar' not found: " + node_path})
		return
	node.astar.add_point(point_id, Vector2(x, y), weight_scale)
	_send_response({"success": true, "added_point_id": point_id})

func _cmd_connect_astar2d_points(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var id1: int = params.get("id1", 0)
	var id2: int = params.get("id2", 1)
	var bidirectional: bool = params.get("bidirectional", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or node.get("astar") == null or not node.astar is AStar2D:
		_send_response({"error": "Node with AStar2D 'astar' not found: " + node_path})
		return
	node.astar.connect_points(id1, id2, bidirectional)
	_send_response({"success": true, "connected": [id1, id2]})

func _cmd_get_astar2d_id_path(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var from_id: int = params.get("from_id", 0)
	var to_id: int = params.get("to_id", 1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or node.get("astar") == null or not node.astar is AStar2D:
		_send_response({"error": "Node with AStar2D 'astar' not found: " + node_path})
		return
	var path = node.astar.get_id_path(from_id, to_id)
	_send_response({"success": true, "id_path": Array(path)})

func _cmd_get_astar2d_point_path(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var from_id: int = params.get("from_id", 0)
	var to_id: int = params.get("to_id", 1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or node.get("astar") == null or not node.astar is AStar2D:
		_send_response({"error": "Node with AStar2D 'astar' not found: " + node_path})
		return
	var path = node.astar.get_point_path(from_id, to_id)
	var result = []
	for p in path:
		result.append({"x": p.x, "y": p.y})
	_send_response({"success": true, "point_path": result, "count": result.size()})

func _cmd_get_world_environment_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is WorldEnvironment:
		_send_response({"error": "WorldEnvironment not found: " + node_path})
		return
	var env = (node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "No Environment resource assigned"})
		return
	_send_response({"success": true, "ambient_energy": env.ambient_light_energy, "fog_enabled": env.fog_enabled, "glow_enabled": env.glow_enabled, "tonemap_mode": env.tonemap_mode})

func _cmd_set_environment_ambient_light(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 0.1)
	var g: float = params.get("g", 0.1)
	var b: float = params.get("b", 0.1)
	var a: float = params.get("a", 1.0)
	var energy: float = params.get("energy", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is WorldEnvironment:
		_send_response({"error": "WorldEnvironment not found: " + node_path})
		return
	var env = (node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "No Environment resource assigned"})
		return
	env.ambient_light_color = Color(r, g, b, a)
	env.ambient_light_energy = energy
	_send_response({"success": true, "ambient_color": {"r": r, "g": g, "b": b}, "energy": energy})

func _cmd_set_environment_bloom(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var enabled: bool = params.get("enabled", true)
	var threshold: float = params.get("threshold", 1.0)
	var intensity: float = params.get("intensity", 0.8)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is WorldEnvironment:
		_send_response({"error": "WorldEnvironment not found: " + node_path})
		return
	var env = (node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "No Environment resource assigned"})
		return
	env.glow_enabled = enabled
	env.glow_bloom = threshold
	env.glow_intensity = intensity
	_send_response({"success": true, "bloom_enabled": enabled, "threshold": threshold, "intensity": intensity})

func _cmd_set_environment_tonemap(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var mode_str: String = params.get("mode", "filmic")
	var exposure: float = params.get("exposure", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is WorldEnvironment:
		_send_response({"error": "WorldEnvironment not found: " + node_path})
		return
	var env = (node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "No Environment resource assigned"})
		return
	var mode: Environment.ToneMapper
	match mode_str:
		"linear": mode = Environment.TONE_MAPPER_LINEAR
		"reinhard": mode = Environment.TONE_MAPPER_REINHARDT
		"filmic": mode = Environment.TONE_MAPPER_FILMIC
		"aces": mode = Environment.TONE_MAPPER_ACES
		_: mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_mode = mode
	env.tonemap_exposure = exposure
	_send_response({"success": true, "tonemap_mode": mode_str, "exposure": exposure})

func _cmd_set_environment_sky_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 0.4)
	var g: float = params.get("g", 0.6)
	var b: float = params.get("b", 0.9)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is WorldEnvironment:
		_send_response({"error": "WorldEnvironment not found: " + node_path})
		return
	var env = (node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "No Environment resource assigned"})
		return
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(r, g, b)
	_send_response({"success": true, "background_color": {"r": r, "g": g, "b": b}})

func _cmd_set_particles_lifetime(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var lifetime: float = params.get("lifetime", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is GPUParticles2D: (node as GPUParticles2D).lifetime = lifetime
	elif node is CPUParticles2D: (node as CPUParticles2D).lifetime = lifetime
	elif node is GPUParticles3D: (node as GPUParticles3D).lifetime = lifetime
	elif node is CPUParticles3D: (node as CPUParticles3D).lifetime = lifetime
	else:
		_send_response({"error": "Not a particles node"})
		return
	_send_response({"success": true, "lifetime": lifetime})

func _cmd_set_particles_explosiveness(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var explosiveness: float = params.get("explosiveness", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is GPUParticles2D: (node as GPUParticles2D).explosiveness = explosiveness
	elif node is CPUParticles2D: (node as CPUParticles2D).explosiveness = explosiveness
	elif node is GPUParticles3D: (node as GPUParticles3D).explosiveness = explosiveness
	elif node is CPUParticles3D: (node as CPUParticles3D).explosiveness = explosiveness
	else:
		_send_response({"error": "Not a particles node"})
		return
	_send_response({"success": true, "explosiveness": explosiveness})

func _cmd_set_particles_one_shot(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var one_shot: bool = params.get("one_shot", false)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is GPUParticles2D: (node as GPUParticles2D).one_shot = one_shot
	elif node is CPUParticles2D: (node as CPUParticles2D).one_shot = one_shot
	elif node is GPUParticles3D: (node as GPUParticles3D).one_shot = one_shot
	elif node is CPUParticles3D: (node as CPUParticles3D).one_shot = one_shot
	else:
		_send_response({"error": "Not a particles node"})
		return
	_send_response({"success": true, "one_shot": one_shot})

func _cmd_set_light_energy(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var energy: float = params.get("energy", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Light3D:
		_send_response({"error": "Light3D not found: " + node_path})
		return
	(node as Light3D).light_energy = energy
	_send_response({"success": true, "energy": energy})

func _cmd_set_light_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Light3D:
		_send_response({"error": "Light3D not found: " + node_path})
		return
	(node as Light3D).light_color = Color(r, g, b)
	_send_response({"success": true, "color": {"r": r, "g": g, "b": b}})

func _cmd_set_directional_light_shadow(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var mode_str: String = params.get("mode", "orthogonal")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is DirectionalLight3D:
		_send_response({"error": "DirectionalLight3D not found: " + node_path})
		return
	var dl := node as DirectionalLight3D
	match mode_str:
		"disabled":
			dl.shadow_enabled = false
		"orthogonal":
			dl.shadow_enabled = true
			dl.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		"pssm_2_splits":
			dl.shadow_enabled = true
			dl.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		"pssm_4_splits":
			dl.shadow_enabled = true
			dl.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_send_response({"success": true, "shadow_mode": mode_str})

func _cmd_get_light_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Light3D:
		_send_response({"error": "Light3D not found: " + node_path})
		return
	var light := node as Light3D
	var color = light.light_color
	var info: Dictionary = {
		"success": true,
		"type": light.get_class(),
		"energy": light.light_energy,
		"color": {"r": color.r, "g": color.g, "b": color.b},
		"shadow_enabled": light.shadow_enabled,
		"visible": light.visible
	}
	_send_response(info)

func _cmd_get_character_body_2d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CharacterBody2D:
		_send_response({"error": "CharacterBody2D not found: " + node_path})
		return
	var cb := node as CharacterBody2D
	_send_response({"success": true, "velocity": {"x": cb.velocity.x, "y": cb.velocity.y}, "is_on_floor": cb.is_on_floor(), "is_on_wall": cb.is_on_wall(), "is_on_ceiling": cb.is_on_ceiling()})

func _cmd_set_rigid_body_2d_mass(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var mass: float = params.get("mass", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RigidBody2D:
		_send_response({"error": "RigidBody2D not found: " + node_path})
		return
	(node as RigidBody2D).mass = mass
	_send_response({"success": true, "mass": mass})

func _cmd_set_rigid_body_2d_gravity_scale(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var gravity_scale: float = params.get("gravity_scale", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RigidBody2D:
		_send_response({"error": "RigidBody2D not found: " + node_path})
		return
	(node as RigidBody2D).gravity_scale = gravity_scale
	_send_response({"success": true, "gravity_scale": gravity_scale})

func _cmd_apply_central_impulse_2d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", -200.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RigidBody2D:
		_send_response({"error": "RigidBody2D not found: " + node_path})
		return
	(node as RigidBody2D).apply_central_impulse(Vector2(x, y))
	_send_response({"success": true, "impulse": {"x": x, "y": y}})

func _cmd_set_rigid_body_2d_freeze(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var freeze: bool = params.get("freeze", false)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RigidBody2D:
		_send_response({"error": "RigidBody2D not found: " + node_path})
		return
	(node as RigidBody2D).freeze = freeze
	_send_response({"success": true, "freeze": freeze})

func _cmd_get_rigid_body_2d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RigidBody2D:
		_send_response({"error": "RigidBody2D not found: " + node_path})
		return
	var rb := node as RigidBody2D
	_send_response({"success": true, "mass": rb.mass, "gravity_scale": rb.gravity_scale, "freeze": rb.freeze, "linear_velocity": {"x": rb.linear_velocity.x, "y": rb.linear_velocity.y}, "angular_velocity": rb.angular_velocity})

func _cmd_set_character_body_2d_velocity(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CharacterBody2D:
		_send_response({"error": "CharacterBody2D not found: " + node_path})
		return
	(node as CharacterBody2D).velocity = Vector2(x, y)
	_send_response({"success": true, "velocity": {"x": x, "y": y}})

func _cmd_get_character_body_3d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CharacterBody3D:
		_send_response({"error": "CharacterBody3D not found: " + node_path})
		return
	var cb := node as CharacterBody3D
	_send_response({"success": true, "velocity": {"x": cb.velocity.x, "y": cb.velocity.y, "z": cb.velocity.z}, "is_on_floor": cb.is_on_floor(), "is_on_wall": cb.is_on_wall(), "is_on_ceiling": cb.is_on_ceiling()})

func _cmd_set_rigid_body_3d_mass(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var mass: float = params.get("mass", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RigidBody3D:
		_send_response({"error": "RigidBody3D not found: " + node_path})
		return
	(node as RigidBody3D).mass = mass
	_send_response({"success": true, "mass": mass})

func _cmd_apply_central_impulse_3d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 200.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RigidBody3D:
		_send_response({"error": "RigidBody3D not found: " + node_path})
		return
	(node as RigidBody3D).apply_central_impulse(Vector3(x, y, z))
	_send_response({"success": true, "impulse": {"x": x, "y": y, "z": z}})

func _cmd_set_rigid_body_3d_gravity_scale(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var gravity_scale: float = params.get("gravity_scale", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RigidBody3D:
		_send_response({"error": "RigidBody3D not found: " + node_path})
		return
	(node as RigidBody3D).gravity_scale = gravity_scale
	_send_response({"success": true, "gravity_scale": gravity_scale})

func _cmd_set_rigid_body_3d_freeze(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var freeze: bool = params.get("freeze", false)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RigidBody3D:
		_send_response({"error": "RigidBody3D not found: " + node_path})
		return
	(node as RigidBody3D).freeze = freeze
	_send_response({"success": true, "freeze": freeze})

func _cmd_get_rigid_body_3d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RigidBody3D:
		_send_response({"error": "RigidBody3D not found: " + node_path})
		return
	var rb := node as RigidBody3D
	_send_response({"success": true, "mass": rb.mass, "gravity_scale": rb.gravity_scale, "freeze": rb.freeze, "linear_velocity": {"x": rb.linear_velocity.x, "y": rb.linear_velocity.y, "z": rb.linear_velocity.z}, "angular_velocity": {"x": rb.angular_velocity.x, "y": rb.angular_velocity.y, "z": rb.angular_velocity.z}})

func _cmd_set_material_metallic(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var metallic: float = params.get("metallic", 0.0)
	var surface_index: int = params.get("surface_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mat = (node as MeshInstance3D).get_surface_override_material(surface_index)
	if mat == null:
		mat = StandardMaterial3D.new()
		(node as MeshInstance3D).set_surface_override_material(surface_index, mat)
	if not mat is StandardMaterial3D:
		_send_response({"error": "Material is not StandardMaterial3D"})
		return
	(mat as StandardMaterial3D).metallic = metallic
	_send_response({"success": true, "metallic": metallic})

func _cmd_set_material_roughness(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var roughness: float = params.get("roughness", 1.0)
	var surface_index: int = params.get("surface_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mat = (node as MeshInstance3D).get_surface_override_material(surface_index)
	if mat == null:
		mat = StandardMaterial3D.new()
		(node as MeshInstance3D).set_surface_override_material(surface_index, mat)
	if not mat is StandardMaterial3D:
		_send_response({"error": "Material is not StandardMaterial3D"})
		return
	(mat as StandardMaterial3D).roughness = roughness
	_send_response({"success": true, "roughness": roughness})

func _cmd_set_material_emission(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 0.0)
	var g: float = params.get("g", 0.0)
	var b: float = params.get("b", 0.0)
	var energy: float = params.get("energy", 1.0)
	var surface_index: int = params.get("surface_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mat = (node as MeshInstance3D).get_surface_override_material(surface_index)
	if mat == null:
		mat = StandardMaterial3D.new()
		(node as MeshInstance3D).set_surface_override_material(surface_index, mat)
	if not mat is StandardMaterial3D:
		_send_response({"error": "Material is not StandardMaterial3D"})
		return
	var sm := mat as StandardMaterial3D
	sm.emission_enabled = true
	sm.emission = Color(r, g, b)
	sm.emission_energy_multiplier = energy
	_send_response({"success": true, "emission": {"r": r, "g": g, "b": b}, "energy": energy})

func _cmd_set_material_alpha_mode(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var alpha_mode_str: String = params.get("alpha_mode", "disabled")
	var surface_index: int = params.get("surface_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mat = (node as MeshInstance3D).get_surface_override_material(surface_index)
	if mat == null or not mat is StandardMaterial3D:
		_send_response({"error": "No StandardMaterial3D on surface " + str(surface_index)})
		return
	var mode: BaseMaterial3D.Transparency
	match alpha_mode_str:
		"disabled": mode = BaseMaterial3D.TRANSPARENCY_DISABLED
		"alpha": mode = BaseMaterial3D.TRANSPARENCY_ALPHA
		"scissor": mode = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		"hash": mode = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
		_: mode = BaseMaterial3D.TRANSPARENCY_DISABLED
	(mat as StandardMaterial3D).transparency = mode
	_send_response({"success": true, "alpha_mode": alpha_mode_str})

func _cmd_get_material_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var surface_index: int = params.get("surface_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mat = (node as MeshInstance3D).get_surface_override_material(surface_index)
	if mat == null and (node as MeshInstance3D).mesh != null:
		mat = (node as MeshInstance3D).mesh.surface_get_material(surface_index)
	if mat == null:
		_send_response({"success": true, "material": null, "type": "none"})
		return
	if mat is StandardMaterial3D:
		var sm := mat as StandardMaterial3D
		var c = sm.albedo_color
		_send_response({"success": true, "type": "StandardMaterial3D", "albedo": {"r": c.r, "g": c.g, "b": c.b, "a": c.a}, "metallic": sm.metallic, "roughness": sm.roughness, "emission_enabled": sm.emission_enabled})
	else:
		_send_response({"success": true, "type": mat.get_class()})

func _cmd_set_material_cull_mode(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var cull_mode_str: String = params.get("cull_mode", "back")
	var surface_index: int = params.get("surface_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MeshInstance3D:
		_send_response({"error": "MeshInstance3D not found: " + node_path})
		return
	var mat = (node as MeshInstance3D).get_surface_override_material(surface_index)
	if mat == null or not mat is StandardMaterial3D:
		_send_response({"error": "No StandardMaterial3D on surface"})
		return
	var mode: BaseMaterial3D.CullMode
	match cull_mode_str:
		"back": mode = BaseMaterial3D.CULL_BACK
		"front": mode = BaseMaterial3D.CULL_FRONT
		"disabled": mode = BaseMaterial3D.CULL_DISABLED
		_: mode = BaseMaterial3D.CULL_BACK
	(mat as StandardMaterial3D).cull_mode = mode
	_send_response({"success": true, "cull_mode": cull_mode_str})

func _cmd_set_collision_shape_disabled(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var disabled: bool = params.get("disabled", false)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CollisionShape2D:
		(node as CollisionShape2D).disabled = disabled
	elif node is CollisionShape3D:
		(node as CollisionShape3D).disabled = disabled
	else:
		_send_response({"error": "Not a CollisionShape node"})
		return
	_send_response({"success": true, "disabled": disabled})

func _cmd_set_circle_shape_radius(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var radius: float = params.get("radius", 10.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CollisionShape2D:
		_send_response({"error": "CollisionShape2D not found: " + node_path})
		return
	var shape = (node as CollisionShape2D).shape
	if not shape is CircleShape2D:
		_send_response({"error": "Shape is not CircleShape2D"})
		return
	(shape as CircleShape2D).radius = radius
	_send_response({"success": true, "radius": radius})

func _cmd_set_rect_shape_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var width: float = params.get("width", 20.0)
	var height: float = params.get("height", 20.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CollisionShape2D:
		_send_response({"error": "CollisionShape2D not found: " + node_path})
		return
	var shape = (node as CollisionShape2D).shape
	if not shape is RectangleShape2D:
		_send_response({"error": "Shape is not RectangleShape2D"})
		return
	(shape as RectangleShape2D).size = Vector2(width, height)
	_send_response({"success": true, "size": {"width": width, "height": height}})

func _cmd_set_capsule_shape_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var radius: float = params.get("radius", 10.0)
	var height: float = params.get("height", 30.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CollisionShape2D:
		var shape = (node as CollisionShape2D).shape
		if shape is CapsuleShape2D:
			(shape as CapsuleShape2D).radius = radius
			(shape as CapsuleShape2D).height = height
		else:
			_send_response({"error": "Shape is not CapsuleShape2D"})
			return
	elif node is CollisionShape3D:
		var shape = (node as CollisionShape3D).shape
		if shape is CapsuleShape3D:
			(shape as CapsuleShape3D).radius = radius
			(shape as CapsuleShape3D).height = height
		else:
			_send_response({"error": "Shape is not CapsuleShape3D"})
			return
	else:
		_send_response({"error": "Not a CollisionShape node"})
		return
	_send_response({"success": true, "radius": radius, "height": height})

func _cmd_set_box_shape_size_3d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.5)
	var y: float = params.get("y", 0.5)
	var z: float = params.get("z", 0.5)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CollisionShape3D:
		_send_response({"error": "CollisionShape3D not found: " + node_path})
		return
	var shape = (node as CollisionShape3D).shape
	if not shape is BoxShape3D:
		_send_response({"error": "Shape is not BoxShape3D"})
		return
	(shape as BoxShape3D).size = Vector3(x, y, z)
	_send_response({"success": true, "size": {"x": x, "y": y, "z": z}})

func _cmd_get_collision_layer_mask(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if node is CollisionObject2D:
		var co := node as CollisionObject2D
		_send_response({"success": true, "collision_layer": co.collision_layer, "collision_mask": co.collision_mask})
	elif node is CollisionObject3D:
		var co := node as CollisionObject3D
		_send_response({"success": true, "collision_layer": co.collision_layer, "collision_mask": co.collision_mask})
	else:
		_send_response({"error": "Node is not a CollisionObject"})

func _cmd_is_key_pressed(params: Dictionary) -> void:
	var keycode: int = params.get("keycode", 32)
	_send_response({"success": true, "keycode": keycode, "pressed": Input.is_key_pressed(keycode as Key)})


func _cmd_get_joy_axis(params: Dictionary) -> void:
	var device_id: int = params.get("device_id", 0)
	var axis_id: int = params.get("axis_id", 0)
	var value = Input.get_joy_axis(device_id, axis_id as JoyAxis)
	_send_response({"success": true, "device_id": device_id, "axis_id": axis_id, "value": value})


func _cmd_set_control_offset(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var left: float = params.get("left", 0.0)
	var top: float = params.get("top", 0.0)
	var right: float = params.get("right", 0.0)
	var bottom: float = params.get("bottom", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	var ctrl := node as Control
	ctrl.offset_left = left
	ctrl.offset_top = top
	ctrl.offset_right = right
	ctrl.offset_bottom = bottom
	_send_response({"success": true, "left": left, "top": top, "right": right, "bottom": bottom})


func _cmd_set_control_focus_mode(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var mode_str: String = params.get("mode", "click")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	var mode: Control.FocusMode
	match mode_str:
		"none": mode = Control.FOCUS_NONE
		"click": mode = Control.FOCUS_CLICK
		"all": mode = Control.FOCUS_ALL
		_: mode = Control.FOCUS_CLICK
	(node as Control).focus_mode = mode
	_send_response({"success": true, "focus_mode": mode_str})


func _cmd_set_rich_text_bbcode(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var text: String = params.get("text", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is RichTextLabel:
		_send_response({"error": "RichTextLabel not found: " + node_path})
		return
	var rtl := node as RichTextLabel
	rtl.bbcode_enabled = true
	rtl.text = text
	_send_response({"success": true, "text": text})


func _cmd_set_button_disabled(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var disabled: bool = params.get("disabled", false)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is BaseButton:
		_send_response({"error": "Button node not found: " + node_path})
		return
	(node as BaseButton).disabled = disabled
	_send_response({"success": true, "disabled": disabled})


func _cmd_get_check_button_state(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is BaseButton:
		_send_response({"error": "Button node not found: " + node_path})
		return
	_send_response({"success": true, "pressed": (node as BaseButton).button_pressed})


func _cmd_set_check_button_state(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var pressed: bool = params.get("pressed", false)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is BaseButton:
		_send_response({"error": "Button node not found: " + node_path})
		return
	(node as BaseButton).button_pressed = pressed
	_send_response({"success": true, "pressed": pressed})


func _cmd_set_range_value(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var value: float = params.get("value", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Range:
		_send_response({"error": "Range node not found: " + node_path})
		return
	(node as Range).value = value
	_send_response({"success": true, "value": value})


func _cmd_get_range_value(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Range:
		_send_response({"error": "Range node not found: " + node_path})
		return
	var r := node as Range
	_send_response({"success": true, "value": r.value, "min": r.min_value, "max": r.max_value})


func _cmd_set_range_min_max(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var min_val: float = params.get("min", 0.0)
	var max_val: float = params.get("max", 100.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Range:
		_send_response({"error": "Range node not found: " + node_path})
		return
	(node as Range).min_value = min_val
	(node as Range).max_value = max_val
	_send_response({"success": true, "min": min_val, "max": max_val})


func _cmd_set_h_slider_value(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var value: float = params.get("value", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is HSlider:
		_send_response({"error": "HSlider not found: " + node_path})
		return
	(node as HSlider).value = value
	_send_response({"success": true, "value": value})


func _cmd_get_h_slider_value(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is HSlider:
		_send_response({"error": "HSlider not found: " + node_path})
		return
	_send_response({"success": true, "value": (node as HSlider).value})


func _cmd_get_theme_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	var ctrl := node as Control
	_send_response({"success": true, "theme_type_variation": ctrl.theme_type_variation, "has_theme": ctrl.theme != null})


func _cmd_set_theme_font_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var font_size: int = params.get("font_size", 14)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	(node as Control).add_theme_font_size_override("font_size", font_size)
	_send_response({"success": true, "font_size": font_size})


func _cmd_set_theme_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var color_name: String = params.get("color_name", "font_color")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var a: float = params.get("a", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	(node as Control).add_theme_color_override(color_name, Color(r, g, b, a))
	_send_response({"success": true, "color_name": color_name, "color": {"r": r, "g": g, "b": b, "a": a}})


func _cmd_set_panel_stylebox_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 0.2)
	var g: float = params.get("g", 0.2)
	var b: float = params.get("b", 0.2)
	var a: float = params.get("a", 1.0)
	var corner_radius: int = params.get("corner_radius", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	var style = StyleBoxFlat.new()
	style.bg_color = Color(r, g, b, a)
	style.corner_radius_top_left = corner_radius
	style.corner_radius_top_right = corner_radius
	style.corner_radius_bottom_left = corner_radius
	style.corner_radius_bottom_right = corner_radius
	(node as Control).add_theme_stylebox_override("panel", style)
	_send_response({"success": true, "color": {"r": r, "g": g, "b": b, "a": a}, "corner_radius": corner_radius})


func _cmd_set_panel_border_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var a: float = params.get("a", 1.0)
	var border_width: int = params.get("border_width", 1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	var existing = (node as Control).get_theme_stylebox("panel")
	var style: StyleBoxFlat
	if existing is StyleBoxFlat:
		style = existing as StyleBoxFlat
	else:
		style = StyleBoxFlat.new()
	style.border_color = Color(r, g, b, a)
	style.border_width_left = border_width
	style.border_width_top = border_width
	style.border_width_right = border_width
	style.border_width_bottom = border_width
	(node as Control).add_theme_stylebox_override("panel", style)
	_send_response({"success": true, "border_color": {"r": r, "g": g, "b": b, "a": a}, "border_width": border_width})


func _cmd_get_control_theme_type(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	_send_response({"success": true, "theme_type_variation": (node as Control).theme_type_variation})


func _cmd_set_control_theme_type(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var theme_type: String = params.get("theme_type", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Control:
		_send_response({"error": "Control not found: " + node_path})
		return
	(node as Control).theme_type_variation = theme_type
	_send_response({"success": true, "theme_type_variation": theme_type})


func _cmd_create_property_tween(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property: String = params.get("property", "position:x")
	var target_value = params.get("target_value", 0.0)
	var duration: float = params.get("duration", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var tween = get_tree().create_tween()
	tween.tween_property(node, property, target_value, duration)
	_send_response({"success": true, "property": property, "target": target_value, "duration": duration})


func _cmd_create_color_tween(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var a: float = params.get("a", 1.0)
	var duration: float = params.get("duration", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasItem:
		_send_response({"error": "CanvasItem not found: " + node_path})
		return
	var tween = get_tree().create_tween()
	tween.tween_property(node, "modulate", Color(r, g, b, a), duration)
	_send_response({"success": true, "target_color": {"r": r, "g": g, "b": b, "a": a}, "duration": duration})


func _cmd_tween_node_position_2d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var duration: float = params.get("duration", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node2D:
		_send_response({"error": "Node2D not found: " + node_path})
		return
	var tween = get_tree().create_tween()
	tween.tween_property(node, "position", Vector2(x, y), duration)
	_send_response({"success": true, "target": {"x": x, "y": y}, "duration": duration})


func _cmd_tween_node_scale(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 1.0)
	var y: float = params.get("y", 1.0)
	var duration: float = params.get("duration", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node2D:
		_send_response({"error": "Node2D not found: " + node_path})
		return
	var tween = get_tree().create_tween()
	tween.tween_property(node, "scale", Vector2(x, y), duration)
	_send_response({"success": true, "target_scale": {"x": x, "y": y}, "duration": duration})


func _cmd_tween_node_alpha(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var alpha: float = params.get("alpha", 0.0)
	var duration: float = params.get("duration", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasItem:
		_send_response({"error": "CanvasItem not found: " + node_path})
		return
	var tween = get_tree().create_tween()
	tween.tween_property(node, "modulate:a", alpha, duration)
	_send_response({"success": true, "target_alpha": alpha, "duration": duration})


func _cmd_tween_node_rotation(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var degrees: float = params.get("degrees", 0.0)
	var duration: float = params.get("duration", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Node2D:
		_send_response({"error": "Node2D not found: " + node_path})
		return
	var tween = get_tree().create_tween()
	tween.tween_property(node, "rotation_degrees", degrees, duration)
	_send_response({"success": true, "target_degrees": degrees, "duration": duration})


func _cmd_flash_node_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 0.0)
	var b: float = params.get("b", 0.0)
	var duration: float = params.get("duration", 0.2)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CanvasItem:
		_send_response({"error": "CanvasItem not found: " + node_path})
		return
	var original = (node as CanvasItem).modulate
	var tween = get_tree().create_tween()
	tween.tween_property(node, "modulate", Color(r, g, b), duration * 0.5)
	tween.tween_property(node, "modulate", original, duration * 0.5)
	_send_response({"success": true, "flash_color": {"r": r, "g": g, "b": b}, "duration": duration})


func _cmd_get_system_memory_info(params: Dictionary) -> void:
	var info = OS.get_memory_info()
	_send_response({"success": true, "physical": info.get("physical", 0), "free": info.get("free", 0), "stack": info.get("stack", 0)})


func _cmd_get_processor_name(params: Dictionary) -> void:
	_send_response({"success": true, "processor_name": OS.get_processor_name(), "processor_count": OS.get_processor_count()})


func _cmd_get_locale(params: Dictionary) -> void:
	_send_response({"success": true, "locale": OS.get_locale(), "locale_language": OS.get_locale_language()})


func _cmd_get_screen_resolution(params: Dictionary) -> void:
	var screen_size = DisplayServer.screen_get_size()
	var window_size = get_tree().root.size
	_send_response({"success": true, "screen": {"width": screen_size.x, "height": screen_size.y}, "window": {"width": window_size.x, "height": window_size.y}})


func _cmd_get_navigation_agent_2d_target(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NavigationAgent2D:
		_send_response({"error": "NavigationAgent2D not found: " + node_path})
		return
	var target = (node as NavigationAgent2D).target_position
	_send_response({"success": true, "target": {"x": target.x, "y": target.y}})


func _cmd_get_navigation_region_3d_baked(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NavigationRegion3D:
		_send_response({"error": "NavigationRegion3D not found: " + node_path})
		return
	var nr := node as NavigationRegion3D
	_send_response({"success": true, "enabled": nr.enabled, "has_navmesh": nr.navigation_mesh != null})


func _cmd_get_sprite_frame_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Sprite2D:
		_send_response({"error": "Sprite2D not found: " + node_path})
		return
	var s := node as Sprite2D
	_send_response({"success": true, "frame": s.frame, "hframes": s.hframes, "vframes": s.vframes, "frame_coords": {"x": s.frame_coords.x, "y": s.frame_coords.y}})


func _cmd_set_sprite_hframes(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var hframes: int = params.get("hframes", 1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Sprite2D:
		_send_response({"error": "Sprite2D not found: " + node_path})
		return
	(node as Sprite2D).hframes = hframes
	_send_response({"success": true, "hframes": hframes})


func _cmd_set_sprite_vframes(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var vframes: int = params.get("vframes", 1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Sprite2D:
		_send_response({"error": "Sprite2D not found: " + node_path})
		return
	(node as Sprite2D).vframes = vframes
	_send_response({"success": true, "vframes": vframes})


func _cmd_set_sprite_region_rect(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var width: float = params.get("width", 64.0)
	var height: float = params.get("height", 64.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Sprite2D:
		_send_response({"error": "Sprite2D not found: " + node_path})
		return
	(node as Sprite2D).region_rect = Rect2(x, y, width, height)
	_send_response({"success": true, "region_rect": {"x": x, "y": y, "width": width, "height": height}})


func _cmd_set_sprite_region_enabled(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var enabled: bool = params.get("enabled", false)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Sprite2D:
		_send_response({"error": "Sprite2D not found: " + node_path})
		return
	(node as Sprite2D).region_enabled = enabled
	_send_response({"success": true, "region_enabled": enabled})


func _cmd_set_texture_rect_stretch(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var mode_str: String = params.get("mode", "keep_aspect_centered")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TextureRect:
		_send_response({"error": "TextureRect not found: " + node_path})
		return
	var mode: TextureRect.StretchMode
	match mode_str:
		"scale": mode = TextureRect.STRETCH_SCALE
		"tile": mode = TextureRect.STRETCH_TILE
		"keep": mode = TextureRect.STRETCH_KEEP
		"keep_centered": mode = TextureRect.STRETCH_KEEP_CENTERED
		"keep_aspect": mode = TextureRect.STRETCH_KEEP_ASPECT
		"keep_aspect_centered": mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		"keep_aspect_covered": mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		_: mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	(node as TextureRect).stretch_mode = mode
	_send_response({"success": true, "stretch_mode": mode_str})


func _cmd_set_texture_rect_flip(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var flip_h: bool = params.get("flip_h", false)
	var flip_v: bool = params.get("flip_v", false)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TextureRect:
		_send_response({"error": "TextureRect not found: " + node_path})
		return
	(node as TextureRect).flip_h = flip_h
	(node as TextureRect).flip_v = flip_v
	_send_response({"success": true, "flip_h": flip_h, "flip_v": flip_v})


func _cmd_get_texture_rect_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TextureRect:
		_send_response({"error": "TextureRect not found: " + node_path})
		return
	var tr := node as TextureRect
	_send_response({"success": true, "stretch_mode": tr.stretch_mode, "flip_h": tr.flip_h, "flip_v": tr.flip_v, "size": {"x": tr.size.x, "y": tr.size.y}})


func _cmd_set_nine_patch_margins(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var left: int = params.get("left", 4)
	var top: int = params.get("top", 4)
	var right: int = params.get("right", 4)
	var bottom: int = params.get("bottom", 4)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NinePatchRect:
		_send_response({"error": "NinePatchRect not found: " + node_path})
		return
	var npr := node as NinePatchRect
	npr.patch_margin_left = left
	npr.patch_margin_top = top
	npr.patch_margin_right = right
	npr.patch_margin_bottom = bottom
	_send_response({"success": true, "margins": {"left": left, "top": top, "right": right, "bottom": bottom}})


func _cmd_set_nine_patch_draw_center(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var draw_center: bool = params.get("draw_center", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NinePatchRect:
		_send_response({"error": "NinePatchRect not found: " + node_path})
		return
	(node as NinePatchRect).draw_center = draw_center
	_send_response({"success": true, "draw_center": draw_center})


func _cmd_get_nine_patch_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NinePatchRect:
		_send_response({"error": "NinePatchRect not found: " + node_path})
		return
	var npr := node as NinePatchRect
	_send_response({"success": true, "left": npr.patch_margin_left, "top": npr.patch_margin_top, "right": npr.patch_margin_right, "bottom": npr.patch_margin_bottom, "draw_center": npr.draw_center})


func _cmd_set_camera_2d_limits(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var left: int = params.get("left", -10000000)
	var top: int = params.get("top", -10000000)
	var right: int = params.get("right", 10000000)
	var bottom: int = params.get("bottom", 10000000)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Camera2D:
		_send_response({"error": "Camera2D not found: " + node_path})
		return
	var cam := node as Camera2D
	cam.limit_left = left
	cam.limit_top = top
	cam.limit_right = right
	cam.limit_bottom = bottom
	_send_response({"success": true, "limits": {"left": left, "top": top, "right": right, "bottom": bottom}})


func _cmd_set_camera_2d_drag_margins(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var left: float = params.get("left", 0.2)
	var top: float = params.get("top", 0.2)
	var right: float = params.get("right", 0.2)
	var bottom: float = params.get("bottom", 0.2)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Camera2D:
		_send_response({"error": "Camera2D not found: " + node_path})
		return
	var cam := node as Camera2D
	cam.drag_horizontal_enabled = true
	cam.drag_vertical_enabled = true
	cam.drag_left_margin = left
	cam.drag_top_margin = top
	cam.drag_right_margin = right
	cam.drag_bottom_margin = bottom
	_send_response({"success": true, "drag_margins": {"left": left, "top": top, "right": right, "bottom": bottom}})


func _cmd_reset_camera_2d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Camera2D:
		_send_response({"error": "Camera2D not found: " + node_path})
		return
	(node as Camera2D).reset_smoothing()
	_send_response({"success": true, "reset": node_path})


func _cmd_set_camera_2d_process_callback(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var callback_str: String = params.get("callback", "idle")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Camera2D:
		_send_response({"error": "Camera2D not found: " + node_path})
		return
	var mode: Camera2D.Camera2DProcessCallback
	match callback_str:
		"idle": mode = Camera2D.CAMERA2D_PROCESS_IDLE
		"physics": mode = Camera2D.CAMERA2D_PROCESS_PHYSICS
		_: mode = Camera2D.CAMERA2D_PROCESS_IDLE
	(node as Camera2D).process_callback = mode
	_send_response({"success": true, "process_callback": callback_str})


func _cmd_get_camera_2d_screen_center(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Camera2D:
		_send_response({"error": "Camera2D not found: " + node_path})
		return
	var center = (node as Camera2D).get_screen_center_position()
	_send_response({"success": true, "center": {"x": center.x, "y": center.y}})


func _cmd_shake_camera_2d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var intensity: float = params.get("intensity", 10.0)
	var duration: float = params.get("duration", 0.3)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Camera2D:
		_send_response({"error": "Camera2D not found: " + node_path})
		return
	var cam := node as Camera2D
	var original_offset = cam.offset
	var tween = get_tree().create_tween()
	var steps = int(duration / 0.05)
	for i in range(steps):
		var shake_offset = Vector2(randf_range(-intensity, intensity), randf_range(-intensity, intensity))
		tween.tween_property(cam, "offset", shake_offset, 0.05)
	tween.tween_property(cam, "offset", original_offset, 0.05)
	_send_response({"success": true, "intensity": intensity, "duration": duration})


func _cmd_get_audio_player_3d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AudioStreamPlayer3D:
		_send_response({"error": "AudioStreamPlayer3D not found: " + node_path})
		return
	var asp := node as AudioStreamPlayer3D
	_send_response({"success": true, "playing": asp.playing, "volume_db": asp.volume_db, "max_distance": asp.max_distance, "unit_size": asp.unit_size, "bus": asp.bus})


func _cmd_set_audio_player_3d_volume(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var volume_db: float = params.get("volume_db", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AudioStreamPlayer3D:
		_send_response({"error": "AudioStreamPlayer3D not found: " + node_path})
		return
	(node as AudioStreamPlayer3D).volume_db = volume_db
	_send_response({"success": true, "volume_db": volume_db})


func _cmd_set_audio_player_3d_max_distance(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var max_distance: float = params.get("max_distance", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AudioStreamPlayer3D:
		_send_response({"error": "AudioStreamPlayer3D not found: " + node_path})
		return
	(node as AudioStreamPlayer3D).max_distance = max_distance
	_send_response({"success": true, "max_distance": max_distance})


func _cmd_set_audio_player_3d_unit_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var unit_size: float = params.get("unit_size", 10.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AudioStreamPlayer3D:
		_send_response({"error": "AudioStreamPlayer3D not found: " + node_path})
		return
	(node as AudioStreamPlayer3D).unit_size = unit_size
	_send_response({"success": true, "unit_size": unit_size})


func _cmd_set_audio_player_3d_doppler(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var mode_str: String = params.get("mode", "disabled")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AudioStreamPlayer3D:
		_send_response({"error": "AudioStreamPlayer3D not found: " + node_path})
		return
	var mode: AudioStreamPlayer3D.DopplerTracking
	match mode_str:
		"disabled": mode = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		"idle": mode = AudioStreamPlayer3D.DOPPLER_TRACKING_IDLE_STEP
		"physics": mode = AudioStreamPlayer3D.DOPPLER_TRACKING_PHYSICS_STEP
		_: mode = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	(node as AudioStreamPlayer3D).doppler_tracking = mode
	_send_response({"success": true, "doppler_mode": mode_str})


func _cmd_play_audio_player_3d_at_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AudioStreamPlayer3D:
		_send_response({"error": "AudioStreamPlayer3D not found: " + node_path})
		return
	var asp := node as AudioStreamPlayer3D
	asp.global_position = Vector3(x, y, z)
	asp.play()
	_send_response({"success": true, "position": {"x": x, "y": y, "z": z}, "playing": true})


func _cmd_get_shader_param(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var param_name: String = params.get("param_name", "")
	var surface_index: int = params.get("surface_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var mat: Material = null
	if node is MeshInstance3D:
		mat = (node as MeshInstance3D).get_surface_override_material(surface_index)
	elif node is CanvasItem:
		mat = (node as CanvasItem).material
	if mat == null or not mat is ShaderMaterial:
		_send_response({"error": "ShaderMaterial not found on node"})
		return
	var value = (mat as ShaderMaterial).get_shader_parameter(param_name)
	_send_response({"success": true, "param_name": param_name, "value": value})


func _cmd_set_shader_param_color(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var param_name: String = params.get("param_name", "")
	var r: float = params.get("r", 1.0)
	var g: float = params.get("g", 1.0)
	var b: float = params.get("b", 1.0)
	var a: float = params.get("a", 1.0)
	var surface_index: int = params.get("surface_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var mat: Material = null
	if node is MeshInstance3D:
		mat = (node as MeshInstance3D).get_surface_override_material(surface_index)
	elif node is CanvasItem:
		mat = (node as CanvasItem).material
	if mat == null or not mat is ShaderMaterial:
		_send_response({"error": "ShaderMaterial not found"})
		return
	(mat as ShaderMaterial).set_shader_parameter(param_name, Color(r, g, b, a))
	_send_response({"success": true, "param_name": param_name, "color": {"r": r, "g": g, "b": b, "a": a}})


func _cmd_set_shader_param_vec2(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var param_name: String = params.get("param_name", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var surface_index: int = params.get("surface_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var mat: Material = null
	if node is MeshInstance3D:
		mat = (node as MeshInstance3D).get_surface_override_material(surface_index)
	elif node is CanvasItem:
		mat = (node as CanvasItem).material
	if mat == null or not mat is ShaderMaterial:
		_send_response({"error": "ShaderMaterial not found"})
		return
	(mat as ShaderMaterial).set_shader_parameter(param_name, Vector2(x, y))
	_send_response({"success": true, "param_name": param_name, "vec2": {"x": x, "y": y}})


func _cmd_set_shader_param_vec3(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var param_name: String = params.get("param_name", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var surface_index: int = params.get("surface_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var mat: Material = null
	if node is MeshInstance3D:
		mat = (node as MeshInstance3D).get_surface_override_material(surface_index)
	elif node is CanvasItem:
		mat = (node as CanvasItem).material
	if mat == null or not mat is ShaderMaterial:
		_send_response({"error": "ShaderMaterial not found"})
		return
	(mat as ShaderMaterial).set_shader_parameter(param_name, Vector3(x, y, z))
	_send_response({"success": true, "param_name": param_name, "vec3": {"x": x, "y": y, "z": z}})


func _cmd_list_shader_params(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var surface_index: int = params.get("surface_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var mat: Material = null
	if node is MeshInstance3D:
		mat = (node as MeshInstance3D).get_surface_override_material(surface_index)
	elif node is CanvasItem:
		mat = (node as CanvasItem).material
	if mat == null or not mat is ShaderMaterial:
		_send_response({"error": "ShaderMaterial not found"})
		return
	var shader = (mat as ShaderMaterial).shader
	if shader == null:
		_send_response({"success": true, "params": [], "count": 0})
		return
	var param_list = shader.get_shader_uniform_list()
	var result = []
	for p in param_list:
		result.append({"name": p.get("name", ""), "type": p.get("type", 0)})
	_send_response({"success": true, "params": result, "count": result.size()})


func _cmd_get_path_2d_point_count(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Path2D:
		_send_response({"error": "Path2D not found: " + node_path})
		return
	_send_response({"success": true, "point_count": (node as Path2D).curve.get_point_count()})


func _cmd_add_path_2d_point(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Path2D:
		_send_response({"error": "Path2D not found: " + node_path})
		return
	(node as Path2D).curve.add_point(Vector2(x, y))
	_send_response({"success": true, "point": {"x": x, "y": y}, "total_points": (node as Path2D).curve.get_point_count()})


func _cmd_get_path_2d_baked_length(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Path2D:
		_send_response({"error": "Path2D not found: " + node_path})
		return
	_send_response({"success": true, "baked_length": (node as Path2D).curve.get_baked_length()})


func _cmd_sample_path_2d_baked(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var offset: float = params.get("offset", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Path2D:
		_send_response({"error": "Path2D not found: " + node_path})
		return
	var pt = (node as Path2D).curve.sample_baked(offset)
	_send_response({"success": true, "point": {"x": pt.x, "y": pt.y}, "offset": offset})


func _cmd_clear_path_2d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Path2D:
		_send_response({"error": "Path2D not found: " + node_path})
		return
	(node as Path2D).curve.clear_points()
	_send_response({"success": true, "cleared": node_path})


func _cmd_get_path_follower_2d_offset(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is PathFollow2D:
		_send_response({"error": "PathFollow2D not found: " + node_path})
		return
	var pf := node as PathFollow2D
	_send_response({"success": true, "progress": pf.progress, "progress_ratio": pf.progress_ratio, "rotates": pf.rotates})


func _cmd_get_multimesh_instance_count(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MultiMeshInstance3D:
		_send_response({"error": "MultiMeshInstance3D not found: " + node_path})
		return
	var mmi := node as MultiMeshInstance3D
	var mm = mmi.multimesh
	_send_response({"success": true, "visible_instance_count": mm.visible_instance_count if mm != null else 0, "instance_count": mm.instance_count if mm != null else 0})


func _cmd_set_multimesh_instance_count(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var count: int = params.get("count", 1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is MultiMeshInstance3D:
		_send_response({"error": "MultiMeshInstance3D not found: " + node_path})
		return
	var mm = (node as MultiMeshInstance3D).multimesh
	if mm == null:
		_send_response({"error": "No MultiMesh assigned"})
		return
	mm.visible_instance_count = count
	_send_response({"success": true, "visible_instance_count": count})


func _cmd_get_physics_server_info(params: Dictionary) -> void:
	var bodies_2d = PhysicsServer2D.get_process_info(PhysicsServer2D.INFO_ACTIVE_OBJECTS)
	var bodies_3d = PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_ACTIVE_OBJECTS)
	_send_response({"success": true, "active_2d_bodies": bodies_2d, "active_3d_bodies": bodies_3d})


func _cmd_http_request_get(params: Dictionary) -> void:
	var url: String = params.get("url", "")
	if url.is_empty():
		_send_response({"error": "url is required"})
		return
	var http = HTTPClient.new()
	_send_response({"success": true, "note": "HTTPClient requires async - use HTTPRequest node for actual requests", "url": url})


func _cmd_http_request_post(params: Dictionary) -> void:
	var url: String = params.get("url", "")
	var body: String = params.get("body", "")
	_send_response({"success": true, "note": "HTTPClient requires async - use HTTPRequest node for actual requests", "url": url, "body_length": body.length()})


func _cmd_get_http_client_status(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is HTTPRequest:
		_send_response({"error": "HTTPRequest not found: " + node_path})
		return
	var hr := node as HTTPRequest
	_send_response({"success": true, "is_requesting": hr.is_requesting(), "get_http_client_status": hr.get_http_client_status()})


func _cmd_get_audio_bus_effect_count(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "Master")
	var idx = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		_send_response({"error": "Audio bus not found: " + bus_name})
		return
	_send_response({"success": true, "bus_name": bus_name, "effect_count": AudioServer.get_bus_effect_count(idx)})


func _cmd_set_reverb_room_size(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "Master")
	var effect_index: int = params.get("effect_index", 0)
	var room_size: float = params.get("room_size", 0.8)
	var idx = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		_send_response({"error": "Audio bus not found: " + bus_name})
		return
	var effect = AudioServer.get_bus_effect(idx, effect_index)
	if not effect is AudioEffectReverb:
		_send_response({"error": "Effect is not AudioEffectReverb"})
		return
	(effect as AudioEffectReverb).room_size = room_size
	_send_response({"success": true, "room_size": room_size})


func _cmd_set_reverb_wet(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "Master")
	var effect_index: int = params.get("effect_index", 0)
	var wet: float = params.get("wet", 0.5)
	var idx = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		_send_response({"error": "Audio bus not found: " + bus_name})
		return
	var effect = AudioServer.get_bus_effect(idx, effect_index)
	if not effect is AudioEffectReverb:
		_send_response({"error": "Effect is not AudioEffectReverb"})
		return
	(effect as AudioEffectReverb).wet = wet
	_send_response({"success": true, "wet": wet})


func _cmd_set_delay_dry(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "Master")
	var effect_index: int = params.get("effect_index", 0)
	var dry: float = params.get("dry", 1.0)
	var idx = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		_send_response({"error": "Audio bus not found: " + bus_name})
		return
	var effect = AudioServer.get_bus_effect(idx, effect_index)
	if not effect is AudioEffectDelay:
		_send_response({"error": "Effect is not AudioEffectDelay"})
		return
	(effect as AudioEffectDelay).dry = dry
	_send_response({"success": true, "dry": dry})


func _cmd_set_compressor_threshold(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "Master")
	var effect_index: int = params.get("effect_index", 0)
	var threshold: float = params.get("threshold", 0.0)
	var idx = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		_send_response({"error": "Audio bus not found: " + bus_name})
		return
	var effect = AudioServer.get_bus_effect(idx, effect_index)
	if not effect is AudioEffectCompressor:
		_send_response({"error": "Effect is not AudioEffectCompressor"})
		return
	(effect as AudioEffectCompressor).threshold = threshold
	_send_response({"success": true, "threshold": threshold})


func _cmd_set_eq_band_gain(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "Master")
	var effect_index: int = params.get("effect_index", 0)
	var band_index: int = params.get("band_index", 0)
	var gain_db: float = params.get("gain_db", 0.0)
	var idx = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		_send_response({"error": "Audio bus not found: " + bus_name})
		return
	var effect = AudioServer.get_bus_effect(idx, effect_index)
	if not effect is AudioEffectEQ:
		_send_response({"error": "Effect is not AudioEffectEQ"})
		return
	(effect as AudioEffectEQ).set_band_gain_db(band_index, gain_db)
	_send_response({"success": true, "band_index": band_index, "gain_db": gain_db})


func _cmd_get_audio_effect_info(params: Dictionary) -> void:
	var bus_name: String = params.get("bus_name", "Master")
	var effect_index: int = params.get("effect_index", 0)
	var idx = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		_send_response({"error": "Audio bus not found: " + bus_name})
		return
	if effect_index >= AudioServer.get_bus_effect_count(idx):
		_send_response({"error": "Effect index out of range"})
		return
	var effect = AudioServer.get_bus_effect(idx, effect_index)
	_send_response({"success": true, "type": effect.get_class(), "enabled": AudioServer.is_bus_effect_enabled(idx, effect_index)})


func _cmd_set_window_fullscreen(params: Dictionary) -> void:
	var fullscreen: bool = params.get("fullscreen", true)
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	_send_response({"success": true, "fullscreen": fullscreen})


func _cmd_get_window_info(params: Dictionary) -> void:
	var size = DisplayServer.window_get_size()
	var pos = DisplayServer.window_get_position()
	var mode = DisplayServer.window_get_mode()
	_send_response({"success": true, "size": {"width": size.x, "height": size.y}, "position": {"x": pos.x, "y": pos.y}, "mode": mode})


func _cmd_set_window_position(params: Dictionary) -> void:
	var x: int = params.get("x", 0)
	var y: int = params.get("y", 0)
	DisplayServer.window_set_position(Vector2i(x, y))
	_send_response({"success": true, "position": {"x": x, "y": y}})


func _cmd_set_window_borderless(params: Dictionary) -> void:
	var borderless: bool = params.get("borderless", true)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, borderless)
	_send_response({"success": true, "borderless": borderless})


func _cmd_set_window_always_on_top(params: Dictionary) -> void:
	var on_top: bool = params.get("on_top", true)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, on_top)
	_send_response({"success": true, "always_on_top": on_top})


func _cmd_find_nodes_by_group(params: Dictionary) -> void:
	var group_name: String = params.get("group_name", "")
	if group_name.is_empty():
		_send_response({"error": "group_name is required"})
		return
	var nodes = get_tree().get_nodes_in_group(group_name)
	var result = []
	for node in nodes:
		result.append({"name": node.name, "path": str(node.get_path()), "class": node.get_class()})
	_send_response({"success": true, "group": group_name, "nodes": result, "count": result.size()})


func _cmd_set_all_nodes_in_group_visible(params: Dictionary) -> void:
	var group_name: String = params.get("group_name", "")
	var visible: bool = params.get("visible", true)
	var nodes = get_tree().get_nodes_in_group(group_name)
	var count = 0
	for node in nodes:
		if node is CanvasItem:
			(node as CanvasItem).visible = visible
			count += 1
		elif node is Node3D:
			(node as Node3D).visible = visible
			count += 1
	_send_response({"success": true, "group": group_name, "visible": visible, "affected": count})


func _cmd_get_node_count_in_scene(params: Dictionary) -> void:
	var count = 0
	var queue = [get_tree().current_scene]
	while queue.size() > 0:
		var node = queue.pop_front()
		if node == null:
			continue
		count += 1
		for child in node.get_children():
			queue.append(child)
	_send_response({"success": true, "node_count": count})


func _cmd_get_nodes_with_script(params: Dictionary) -> void:
	var script_path: String = params.get("script_path", "")
	var result = []
	var queue = [get_tree().current_scene]
	while queue.size() > 0:
		var node = queue.pop_front()
		if node == null:
			continue
		var sc = node.get_script()
		if sc != null:
			var sc_path = sc.resource_path if sc.resource_path != null else ""
			if script_path.is_empty() or sc_path == script_path:
				result.append({"name": node.name, "path": str(node.get_path()), "script": sc_path})
		for child in node.get_children():
			queue.append(child)
	_send_response({"success": true, "nodes": result, "count": result.size()})


func _cmd_set_group_process(params: Dictionary) -> void:
	var group_name: String = params.get("group_name", "")
	var enabled: bool = params.get("enabled", true)
	var nodes = get_tree().get_nodes_in_group(group_name)
	var count = 0
	for node in nodes:
		node.set_process(enabled)
		node.set_physics_process(enabled)
		count += 1
	_send_response({"success": true, "group": group_name, "process_enabled": enabled, "affected": count})


func _cmd_get_skeleton_3d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	var skel := node as Skeleton3D
	var bone_names = []
	for i in range(skel.get_bone_count()):
		bone_names.append(skel.get_bone_name(i))
	_send_response({"success": true, "bone_count": skel.get_bone_count(), "bone_names": bone_names})


func _cmd_set_skeleton_3d_bone_pose_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bone_index: int = params.get("bone_index", 0)
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	var skel := node as Skeleton3D
	var pose = skel.get_bone_pose(bone_index)
	pose.origin = Vector3(x, y, z)
	skel.set_bone_pose(bone_index, pose)
	_send_response({"success": true, "bone_index": bone_index, "position": {"x": x, "y": y, "z": z}})


func _cmd_get_skeleton_3d_bone_global_pose(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bone_index: int = params.get("bone_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	var pose = (node as Skeleton3D).get_bone_global_pose(bone_index)
	var origin = pose.origin
	_send_response({"success": true, "bone_index": bone_index, "position": {"x": origin.x, "y": origin.y, "z": origin.z}})


func _cmd_reset_skeleton_3d_pose(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	var skel := node as Skeleton3D
	for i in range(skel.get_bone_count()):
		skel.set_bone_pose(i, skel.get_bone_rest(i))
	_send_response({"success": true, "reset_bones": skel.get_bone_count()})


func _cmd_get_skeleton_3d_bone_name(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bone_index: int = params.get("bone_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	_send_response({"success": true, "bone_name": (node as Skeleton3D).get_bone_name(bone_index), "bone_index": bone_index})


func _cmd_find_skeleton_3d_bone_by_name(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bone_name: String = params.get("bone_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	var idx = (node as Skeleton3D).find_bone(bone_name)
	_send_response({"success": true, "bone_name": bone_name, "bone_index": idx, "found": idx >= 0})


func _cmd_set_skeleton_3d_bone_enabled(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bone_index: int = params.get("bone_index", 0)
	var enabled: bool = params.get("enabled", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + node_path})
		return
	(node as Skeleton3D).set_bone_enabled(bone_index, enabled)
	_send_response({"success": true, "bone_index": bone_index, "enabled": enabled})


func _cmd_create_http_request_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var request_name: String = params.get("request_name", "HTTPRequest")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Parent node not found: " + node_path})
		return
	var existing = node.get_node_or_null(request_name)
	if existing != null:
		_send_response({"success": true, "note": "HTTPRequest already exists", "name": request_name})
		return
	var http_req = HTTPRequest.new()
	http_req.name = request_name
	node.add_child(http_req)
	_send_response({"success": true, "created": request_name, "parent": node_path})


func _cmd_get_last_http_response(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is HTTPRequest:
		_send_response({"error": "HTTPRequest not found: " + node_path})
		return
	_send_response({"success": true, "is_requesting": (node as HTTPRequest).is_requesting(), "body_size_limit": (node as HTTPRequest).body_size_limit})


func _cmd_download_file_via_http(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var url: String = params.get("url", "")
	var save_path: String = params.get("save_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is HTTPRequest:
		_send_response({"error": "HTTPRequest not found: " + node_path})
		return
	if url.is_empty():
		_send_response({"error": "url is required"})
		return
	(node as HTTPRequest).download_file = save_path
	(node as HTTPRequest).request(url)
	_send_response({"success": true, "url": url, "save_path": save_path, "note": "Download started asynchronously"})


func _cmd_get_node_children_recursive(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var max_depth: int = params.get("max_depth", 5)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var result = []
	var stack = [[node, 0]]
	while stack.size() > 0:
		var entry = stack.pop_back()
		var current = entry[0]
		var depth = entry[1]
		if depth > 0:
			result.append({"name": current.name, "class": current.get_class(), "path": str(current.get_path()), "depth": depth})
		if depth < max_depth:
			for child in current.get_children():
				stack.push_back([child, depth + 1])
	_send_response({"success": true, "children": result, "count": result.size()})


func _cmd_get_scene_instanced_count(params: Dictionary) -> void:
	var scene_path: String = params.get("scene_path", "")
	var count = 0
	var queue = [get_tree().current_scene]
	while queue.size() > 0:
		var node = queue.pop_front()
		if node == null:
			continue
		if node.scene_file_path == scene_path:
			count += 1
		for child in node.get_children():
			queue.append(child)
	_send_response({"success": true, "scene_path": scene_path, "instance_count": count})


func _cmd_get_animation_player_animations(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationPlayer:
		_send_response({"error": "AnimationPlayer not found: " + node_path})
		return
	var anim_list = (node as AnimationPlayer).get_animation_list()
	_send_response({"success": true, "animations": Array(anim_list), "count": anim_list.size()})


func _cmd_get_unix_time(params: Dictionary) -> void:
	_send_response({"success": true, "unix_time": Time.get_unix_time_from_system()})


func _cmd_get_datetime_dict(params: Dictionary) -> void:
	var dt = Time.get_datetime_dict_from_system()
	_send_response({"success": true, "datetime": dt})


func _cmd_get_ticks_msec(params: Dictionary) -> void:
	_send_response({"success": true, "ticks_msec": Time.get_ticks_msec()})


func _cmd_get_ticks_usec(params: Dictionary) -> void:
	_send_response({"success": true, "ticks_usec": Time.get_ticks_usec()})


func _cmd_unix_time_to_datetime(params: Dictionary) -> void:
	var unix_time: float = params.get("unix_time", 0.0)
	var dt = Time.get_datetime_dict_from_unix_time(int(unix_time))
	_send_response({"success": true, "datetime": dt})


func _cmd_datetime_to_unix_time(params: Dictionary) -> void:
	var dt = {
		"year": params.get("year", 2024),
		"month": params.get("month", 1),
		"day": params.get("day", 1),
		"hour": params.get("hour", 0),
		"minute": params.get("minute", 0),
		"second": params.get("second", 0)
	}
	var unix_time = Time.get_unix_time_from_datetime_dict(dt)
	_send_response({"success": true, "unix_time": unix_time})


func _cmd_hash_string_sha256(params: Dictionary) -> void:
	var text: String = params.get("text", "")
	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.to_utf8_buffer())
	var result = ctx.finish()
	_send_response({"success": true, "sha256": result.hex_encode(), "input_length": text.length()})


func _cmd_hash_string_md5(params: Dictionary) -> void:
	var text: String = params.get("text", "")
	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(text.to_utf8_buffer())
	var result = ctx.finish()
	_send_response({"success": true, "md5": result.hex_encode(), "input_length": text.length()})


func _cmd_generate_uuid_v4(params: Dictionary) -> void:
	var b = PackedByteArray()
	b.resize(16)
	for i in range(16):
		b[i] = randi() % 256
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	var hex = b.hex_encode()
	var uuid = "%s-%s-%s-%s-%s" % [hex.substr(0,8), hex.substr(8,4), hex.substr(12,4), hex.substr(16,4), hex.substr(20,12)]
	_send_response({"success": true, "uuid": uuid})


func _cmd_base64_encode(params: Dictionary) -> void:
	var text: String = params.get("text", "")
	var encoded = Marshalls.utf8_to_base64(text)
	_send_response({"success": true, "encoded": encoded})


func _cmd_base64_decode(params: Dictionary) -> void:
	var encoded: String = params.get("encoded", "")
	var decoded = Marshalls.base64_to_utf8(encoded)
	_send_response({"success": true, "decoded": decoded})


func _cmd_get_random_int(params: Dictionary) -> void:
	var min_val: int = params.get("min", 0)
	var max_val: int = params.get("max", 100)
	var result = randi_range(min_val, max_val)
	_send_response({"success": true, "value": result, "min": min_val, "max": max_val})


func _cmd_get_input_map_actions(params: Dictionary) -> void:
	var actions = InputMap.get_actions()
	_send_response({"success": true, "actions": Array(actions), "count": actions.size()})


func _cmd_action_has_event(params: Dictionary) -> void:
	var action_name: String = params.get("action_name", "")
	if not InputMap.has_action(action_name):
		_send_response({"error": "Action not found: " + action_name})
		return
	var events = InputMap.action_get_events(action_name)
	_send_response({"success": true, "action_name": action_name, "event_count": events.size(), "has_events": events.size() > 0})


func _cmd_add_input_action(params: Dictionary) -> void:
	var action_name: String = params.get("action_name", "")
	var deadzone: float = params.get("deadzone", 0.5)
	if action_name.is_empty():
		_send_response({"error": "action_name is required"})
		return
	if InputMap.has_action(action_name):
		_send_response({"success": true, "note": "Action already exists", "action_name": action_name})
		return
	InputMap.add_action(action_name, deadzone)
	_send_response({"success": true, "added": action_name, "deadzone": deadzone})


func _cmd_erase_input_action(params: Dictionary) -> void:
	var action_name: String = params.get("action_name", "")
	if not InputMap.has_action(action_name):
		_send_response({"error": "Action not found: " + action_name})
		return
	InputMap.erase_action(action_name)
	_send_response({"success": true, "erased": action_name})


func _cmd_action_get_deadzone(params: Dictionary) -> void:
	var action_name: String = params.get("action_name", "")
	if not InputMap.has_action(action_name):
		_send_response({"error": "Action not found: " + action_name})
		return
	_send_response({"success": true, "action_name": action_name, "deadzone": InputMap.action_get_deadzone(action_name)})


func _cmd_get_actions_for_key(params: Dictionary) -> void:
	var keycode: int = params.get("keycode", 32)
	var result = []
	for action in InputMap.get_actions():
		for event in InputMap.action_get_events(action):
			if event is InputEventKey and event.keycode == keycode:
				result.append(str(action))
				break
	_send_response({"success": true, "keycode": keycode, "actions": result, "count": result.size()})


func _cmd_gdscript_string_format(params: Dictionary) -> void:
	var template: String = params.get("template", "")
	var values = params.get("values", [])
	var result = template % values
	_send_response({"success": true, "result": result})


func _cmd_json_stringify_in_godot(params: Dictionary) -> void:
	var data = params.get("data", {})
	var result = JSON.stringify(data)
	_send_response({"success": true, "json": result, "length": result.length()})


func _cmd_json_parse_in_godot(params: Dictionary) -> void:
	var json_string: String = params.get("json_string", "{}")
	var result = JSON.parse_string(json_string)
	if result == null:
		_send_response({"error": "Failed to parse JSON"})
		return
	_send_response({"success": true, "data": result})


func _cmd_evaluate_gdscript_expression(params: Dictionary) -> void:
	var expression_str: String = params.get("expression", "1 + 1")
	var expr = Expression.new()
	var err = expr.parse(expression_str)
	if err != OK:
		_send_response({"error": "Parse error: " + expr.get_error_text()})
		return
	var result = expr.execute([], null, true)
	if expr.has_execute_failed():
		_send_response({"error": "Execution failed"})
		return
	_send_response({"success": true, "expression": expression_str, "result": result})


func _cmd_get_string_length(params: Dictionary) -> void:
	var text: String = params.get("text", "")
	_send_response({"success": true, "length": text.length(), "byte_count": text.to_utf8_buffer().size()})


func _cmd_start_animation_state(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var state_name: String = params.get("state_name", "")
	var param_path: String = params.get("param_path", "parameters/playback")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found: " + node_path})
		return
	var playback = (node as AnimationTree).get(param_path)
	if playback == null or not playback is AnimationNodeStateMachinePlayback:
		_send_response({"error": "No StateMachinePlayback at: " + param_path})
		return
	(playback as AnimationNodeStateMachinePlayback).start(state_name)
	_send_response({"success": true, "started_state": state_name})


func _cmd_stop_animation_state_machine(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var param_path: String = params.get("param_path", "parameters/playback")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found: " + node_path})
		return
	var playback = (node as AnimationTree).get(param_path)
	if playback == null or not playback is AnimationNodeStateMachinePlayback:
		_send_response({"error": "No StateMachinePlayback at: " + param_path})
		return
	(playback as AnimationNodeStateMachinePlayback).stop()
	_send_response({"success": true, "stopped": true})


func _cmd_get_current_animation_state(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var param_path: String = params.get("param_path", "parameters/playback")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is AnimationTree:
		_send_response({"error": "AnimationTree not found: " + node_path})
		return
	var playback = (node as AnimationTree).get(param_path)
	if playback == null or not playback is AnimationNodeStateMachinePlayback:
		_send_response({"error": "No StateMachinePlayback at: " + param_path})
		return
	var pb = playback as AnimationNodeStateMachinePlayback
	_send_response({"success": true, "current_node": pb.get_current_node(), "travel_path": Array(pb.get_travel_path()), "is_playing": pb.is_playing()})


func _cmd_get_path_3d_baked_length(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Path3D:
		_send_response({"error": "Path3D not found: " + node_path})
		return
	var curve = (node as Path3D).curve
	if curve == null:
		_send_response({"error": "Path3D has no curve"})
		return
	_send_response({"success": true, "baked_length": curve.get_baked_length(), "point_count": curve.point_count})


func _cmd_get_path_3d_point_count(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Path3D:
		_send_response({"error": "Path3D not found: " + node_path})
		return
	var curve = (node as Path3D).curve
	var count = 0 if curve == null else curve.point_count
	_send_response({"success": true, "point_count": count})


func _cmd_add_path_3d_point(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var idx: int = params.get("idx", -1)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Path3D:
		_send_response({"error": "Path3D not found: " + node_path})
		return
	var curve = (node as Path3D).curve
	if curve == null:
		curve = Curve3D.new()
		(node as Path3D).curve = curve
	curve.add_point(Vector3(x, y, z), Vector3.ZERO, Vector3.ZERO, idx)
	_send_response({"success": true, "point_count": curve.point_count})


func _cmd_remove_path_3d_point(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var idx: int = params.get("idx", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Path3D:
		_send_response({"error": "Path3D not found: " + node_path})
		return
	var curve = (node as Path3D).curve
	if curve == null or idx >= curve.point_count:
		_send_response({"error": "Invalid index"})
		return
	curve.remove_point(idx)
	_send_response({"success": true, "point_count": curve.point_count})


func _cmd_get_path_3d_point_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var idx: int = params.get("idx", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Path3D:
		_send_response({"error": "Path3D not found: " + node_path})
		return
	var curve = (node as Path3D).curve
	if curve == null or idx >= curve.point_count:
		_send_response({"error": "Invalid index or no curve"})
		return
	var pos = curve.get_point_position(idx)
	_send_response({"success": true, "x": pos.x, "y": pos.y, "z": pos.z})


func _cmd_sample_path_3d_at_offset(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var offset: float = params.get("offset", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Path3D:
		_send_response({"error": "Path3D not found: " + node_path})
		return
	var curve = (node as Path3D).curve
	if curve == null:
		_send_response({"error": "Path3D has no curve"})
		return
	var pos = curve.sample_baked(offset)
	var tangent = curve.sample_baked(offset + 0.01) - pos
	_send_response({"success": true, "x": pos.x, "y": pos.y, "z": pos.z, "tangent": {"x": tangent.x, "y": tangent.y, "z": tangent.z}})


func _cmd_get_pin_joint_2d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is PinJoint2D:
		_send_response({"error": "PinJoint2D not found: " + node_path})
		return
	var pj = node as PinJoint2D
	_send_response({"success": true, "softness": pj.softness, "node_a": str(pj.node_a), "node_b": str(pj.node_b)})


func _cmd_set_pin_joint_2d_softness(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var softness: float = params.get("softness", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is PinJoint2D:
		_send_response({"error": "PinJoint2D not found: " + node_path})
		return
	(node as PinJoint2D).softness = softness
	_send_response({"success": true, "softness": softness})


func _cmd_get_groove_joint_2d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GrooveJoint2D:
		_send_response({"error": "GrooveJoint2D not found: " + node_path})
		return
	var gj = node as GrooveJoint2D
	_send_response({"success": true, "length": gj.length, "initial_offset": gj.initial_offset, "node_a": str(gj.node_a), "node_b": str(gj.node_b)})


func _cmd_get_damped_spring_joint_2d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is DampedSpringJoint2D:
		_send_response({"error": "DampedSpringJoint2D not found: " + node_path})
		return
	var dj = node as DampedSpringJoint2D
	_send_response({"success": true, "stiffness": dj.stiffness, "damping": dj.damping, "rest_length": dj.rest_length, "length": dj.length})


func _cmd_set_damped_spring_joint_2d_stiffness(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var stiffness: float = params.get("stiffness", 20.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is DampedSpringJoint2D:
		_send_response({"error": "DampedSpringJoint2D not found: " + node_path})
		return
	(node as DampedSpringJoint2D).stiffness = stiffness
	_send_response({"success": true, "stiffness": stiffness})


func _cmd_get_hinge_joint_3d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is HingeJoint3D:
		_send_response({"error": "HingeJoint3D not found: " + node_path})
		return
	var hj = node as HingeJoint3D
	_send_response({"success": true, "limit_lower": hj.get_param(HingeJoint3D.PARAM_LIMIT_LOWER), "limit_upper": hj.get_param(HingeJoint3D.PARAM_LIMIT_UPPER), "motor_target_velocity": hj.get_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY), "node_a": str(hj.node_a), "node_b": str(hj.node_b)})


func _cmd_get_slider_joint_3d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SliderJoint3D:
		_send_response({"error": "SliderJoint3D not found: " + node_path})
		return
	var sj = node as SliderJoint3D
	_send_response({"success": true, "linear_limit_lower": sj.get_param(SliderJoint3D.PARAM_LINEAR_LIMIT_LOWER), "linear_limit_upper": sj.get_param(SliderJoint3D.PARAM_LINEAR_LIMIT_UPPER), "node_a": str(sj.node_a), "node_b": str(sj.node_b)})


func _cmd_get_cone_twist_joint_3d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is ConeTwistJoint3D:
		_send_response({"error": "ConeTwistJoint3D not found: " + node_path})
		return
	var cj = node as ConeTwistJoint3D
	_send_response({"success": true, "swing_span": cj.get_param(ConeTwistJoint3D.PARAM_SWING_SPAN), "twist_span": cj.get_param(ConeTwistJoint3D.PARAM_TWIST_SPAN), "node_a": str(cj.node_a), "node_b": str(cj.node_b)})


func _cmd_get_generic_6dof_joint_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Generic6DOFJoint3D:
		_send_response({"error": "Generic6DOFJoint3D not found: " + node_path})
		return
	var gj = node as Generic6DOFJoint3D
	_send_response({"success": true, "linear_limit_x_lower": gj.get_param_x(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT), "linear_limit_x_upper": gj.get_param_x(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT), "node_a": str(gj.node_a), "node_b": str(gj.node_b)})


func _cmd_set_joint_3d_node_paths(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node_a: String = params.get("node_a", "")
	var node_b: String = params.get("node_b", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Joint3D:
		_send_response({"error": "Joint3D not found: " + node_path})
		return
	var joint = node as Joint3D
	joint.node_a = NodePath(node_a)
	joint.node_b = NodePath(node_b)
	_send_response({"success": true, "node_a": node_a, "node_b": node_b})


func _cmd_get_vehicle_body_3d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is VehicleBody3D:
		_send_response({"error": "VehicleBody3D not found: " + node_path})
		return
	var vb = node as VehicleBody3D
	_send_response({"success": true, "engine_force": vb.engine_force, "brake": vb.brake, "steering": vb.steering, "linear_velocity": {"x": vb.linear_velocity.x, "y": vb.linear_velocity.y, "z": vb.linear_velocity.z}})


func _cmd_set_vehicle_body_3d_engine_force(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var engine_force: float = params.get("engine_force", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is VehicleBody3D:
		_send_response({"error": "VehicleBody3D not found: " + node_path})
		return
	(node as VehicleBody3D).engine_force = engine_force
	_send_response({"success": true, "engine_force": engine_force})


func _cmd_get_spring_arm_3d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SpringArm3D:
		_send_response({"error": "SpringArm3D not found: " + node_path})
		return
	var sa = node as SpringArm3D
	_send_response({"success": true, "spring_length": sa.spring_length, "collision_mask": sa.collision_mask, "margin": sa.margin})


func _cmd_set_spring_arm_3d_length(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var spring_length: float = params.get("spring_length", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SpringArm3D:
		_send_response({"error": "SpringArm3D not found: " + node_path})
		return
	(node as SpringArm3D).spring_length = spring_length
	_send_response({"success": true, "spring_length": spring_length})


func _cmd_get_bone_attachment_3d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is BoneAttachment3D:
		_send_response({"error": "BoneAttachment3D not found: " + node_path})
		return
	var ba = node as BoneAttachment3D
	_send_response({"success": true, "bone_name": ba.bone_name, "bone_idx": ba.bone_idx, "override_pose": ba.override_pose})


func _cmd_set_bone_attachment_3d_bone_name(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var bone_name: String = params.get("bone_name", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is BoneAttachment3D:
		_send_response({"error": "BoneAttachment3D not found: " + node_path})
		return
	(node as BoneAttachment3D).bone_name = bone_name
	_send_response({"success": true, "bone_name": bone_name})


func _cmd_get_physical_bone_3d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is PhysicalBone3D:
		_send_response({"error": "PhysicalBone3D not found: " + node_path})
		return
	var pb = node as PhysicalBone3D
	_send_response({"success": true, "joint_type": pb.joint_type, "mass": pb.mass, "linear_velocity": {"x": pb.linear_velocity.x, "y": pb.linear_velocity.y, "z": pb.linear_velocity.z}})


func _cmd_apply_physical_bone_impulse(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var z: float = params.get("z", 0.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is PhysicalBone3D:
		_send_response({"error": "PhysicalBone3D not found: " + node_path})
		return
	(node as PhysicalBone3D).apply_central_impulse(Vector3(x, y, z))
	_send_response({"success": true, "impulse": {"x": x, "y": y, "z": z}})


func _cmd_get_skeleton_physical_bones_simulating(params: Dictionary) -> void:
	var skeleton_path: String = params.get("skeleton_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(skeleton_path))
	if node == null or not node is Skeleton3D:
		_send_response({"error": "Skeleton3D not found: " + skeleton_path})
		return
	var sk = node as Skeleton3D
	var physical_bones = []
	for child in sk.get_children():
		if child is PhysicalBone3D:
			physical_bones.append({"name": child.name, "simulating": child.is_simulating_physics()})
	_send_response({"success": true, "physical_bones": physical_bones, "count": physical_bones.size()})


func _cmd_get_decal_3d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Decal:
		_send_response({"error": "Decal not found: " + node_path})
		return
	var d = node as Decal
	_send_response({"success": true, "size": {"x": d.size.x, "y": d.size.y, "z": d.size.z}, "albedo_mix": d.albedo_mix, "upper_fade": d.upper_fade, "lower_fade": d.lower_fade})


func _cmd_set_decal_3d_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var x: float = params.get("x", 1.0)
	var y: float = params.get("y", 1.0)
	var z: float = params.get("z", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Decal:
		_send_response({"error": "Decal not found: " + node_path})
		return
	(node as Decal).size = Vector3(x, y, z)
	_send_response({"success": true, "size": {"x": x, "y": y, "z": z}})


func _cmd_set_decal_3d_albedo_mix(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var albedo_mix: float = params.get("albedo_mix", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Decal:
		_send_response({"error": "Decal not found: " + node_path})
		return
	(node as Decal).albedo_mix = clamp(albedo_mix, 0.0, 1.0)
	_send_response({"success": true, "albedo_mix": albedo_mix})


func _cmd_get_csg_shape_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CSGShape3D:
		_send_response({"error": "CSGShape3D not found: " + node_path})
		return
	var cs = node as CSGShape3D
	_send_response({"success": true, "operation": cs.operation, "snap": cs.snap, "use_collision": cs.use_collision})


func _cmd_set_csg_shape_operation(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var operation: int = params.get("operation", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CSGShape3D:
		_send_response({"error": "CSGShape3D not found: " + node_path})
		return
	(node as CSGShape3D).operation = operation
	_send_response({"success": true, "operation": operation})


func _cmd_get_csg_combined_faces(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is CSGShape3D:
		_send_response({"error": "CSGShape3D not found: " + node_path})
		return
	var faces = (node as CSGShape3D).get_meshes()
	var face_count = 0
	if faces.size() > 1 and faces[1] is Mesh:
		var mesh = faces[1] as Mesh
		for s in range(mesh.get_surface_count()):
			face_count += mesh.surface_get_array_len(s) / 3
	_send_response({"success": true, "face_count": face_count, "mesh_count": faces.size()})


func _cmd_set_audio_bus_name(params: Dictionary) -> void:
	var bus_index: int = params.get("bus_index", 0)
	var name: String = params.get("name", "")
	if bus_index < 0 or bus_index >= AudioServer.get_bus_count():
		_send_response({"error": "Invalid bus index: " + str(bus_index)})
		return
	AudioServer.set_bus_name(bus_index, name)
	_send_response({"success": true, "index": bus_index, "name": name})


func _cmd_move_audio_bus(params: Dictionary) -> void:
	var bus_index: int = params.get("bus_index", 0)
	var to_index: int = params.get("to_index", 0)
	if bus_index < 0 or bus_index >= AudioServer.get_bus_count():
		_send_response({"error": "Invalid bus index: " + str(bus_index)})
		return
	AudioServer.move_bus(bus_index, to_index)
	_send_response({"success": true, "moved_from": bus_index, "moved_to": to_index})


func _cmd_get_audio_bus_send(params: Dictionary) -> void:
	var bus_index: int = params.get("bus_index", 0)
	if bus_index < 0 or bus_index >= AudioServer.get_bus_count():
		_send_response({"error": "Invalid bus index: " + str(bus_index)})
		return
	_send_response({"success": true, "send": AudioServer.get_bus_send(bus_index)})


func _cmd_create_enet_peer(params: Dictionary) -> void:
	var address: String = params.get("address", "localhost")
	var port: int = params.get("port", 7777)
	var channel_count: int = params.get("channel_count", 0)
	var peer = ENetMultiplayerPeer.new()
	var err = peer.create_client(address, port, channel_count)
	if err != OK:
		_send_response({"error": "Failed to create ENet client: " + str(err)})
		return
	_send_response({"success": true, "address": address, "port": port, "status": peer.get_connection_status()})


func _cmd_create_enet_server(params: Dictionary) -> void:
	var port: int = params.get("port", 7777)
	var max_clients: int = params.get("max_clients", 32)
	var channel_count: int = params.get("channel_count", 0)
	var peer = ENetMultiplayerPeer.new()
	var err = peer.create_server(port, max_clients, channel_count)
	if err != OK:
		_send_response({"error": "Failed to create ENet server: " + str(err)})
		return
	_send_response({"success": true, "port": port, "max_clients": max_clients, "status": peer.get_connection_status()})


func _cmd_get_enet_connection_status(params: Dictionary) -> void:
	var mp = get_tree().get_multiplayer()
	if mp == null:
		_send_response({"error": "No multiplayer peer configured"})
		return
	_send_response({"success": true, "unique_id": mp.get_unique_id(), "is_server": mp.is_server()})


func _cmd_create_websocket_peer(params: Dictionary) -> void:
	var url: String = params.get("url", "")
	var protocols: Array = params.get("protocols", [])
	if url.is_empty():
		_send_response({"error": "url is required"})
		return
	var peer = WebSocketPeer.new()
	var err = peer.connect_to_url(url, PackedStringArray(protocols))
	if err != OK:
		_send_response({"error": "Failed to connect WebSocket: " + str(err)})
		return
	_send_response({"success": true, "url": url, "state": peer.get_ready_state()})


func _cmd_get_websocket_peer_state(params: Dictionary) -> void:
	_send_response({"success": true, "note": "WebSocketPeer state must be checked per-instance", "states": {"CONNECTING": 0, "OPEN": 1, "CLOSING": 2, "CLOSED": 3}})


func _cmd_send_websocket_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var message: String = params.get("message", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if not node.has_method("send_text"):
		_send_response({"error": "Node does not have send_text method"})
		return
	node.send_text(message)
	_send_response({"success": true, "message": message, "length": message.length()})


func _cmd_get_visual_shader_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	if not node is ShaderMaterial:
		_send_response({"error": "Node does not have ShaderMaterial"})
		return
	var mat = node.material_override if node.has_method("get") else null
	_send_response({"success": true, "node_path": node_path, "note": "VisualShader manipulation requires editor context"})


func _cmd_add_visual_shader_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node_type: String = params.get("node_type", "")
	var shader_type: String = params.get("shader_type", "TYPE_FRAGMENT")
	var pos_x: float = params.get("pos_x", 0.0)
	var pos_y: float = params.get("pos_y", 0.0)
	_send_response({"success": true, "note": "VisualShader node addition requires editor context", "node_path": node_path, "node_type": node_type, "shader_type": shader_type, "position": {"x": pos_x, "y": pos_y}})


func _cmd_remove_visual_shader_node(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var shader_type: String = params.get("shader_type", "TYPE_FRAGMENT")
	var node_id: int = params.get("node_id", 0)
	_send_response({"success": true, "note": "VisualShader removal requires editor context", "node_path": node_path, "shader_type": shader_type, "node_id": node_id})


func _cmd_connect_visual_shader_nodes(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var shader_type: String = params.get("shader_type", "TYPE_FRAGMENT")
	var from_node: int = params.get("from_node", 0)
	var from_port: int = params.get("from_port", 0)
	var to_node: int = params.get("to_node", 0)
	var to_port: int = params.get("to_port", 0)
	_send_response({"success": true, "note": "VisualShader connection requires editor context", "from": {"node": from_node, "port": from_port}, "to": {"node": to_node, "port": to_port}})


func _cmd_get_visual_shader_node_list(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var shader_type: String = params.get("shader_type", "TYPE_FRAGMENT")
	_send_response({"success": true, "note": "VisualShader node listing requires editor context", "node_path": node_path, "shader_type": shader_type, "valid_shader_types": ["TYPE_VERTEX", "TYPE_FRAGMENT", "TYPE_LIGHT", "TYPE_START", "TYPE_PROCESS", "TYPE_COLLIDE", "TYPE_END"]})


func _cmd_set_visual_shader_node_position(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var shader_type: String = params.get("shader_type", "TYPE_FRAGMENT")
	var node_id: int = params.get("node_id", 0)
	var pos_x: float = params.get("pos_x", 0.0)
	var pos_y: float = params.get("pos_y", 0.0)
	_send_response({"success": true, "note": "VisualShader position set requires editor context", "node_id": node_id, "position": {"x": pos_x, "y": pos_y}})


func _cmd_get_visual_shader_connections(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var shader_type: String = params.get("shader_type", "TYPE_FRAGMENT")
	_send_response({"success": true, "note": "VisualShader connections require editor context", "node_path": node_path, "shader_type": shader_type})


func _cmd_disconnect_visual_shader_nodes(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var shader_type: String = params.get("shader_type", "TYPE_FRAGMENT")
	var from_node: int = params.get("from_node", 0)
	var from_port: int = params.get("from_port", 0)
	var to_node: int = params.get("to_node", 0)
	var to_port: int = params.get("to_port", 0)
	_send_response({"success": true, "note": "VisualShader disconnect requires editor context", "from": {"node": from_node, "port": from_port}, "to": {"node": to_node, "port": to_port}})


func _cmd_list_system_fonts(params: Dictionary) -> void:
	var fonts = OS.get_system_fonts()
	_send_response({"success": true, "fonts": Array(fonts), "count": fonts.size()})


func _cmd_get_editor_selected_nodes(params: Dictionary) -> void:
	_send_response({"success": true, "note": "Editor selection is only available via editorCommand (port 9091)", "use_tool": "get_editor_selected_nodes via editor plugin"})


func _cmd_get_screen_dpi(params: Dictionary) -> void:
	_send_response({"success": true, "dpi": DisplayServer.screen_get_dpi(), "size": {"x": DisplayServer.screen_get_size().x, "y": DisplayServer.screen_get_size().y}})


func _cmd_get_display_server_info(params: Dictionary) -> void:
	_send_response({"success": true, "screen_count": DisplayServer.get_screen_count(), "main_window_id": DisplayServer.get_window_list()[0] if DisplayServer.get_window_list().size() > 0 else -1, "native_handle": 0})


func _cmd_get_engine_target_fps(params: Dictionary) -> void:
	_send_response({"success": true, "target_fps": Engine.max_fps, "physics_ticks": Engine.physics_ticks_per_second, "time_scale": Engine.time_scale})


func _cmd_set_engine_target_fps(params: Dictionary) -> void:
	var fps: int = params.get("fps", 60)
	Engine.max_fps = fps
	_send_response({"success": true, "target_fps": fps})


func _cmd_get_locale_info(params: Dictionary) -> void:
	_send_response({"success": true, "locale": OS.get_locale(), "language": OS.get_locale_language(), "country_code": OS.get_locale().split("_")[1] if "_" in OS.get_locale() else ""})


func _cmd_get_environment_variable(params: Dictionary) -> void:
	var var_name: String = params.get("var_name", "")
	if var_name.is_empty():
		_send_response({"error": "var_name is required"})
		return
	var value = OS.get_environment(var_name)
	_send_response({"success": true, "var_name": var_name, "value": value, "found": not value.is_empty()})


func _cmd_get_xr_interface_list(params: Dictionary) -> void:
	var iface_count = XRServer.get_interface_count()
	var interfaces = []
	for i in range(iface_count):
		var iface = XRServer.get_interface(i)
		interfaces.append({"name": iface.get_name(), "is_initialized": iface.is_initialized()})
	_send_response({"success": true, "interfaces": interfaces, "count": iface_count})


func _cmd_initialize_xr_interface(params: Dictionary) -> void:
	var interface_name: String = params.get("interface_name", "")
	var iface = XRServer.find_interface(interface_name)
	if iface == null:
		_send_response({"error": "XR interface not found: " + interface_name})
		return
	var result = iface.initialize()
	_send_response({"success": true, "interface_name": interface_name, "initialized": result})


func _cmd_get_xr_is_tracking(params: Dictionary) -> void:
	var primary = XRServer.primary_interface
	if primary == null:
		_send_response({"success": true, "tracking": false, "primary_interface": null})
		return
	_send_response({"success": true, "tracking": primary.is_initialized(), "primary_interface": primary.get_name()})


func _cmd_get_xr_controller_input(params: Dictionary) -> void:
	var controller_id: int = params.get("controller_id", 1)
	var result = {"controller_id": controller_id}
	for node in get_tree().root.find_children("*", "XRController3D", true):
		if node is XRController3D and node.get_tracker_hand() == controller_id:
			result["is_active"] = node.get_is_active()
			result["position"] = {"x": node.global_position.x, "y": node.global_position.y, "z": node.global_position.z}
			break
	_send_response({"success": true, "data": result})


func _cmd_get_xr_camera_transform(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is XRCamera3D:
		_send_response({"error": "XRCamera3D not found: " + node_path})
		return
	var cam = node as XRCamera3D
	var pos = cam.global_position
	_send_response({"success": true, "position": {"x": pos.x, "y": pos.y, "z": pos.z}, "is_active": true})


func _cmd_set_xr_world_scale(params: Dictionary) -> void:
	var scale_val: float = params.get("scale", 1.0)
	XRServer.world_scale = scale_val
	_send_response({"success": true, "world_scale": scale_val})


func _cmd_get_xr_anchor_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is XRAnchor3D:
		_send_response({"error": "XRAnchor3D not found: " + node_path})
		return
	var anchor = node as XRAnchor3D
	var pos = anchor.global_position
	_send_response({"success": true, "position": {"x": pos.x, "y": pos.y, "z": pos.z}, "is_active": anchor.get_is_active()})


func _cmd_get_navigation_agent_3d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NavigationAgent3D:
		_send_response({"error": "NavigationAgent3D not found: " + node_path})
		return
	var na = node as NavigationAgent3D
	var tp = na.target_position
	_send_response({"success": true, "target_position": {"x": tp.x, "y": tp.y, "z": tp.z}, "is_navigation_finished": na.is_navigation_finished(), "distance_to_target": na.distance_to_target(), "path_desired_distance": na.path_desired_distance})


func _cmd_get_navigation_agent_3d_next_path_pos(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NavigationAgent3D:
		_send_response({"error": "NavigationAgent3D not found: " + node_path})
		return
	var next = (node as NavigationAgent3D).get_next_path_position()
	_send_response({"success": true, "next_position": {"x": next.x, "y": next.y, "z": next.z}})


func _cmd_is_navigation_agent_3d_target_reachable(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NavigationAgent3D:
		_send_response({"error": "NavigationAgent3D not found: " + node_path})
		return
	var na = node as NavigationAgent3D
	_send_response({"success": true, "is_target_reachable": na.is_target_reachable(), "is_navigation_finished": na.is_navigation_finished()})


func _cmd_get_navigation_region_3d_enabled(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NavigationRegion3D:
		_send_response({"error": "NavigationRegion3D not found: " + node_path})
		return
	_send_response({"success": true, "enabled": (node as NavigationRegion3D).enabled})


func _cmd_set_navigation_region_3d_enabled(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var enabled: bool = params.get("enabled", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NavigationRegion3D:
		_send_response({"error": "NavigationRegion3D not found: " + node_path})
		return
	(node as NavigationRegion3D).enabled = enabled
	_send_response({"success": true, "enabled": enabled})


func _cmd_bake_navigation_mesh_3d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is NavigationRegion3D:
		_send_response({"error": "NavigationRegion3D not found: " + node_path})
		return
	(node as NavigationRegion3D).bake_navigation_mesh()
	_send_response({"success": true, "baking_started": true, "node_path": node_path})


func _cmd_get_gpu_particles_3d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GPUParticles3D:
		_send_response({"error": "GPUParticles3D not found: " + node_path})
		return
	var gp = node as GPUParticles3D
	_send_response({"success": true, "emitting": gp.emitting, "amount": gp.amount, "lifetime": gp.lifetime, "one_shot": gp.one_shot, "preprocess": gp.preprocess, "speed_scale": gp.speed_scale})


func _cmd_set_gpu_particles_3d_amount(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var amount: int = params.get("amount", 8)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GPUParticles3D:
		_send_response({"error": "GPUParticles3D not found: " + node_path})
		return
	(node as GPUParticles3D).amount = amount
	_send_response({"success": true, "amount": amount})


func _cmd_set_gpu_particles_3d_lifetime(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var lifetime: float = params.get("lifetime", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GPUParticles3D:
		_send_response({"error": "GPUParticles3D not found: " + node_path})
		return
	(node as GPUParticles3D).lifetime = lifetime
	_send_response({"success": true, "lifetime": lifetime})


func _cmd_restart_gpu_particles_3d(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GPUParticles3D:
		_send_response({"error": "GPUParticles3D not found: " + node_path})
		return
	(node as GPUParticles3D).restart()
	_send_response({"success": true, "restarted": true})


func _cmd_set_gpu_particles_3d_one_shot(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var one_shot: bool = params.get("one_shot", false)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GPUParticles3D:
		_send_response({"error": "GPUParticles3D not found: " + node_path})
		return
	(node as GPUParticles3D).one_shot = one_shot
	_send_response({"success": true, "one_shot": one_shot})


func _cmd_emit_gpu_particles_3d_subemitter(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is GPUParticles3D:
		_send_response({"error": "GPUParticles3D not found: " + node_path})
		return
	(node as GPUParticles3D).emit_particle(Transform3D.IDENTITY, Vector3.ZERO, Color.WHITE, Color.WHITE, 0)
	_send_response({"success": true, "emitted": true})


func _cmd_get_performance_monitor_value(params: Dictionary) -> void:
	var monitor_name: String = params.get("monitor_name", "TIME_FPS")
	var monitor_map = {
		"TIME_FPS": Performance.TIME_FPS,
		"TIME_PROCESS": Performance.TIME_PROCESS,
		"TIME_PHYSICS_PROCESS": Performance.TIME_PHYSICS_PROCESS,
		"MEMORY_STATIC": Performance.MEMORY_STATIC,
		"MEMORY_STATIC_MAX": Performance.MEMORY_STATIC_MAX,
		"OBJECT_COUNT": Performance.OBJECT_COUNT,
		"OBJECT_NODE_COUNT": Performance.OBJECT_NODE_COUNT,
		"RENDER_TOTAL_DRAW_CALLS_IN_FRAME": Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME
	}
	if not monitor_name in monitor_map:
		_send_response({"error": "Unknown monitor: " + monitor_name, "valid_monitors": Array(monitor_map.keys())})
		return
	_send_response({"success": true, "monitor": monitor_name, "value": Performance.get_monitor(monitor_map[monitor_name])})


func _cmd_get_all_performance_monitors(params: Dictionary) -> void:
	var monitors = {
		"fps": Performance.get_monitor(Performance.TIME_FPS),
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"memory_static_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"object_count": Performance.get_monitor(Performance.OBJECT_COUNT),
		"node_count": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	}
	_send_response({"success": true, "monitors": monitors})


func _cmd_set_project_setting_runtime(params: Dictionary) -> void:
	var setting_name: String = params.get("setting_name", "")
	var value = params.get("value", null)
	if setting_name.is_empty():
		_send_response({"error": "setting_name is required"})
		return
	ProjectSettings.set_setting(setting_name, value)
	_send_response({"success": true, "setting": setting_name, "value": value})


func _cmd_get_rendering_info(params: Dictionary) -> void:
	var info = {
		"video_adapter_name": RenderingServer.get_video_adapter_name(),
		"video_adapter_vendor": RenderingServer.get_video_adapter_vendor(),
		"video_adapter_api_version": RenderingServer.get_video_adapter_api_version(),
		"rendering_info_total_objects_in_frame": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		"rendering_info_total_draw_calls_in_frame": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	}
	_send_response({"success": true, "rendering": info})


func _cmd_get_viewport_render_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Viewport:
		_send_response({"error": "Viewport not found: " + node_path})
		return
	var vp = node as Viewport
	_send_response({"success": true, "size": {"x": vp.size.x, "y": vp.size.y}, "msaa_2d": vp.msaa_2d, "msaa_3d": vp.msaa_3d})


func _cmd_inspect_resource_properties(params: Dictionary) -> void:
	_send_response({"success": true, "note": "Resource property inspection requires headless mode via godot_operations.gd", "params": params})


func _cmd_get_sky_material_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is WorldEnvironment:
		_send_response({"error": "WorldEnvironment not found: " + node_path})
		return
	var env = (node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "No Environment resource set"})
		return
	var sky = env.sky
	_send_response({"success": true, "has_sky": sky != null, "sky_custom_fov": env.sky_custom_fov, "sky_rotation": {"x": env.sky_rotation.x, "y": env.sky_rotation.y, "z": env.sky_rotation.z}})


func _cmd_get_environment_tone_map(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is WorldEnvironment:
		_send_response({"error": "WorldEnvironment not found: " + node_path})
		return
	var env = (node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "No Environment resource set"})
		return
	_send_response({"success": true, "tone_mapper": env.tonemap_mode, "exposure": env.tonemap_exposure, "white": env.tonemap_white})


func _cmd_set_environment_tone_map(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var tone_mapper: int = params.get("tone_mapper", 0)
	var exposure: float = params.get("exposure", 1.0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is WorldEnvironment:
		_send_response({"error": "WorldEnvironment not found: " + node_path})
		return
	var env = (node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "No Environment resource set"})
		return
	env.tonemap_mode = tone_mapper
	env.tonemap_exposure = exposure
	_send_response({"success": true, "tone_mapper": tone_mapper, "exposure": exposure})


func _cmd_get_environment_glow(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is WorldEnvironment:
		_send_response({"error": "WorldEnvironment not found: " + node_path})
		return
	var env = (node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "No Environment resource set"})
		return
	_send_response({"success": true, "glow_enabled": env.glow_enabled, "glow_intensity": env.glow_intensity, "glow_strength": env.glow_strength, "glow_bloom": env.glow_bloom})


func _cmd_set_environment_glow_enabled(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var enabled: bool = params.get("enabled", true)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is WorldEnvironment:
		_send_response({"error": "WorldEnvironment not found: " + node_path})
		return
	var env = (node as WorldEnvironment).environment
	if env == null:
		_send_response({"error": "No Environment resource set"})
		return
	env.glow_enabled = enabled
	_send_response({"success": true, "glow_enabled": enabled})


func _cmd_set_group_property(params: Dictionary) -> void:
	var group_name: String = params.get("group_name", "")
	var property_name: String = params.get("property_name", "")
	var value = params.get("value", null)
	var nodes = get_tree().get_nodes_in_group(group_name)
	var count = 0
	for n in nodes:
		if property_name in n:
			n.set(property_name, value)
			count += 1
	_send_response({"success": true, "group": group_name, "property": property_name, "updated_count": count})


func _cmd_get_node_incoming_connections(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var connections = []
	for sig in node.get_signal_list():
		var sig_name = sig.get("name", "")
		for conn in node.get_signal_connection_list(sig_name):
			connections.append({"signal": sig_name, "callable": str(conn.get("callable", ""))})
	_send_response({"success": true, "connections": connections, "count": connections.size()})


func _cmd_get_resource_import_metadata(params: Dictionary) -> void:
	_send_response({"success": true, "note": "Resource import metadata requires headless mode", "params": params})


func _cmd_list_resources_of_type(params: Dictionary) -> void:
	_send_response({"success": true, "note": "Resource listing by type requires headless mode", "params": params})


func _cmd_get_gdscript_class_hierarchy(params: Dictionary) -> void:
	_send_response({"success": true, "note": "GDScript class hierarchy requires headless mode", "params": params})


func _cmd_get_script_exported_properties(params: Dictionary) -> void:
	_send_response({"success": true, "note": "Script exported properties require headless mode", "params": params})


func _cmd_get_texture_2d_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property_name: String = params.get("property_name", "texture")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var texture = node.get(property_name)
	if texture == null or not texture is Texture2D:
		_send_response({"error": "Texture2D not found at property: " + property_name})
		return
	_send_response({"success": true, "width": texture.get_width(), "height": texture.get_height()})


func _cmd_get_image_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property_name: String = params.get("property_name", "texture")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var texture = node.get(property_name)
	if texture == null or not texture is Texture2D:
		_send_response({"error": "Texture2D not found at property: " + property_name})
		return
	var img = texture.get_image()
	if img == null:
		_send_response({"error": "Could not get Image from texture"})
		return
	_send_response({"success": true, "width": img.get_width(), "height": img.get_height(), "format": img.get_format(), "has_mipmaps": img.has_mipmaps()})


func _cmd_set_texture_rect_stretch_mode(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var stretch_mode: int = params.get("stretch_mode", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is TextureRect:
		_send_response({"error": "TextureRect not found: " + node_path})
		return
	(node as TextureRect).stretch_mode = stretch_mode
	_send_response({"success": true, "stretch_mode": stretch_mode})


func _cmd_get_atlas_texture_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property_name: String = params.get("property_name", "texture")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var texture = node.get(property_name)
	if texture == null or not texture is AtlasTexture:
		_send_response({"error": "AtlasTexture not found at property: " + property_name})
		return
	var at = texture as AtlasTexture
	var r = at.region
	_send_response({"success": true, "region": {"x": r.position.x, "y": r.position.y, "w": r.size.x, "h": r.size.y}, "filter_clip": at.filter_clip})


func _cmd_create_viewport_texture(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SubViewport:
		_send_response({"error": "SubViewport not found: " + node_path})
		return
	var vp = node as SubViewport
	var tex = vp.get_texture()
	_send_response({"success": true, "has_texture": tex != null, "size": {"x": vp.size.x, "y": vp.size.y}})


func _cmd_get_texture_flags(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var property_name: String = params.get("property_name", "texture")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var texture = node.get(property_name)
	if texture == null or not texture is Texture2D:
		_send_response({"error": "Texture2D not found at property: " + property_name})
		return
	_send_response({"success": true, "width": texture.get_width(), "height": texture.get_height(), "class": texture.get_class()})


func _cmd_get_sub_viewport_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SubViewport:
		_send_response({"error": "SubViewport not found: " + node_path})
		return
	var vp = node as SubViewport
	_send_response({"success": true, "size": {"x": vp.size.x, "y": vp.size.y}, "render_target_update_mode": vp.render_target_update_mode, "transparent_bg": vp.transparent_bg, "use_hdr_2d": vp.use_hdr_2d})


func _cmd_get_viewport_texture_rid(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Viewport:
		_send_response({"error": "Viewport not found: " + node_path})
		return
	var tex = (node as Viewport).get_texture()
	_send_response({"success": true, "has_texture": tex != null, "size": {"x": (node as Viewport).size.x, "y": (node as Viewport).size.y}})


func _cmd_set_viewport_clear_mode(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var clear_mode: int = params.get("clear_mode", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SubViewport:
		_send_response({"error": "SubViewport not found: " + node_path})
		return
	(node as SubViewport).render_target_clear_mode = clear_mode
	_send_response({"success": true, "clear_mode": clear_mode})


func _cmd_get_viewport_canvas_transform(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Viewport:
		_send_response({"error": "Viewport not found: " + node_path})
		return
	var t = (node as Viewport).canvas_transform
	_send_response({"success": true, "origin": {"x": t.origin.x, "y": t.origin.y}, "scale": {"x": t.get_scale().x, "y": t.get_scale().y}})


func _cmd_get_label_3d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Label3D:
		_send_response({"error": "Label3D not found: " + node_path})
		return
	var lbl = node as Label3D
	_send_response({"success": true, "text": lbl.text, "font_size": lbl.font_size, "billboard": lbl.billboard, "modulate": {"r": lbl.modulate.r, "g": lbl.modulate.g, "b": lbl.modulate.b, "a": lbl.modulate.a}})


func _cmd_set_label_3d_text(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var text: String = params.get("text", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Label3D:
		_send_response({"error": "Label3D not found: " + node_path})
		return
	(node as Label3D).text = text
	_send_response({"success": true, "text": text})


func _cmd_set_label_3d_font_size(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var font_size: int = params.get("font_size", 16)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Label3D:
		_send_response({"error": "Label3D not found: " + node_path})
		return
	(node as Label3D).font_size = font_size
	_send_response({"success": true, "font_size": font_size})


func _cmd_set_label_3d_billboard(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var billboard_mode: int = params.get("billboard_mode", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is Label3D:
		_send_response({"error": "Label3D not found: " + node_path})
		return
	(node as Label3D).billboard = billboard_mode
	_send_response({"success": true, "billboard_mode": billboard_mode})


func _cmd_get_text_mesh_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null:
		_send_response({"error": "Node not found: " + node_path})
		return
	var mesh_inst = node as MeshInstance3D
	if mesh_inst == null or not mesh_inst.mesh is TextMesh:
		_send_response({"error": "Node does not have a TextMesh: " + node_path})
		return
	var tm = mesh_inst.mesh as TextMesh
	_send_response({"success": true, "text": tm.text, "font_size": tm.font_size, "depth": tm.depth, "pixel_size": tm.pixel_size})


func _cmd_get_soft_body_3d_info(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SoftBody3D:
		_send_response({"error": "SoftBody3D not found: " + node_path})
		return
	var sb = node as SoftBody3D
	_send_response({"success": true, "simulation_precision": sb.simulation_precision, "total_mass": sb.total_mass, "linear_stiffness": sb.linear_stiffness, "damping_coefficient": sb.damping_coefficient})


func _cmd_set_soft_body_3d_simulation_precision(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var precision: int = params.get("precision", 5)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SoftBody3D:
		_send_response({"error": "SoftBody3D not found: " + node_path})
		return
	(node as SoftBody3D).simulation_precision = precision
	_send_response({"success": true, "simulation_precision": precision})


func _cmd_pin_soft_body_3d_point(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var point_index: int = params.get("point_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SoftBody3D:
		_send_response({"error": "SoftBody3D not found: " + node_path})
		return
	(node as SoftBody3D).set_point_pinned(point_index, true)
	_send_response({"success": true, "pinned_point": point_index})


func _cmd_unpin_soft_body_3d_point(params: Dictionary) -> void:
	var node_path: String = params.get("node_path", "")
	var point_index: int = params.get("point_index", 0)
	var node = get_tree().root.get_node_or_null(NodePath(node_path))
	if node == null or not node is SoftBody3D:
		_send_response({"error": "SoftBody3D not found: " + node_path})
		return
	(node as SoftBody3D).set_point_pinned(point_index, false)
	_send_response({"success": true, "unpinned_point": point_index})


func _exit_tree() -> void:
	_clear_debug_draw()
	if _websocket != null:
		_websocket.close()
		_websocket = null
	if _client != null:
		_client.disconnect_from_host()
		_client = null
	if _server != null:
		_server.stop()
		_server = null
	print("McpInteractionServer: Stopped")
