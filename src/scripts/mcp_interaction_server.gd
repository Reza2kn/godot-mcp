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
		"set_progress_bar_value":
			_cmd_set_progress_bar_value(params)
		"set_slider_value":
			_cmd_set_slider_value(params)
		"get_spin_box_value":
			_cmd_get_spin_box_value(params)
		"set_spin_box_value":
			_cmd_set_spin_box_value(params)
		"set_option_button_selected":
			_cmd_set_option_button_selected(params)
		"get_option_button_selected":
			_cmd_get_option_button_selected(params)
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
