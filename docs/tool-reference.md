# Complete tool reference

Generated from the compiled MCP server. Total unique tools: **1969**.

The machine-readable schemas are in `tool-reference.json`. Regenerate both files with `npm run docs:generate`.

## Animation

| Tool | Description | Required arguments |
|---|---|---|
| `add_animation_key_value` | Add a value key to an animation track. | projectPath, animationPath, trackIndex, time, value |
| `add_animation_keyframe` | Add a keyframe to an animation track in a scene. | projectPath, scenePath, animationName, value |
| `add_animation_track` | Add a new track to an Animation resource. | projectPath, animationPath, trackType, nodePath |
| `add_tween` | Create a Tween on a node in the running game. | nodePath, propertyPath, finalValue |
| `animation_add_keyframe` | Add a keyframe to an animation track in the running game. | nodePath, animationName, trackPath, time, value |
| `animation_delete_keyframe` | Delete a keyframe from an animation track by index. | nodePath, animationName, trackPath, keyIndex |
| `animation_get_keyframes` | Get all keyframes in an animation track in the running game. | nodePath, animationName, trackPath |
| `animation_set_loop` | Set the loop mode of an animation in the running game. | nodePath, animationName, loopMode |
| `create_animation_library_resource` | Create an empty AnimationLibrary resource. | projectPath, outputPath |
| `create_animation_track` | Add a property track to an animation in a scene. | projectPath, scenePath, animationName, trackPath |
| `create_color_tween` | Animate a node's modulate color with Tween. | nodePath |
| `create_property_tween` | Animate a node property with Tween at runtime. | nodePath, property, targetValue, duration |
| `game_animation_control` | AnimationPlayer seek/queue/speed/info control | nodePath, action |
| `game_create_animation` | Create an animation with tracks and keyframes | nodePath, animationName |
| `game_play_animation` | Control an AnimationPlayer node: play, stop, pause, or list animations | nodePath |
| `game_tween_property` | Tween a node property in the running game | nodePath, property, finalValue |
| `get_animated_sprite_frame` | Get the current frame of an AnimatedSprite in game. | nodePath |
| `get_animation_current` | Get the current animation playing in AnimationPlayer. | nodePath |
| `get_animation_key_count` | Get number of keys on a track in an Animation. | projectPath, animationPath, trackIndex |
| `get_animation_length` | Get the length of an animation from a scene file. | projectPath, scenePath, animationName |
| `get_animation_library_info` | List animations in an AnimationLibrary .tres resource. | projectPath, libraryPath |
| `get_animation_list` | Get list of all animations in an AnimationPlayer node. | nodePath |
| `get_animation_names` | Get all animations from an AnimationPlayer in a scene. | projectPath, scenePath |
| `get_animation_player_blend_time` | Get blend time between two animations. | nodePath, animFrom, animTo |
| `get_animation_player_current_position` | Get current playback position in animation. | nodePath |
| `get_animation_player_list` | List all AnimationPlayers and their animations in game. | None |
| `get_animation_player_queue` | Get the queued animations in AnimationPlayer. | nodePath |
| `get_animation_position` | Get the current playback position of AnimationPlayer. | nodePath |
| `get_animation_track_count` | Get track count in an animation in a scene file. | projectPath, scenePath, animationName |
| `get_current_animation` | Get name of currently playing animation. | nodePath |
| `get_current_animation_state` | Get the current state from AnimationStateMachinePlayback. | nodePath |
| `get_sprite_frame` | Get the current frame of a Sprite2D in the game. | nodePath |
| `get_sprite_frame_info` | Get frame, hframes, vframes from a Sprite2D. | nodePath |
| `get_sprite_frames_info` | Read a SpriteFrames .tres and list animations. | projectPath, spriteFramesPath |
| `is_animation_playing` | Check if an AnimationPlayer is currently playing. | nodePath |
| `list_animations` | Scan a .tscn for AnimationPlayer nodes and return their animation names. | projectPath, scenePath |
| `play_animation_from_position` | Play an animation from a specific time position. | nodePath, animationName |
| `queue_animation` | Queue an animation to play after current one ends. | nodePath, animationName |
| `remove_animation` | Remove an animation from an AnimationPlayer node in a .tscn file. | projectPath, scenePath, animationPlayerPath, animationName |
| `seek_animation` | Seek an AnimationPlayer to a time position in game. | nodePath |
| `seek_animation_player` | Seek animation to a specific time position. | nodePath, position |
| `set_animated_sprite_animation` | Set the animation on AnimatedSprite2D/3D in game. | nodePath, animationName |
| `set_animated_sprite_frame` | Set the frame on an AnimatedSprite in the game. | nodePath |
| `set_animation_blend_time` | Set blend time between animations in AnimationPlayer. | nodePath, fromAnim, toAnim |
| `set_animation_length` | Set the length of a named animation in a scene file. | projectPath, scenePath, animationName, length |
| `set_animation_loop` | Set whether an animation loops in AnimationPlayer. | nodePath, animationName |
| `set_animation_loop_mode` | Set loop mode on an Animation resource. | projectPath, animationPath |
| `set_animation_player_blend_time` | Set blend time between two animations. | nodePath, animFrom, animTo, blendTime |
| `set_animation_speed_scale` | Set the speed_scale on an AnimationPlayer in game. | nodePath |
| `set_sprite_frame` | Set the frame on a Sprite2D in the running game. | nodePath |
| `set_tween_property` | Tween a property on a node to a value in game. | nodePath, property |
| `spriteframes_add_animation` | Add an animation to a SpriteFrames resource (uses headless Godot). | projectPath, spriteframesPath, animationName |
| `start_animation_state` | Start a state in AnimationStateMachinePlayback. | nodePath, stateName |
| `stop_animation_state_machine` | Stop the AnimationStateMachine playback. | nodePath |
| `stop_tween` | Stop all active Tweens on a node in the running game. | nodePath |
| `travel_animation_state` | Travel to a state in AnimationStateMachine. | nodePath, stateName |
| `tween_alpha` | Tween a CanvasItem modulate alpha to a target value. | nodePath |
| `tween_color` | Tween a CanvasItem modulate to a target RGBA color. | nodePath |
| `tween_position_2d` | Tween a Node2D position to target x/y over duration. | nodePath |
| `tween_property` | Tween a node property to a target value over duration. | nodePath, property |
| `tween_rotation_2d` | Tween a Node2D rotation to target angle (radians). | nodePath |
| `tween_scale_2d` | Tween a Node2D scale to target x/y scale values. | nodePath |
| `write_tween_helper_script` | Write a tween animation helper script. | projectPath, scriptPath |
| `write_ui_animation_script` | Write UI show/hide tween animation helpers. | projectPath, scriptPath |

## Audio

| Tool | Description | Required arguments |
|---|---|---|
| `add_audio_bus` | Add a new audio bus with a given name. | None |
| `add_audio_effect_to_bus` | Add an AudioEffect to a named audio bus in game. | effectClass |
| `add_audio_listener_3d` | Add an AudioListener3D node to a scene file. | projectPath, scenePath |
| `add_audio_stream_player` | Add an AudioStreamPlayer node to a scene file. | projectPath, scenePath |
| `add_audio_stream_player_2d` | Add an AudioStreamPlayer2D node to a scene. | projectPath, scenePath |
| `add_audio_stream_player_3d` | Add an AudioStreamPlayer3D node to a scene. | projectPath, scenePath |
| `audio_bus_add_effect` | Add an audio effect to a bus by effect type name. | busName, effectType |
| `audio_bus_create` | Create a new audio bus in the AudioServer. | busName |
| `audio_bus_list` | List all audio buses with their volume and effects. | None |
| `audio_bus_set_volume` | Set the volume of an audio bus in dB. | busName, volumeDb |
| `audio_player_set_bus` | Set the bus of an AudioStreamPlayer in the running game. | nodePath, busName |
| `create_audio_bus` | Create a new named audio bus in the running game. | busName |
| `create_audio_stream_ogg` | Import an OGG file as AudioStreamOggVorbis resource. | projectPath, oggPath, savePath |
| `create_audio_stream_wav` | Create an AudioStreamWAV .tres referencing a .wav file. | projectPath, outputPath, wavPath |
| `create_audio_stream_wav_resource` | Create an AudioStreamWAV resource file. | projectPath, outputPath |
| `game_audio_bus` | Set volume, mute, or solo on an audio bus | None |
| `game_audio_bus_layout` | Create/remove/reorder audio buses and routing | action |
| `game_audio_effect` | Add/remove/configure audio bus effects | action |
| `game_audio_play` | Play, stop, or pause an AudioStreamPlayer node | nodePath |
| `game_audio_spatial` | Configure AudioStreamPlayer3D spatial properties | nodePath, action |
| `game_get_audio` | Get audio bus layout and playing streams | None |
| `get_audio_bus_count` | Get the number of audio buses in the game. | None |
| `get_audio_bus_effect_count` | Get count of effects on an audio bus. | busName |
| `get_audio_bus_effects` | List all AudioEffects on an audio bus in game. | None |
| `get_audio_bus_info` | Get info about an audio bus by index or name. | None |
| `get_audio_bus_list` | Get all audio buses and their volumes from game. | None |
| `get_audio_bus_muted` | Get mute state of an audio bus. | busName |
| `get_audio_bus_name` | Get the name of an audio bus by index in game. | None |
| `get_audio_bus_names` | List names of all audio buses in the project. | None |
| `get_audio_bus_send` | Get the send target bus name of an audio bus. | busIndex |
| `get_audio_bus_solo` | Get solo state of an audio bus. | busName |
| `get_audio_bus_volume_db` | Get the dB volume level of an audio bus. | busName |
| `get_audio_effect_info` | Get type and params of an audio bus effect. | busName, effectIndex |
| `get_audio_player_3d_info` | Get playback info from an AudioStreamPlayer3D. | nodePath |
| `get_audio_setup_guide` | Guide to setting up audio in a Godot project. | None |
| `get_audio_stream_length` | Get duration of AudioStreamPlayer's stream. | nodePath |
| `get_audio_stream_player_position` | Get playback position of AudioStreamPlayer. | nodePath |
| `get_audio_stream_position` | Get the playback position of an AudioStreamPlayer. | nodePath |
| `is_audio_bus_muted` | Check if an audio bus is muted in the game. | busName |
| `list_audio_buses` | List all audio buses in the running game. | None |
| `move_audio_bus` | Move an audio bus to a different index position. | busIndex, toIndex |
| `play_audio_player_3d_at_position` | Play AudioStreamPlayer3D from a world position. | nodePath |
| `remove_audio_bus` | Remove an audio bus by name. | busName |
| `remove_audio_effect_from_bus` | Remove an AudioEffect from an audio bus in game. | busName |
| `seek_audio_stream` | Seek an AudioStreamPlayer to a position in game. | nodePath |
| `set_audio_bus_effect_enabled` | Enable/disable an effect on an audio bus. | None |
| `set_audio_bus_muted` | Set mute state of an audio bus. | busName |
| `set_audio_bus_name` | Set the name of an audio bus by index. | busIndex, name |
| `set_audio_bus_send` | Set which bus an audio bus sends its output to. | busName |
| `set_audio_bus_solo` | Set solo state of an audio bus. | busName |
| `set_audio_bus_volume` | Set an audio bus volume (dB) in the running game. | busName, volumeDb |
| `set_audio_bus_volume_db` | Set the dB volume level of an audio bus. | busName |
| `set_audio_effect_parameter` | Set a parameter on an AudioEffect on a bus in game. | paramName, paramValue |
| `set_audio_pitch_scale` | Set pitch scale of an AudioStreamPlayer node. | nodePath |
| `set_audio_player_3d_doppler` | Set doppler tracking on AudioStreamPlayer3D. | nodePath |
| `set_audio_player_3d_max_distance` | Set max_distance on AudioStreamPlayer3D. | nodePath |
| `set_audio_player_3d_unit_size` | Set unit_size (attenuation) on AudioStreamPlayer3D. | nodePath |
| `set_audio_player_3d_volume` | Set volume dB on an AudioStreamPlayer3D. | nodePath |
| `set_audio_stream_pitch_scale` | Set the pitch_scale on an AudioStreamPlayer in game. | nodePath |
| `set_audio_stream_player_bus` | Set the bus on an AudioStreamPlayer in game. | nodePath, busName |
| `set_audio_stream_player_position` | Seek AudioStreamPlayer to a position. | nodePath |
| `set_audio_stream_player_stream` | Set the stream on an AudioStreamPlayer in game. | nodePath, streamPath |
| `write_audio_manager_script` | Write a singleton audio manager script. | projectPath, scriptPath |

## Files, scripts, and resources

| Tool | Description | Required arguments |
|---|---|---|
| `append_to_file` | Append text to a file in the Godot project. | projectPath, filePath, content |
| `append_to_gdscript_file` | Append code to the end of a .gd script file. | projectPath, scriptPath, code |
| `attach_script` | Attach a GDScript to a scene node (headless) | projectPath, scenePath, nodePath, scriptPath |
| `check_missing_resources` | Find missing ext_resource files referenced in scenes. | projectPath |
| `check_resource_exists` | Check if a resource path exists in a Godot project. | projectPath, resourcePath |
| `copy_file` | Copy a file within the Godot project. | projectPath, sourcePath, destPath |
| `count_gdscript_lines` | Count total lines of GDScript in a project. | projectPath |
| `count_script_lines` | Count lines of code across all GDScript files. | projectPath |
| `create_bitmap_font_resource` | Create a BitmapFont resource from an image. | projectPath, imageFilePath, outputPath |
| `create_curve_resource` | Create a Curve .tres resource with control points. | projectPath, outputPath |
| `create_directory` | Create a directory inside a Godot project | projectPath, directoryPath |
| `create_dynamic_font_resource` | Create a DynamicFont resource from a TTF file. | projectPath, fontFilePath, outputPath |
| `create_gdscript_file` | Create a new GDScript .gd file in the project. | projectPath, scriptPath |
| `create_gdscript_resource` | Create a GDScript resource file from code. | projectPath, scriptPath |
| `create_gradient_texture_resource` | Create a GradientTexture1D resource. | projectPath, outputPath |
| `create_locale_file` | Create a .po locale file template for a given language. | projectPath, language |
| `create_resource` | Create a .tres resource file (headless) | projectPath, resourceType, resourcePath |
| `create_resource_file` | Create a new .tres resource file in the project. | projectPath, resourcePath |
| `create_script` | Create a GDScript file from a template | projectPath, scriptPath |
| `create_tileset_resource` | Create a new TileSet resource file on disk. | projectPath, outputPath |
| `delete_file` | Delete a file from a Godot project | projectPath, filePath |
| `download_file_via_http` | Download a file using HTTPRequest node. | nodePath, url, savePath |
| `evaluate_gdscript_expression` | Evaluate a math expression string in Godot. | expression |
| `find_gdscript_classes` | Find all 'class_name' declarations in GDScript files. | projectPath |
| `find_gdscript_function` | Search for a function definition in project scripts. | projectPath, functionName |
| `find_gdscript_signal_usage` | Find signal connection calls in project scripts. | projectPath, signalName |
| `find_gdscript_signals_defined` | Find all signal definitions across GDScript files. | projectPath |
| `find_large_resources` | Find files exceeding a size threshold in the project. | projectPath |
| `find_orphan_resources` | Find resource files not referenced by any scene. | projectPath |
| `find_orphan_scripts` | Find GDScript files not attached to any scene node. | projectPath |
| `find_orphaned_gdscript_files` | Find .gd files not referenced by any .tscn scene. | projectPath |
| `find_script_references` | Grep all .gd files for a given class name, method name, or string. | projectPath, searchTerm |
| `find_unused_resources` | Find resource files not referenced by any scene or script. | projectPath |
| `game_resource` | Runtime resource load, save, or preload | action, path |
| `game_script` | Attach, detach, or get source of node scripts | nodePath, action |
| `gdscript_string_format` | Run string formatting in Godot (% operator). | template, values |
| `get_editor_filesystem_files` | List files in a folder via the editor filesystem. | None |
| `get_file_content` | Read the content of a text file in a project. | projectPath, filePath |
| `get_file_dependencies` | Get dependencies listed in a scene or resource file. | projectPath, filePath |
| `get_file_size` | Get the byte size of a file in the Godot project. | projectPath, filePath |
| `get_file_stats` | Get file size, modification time for a project file. | projectPath, filePath |
| `get_gdscript_class_hierarchy` | Get inheritance chain of a GDScript class. | projectPath, className |
| `get_gdscript_function_calls` | List all function calls in a GDScript file. | projectPath, scriptPath |
| `get_gdscript_parse_errors` | Use headless Godot to check a script for parse errors. | projectPath, scriptPath |
| `get_import_file` | Read the .import file for an asset and return settings. | projectPath, assetPath |
| `get_resource_file_content` | Read the raw content of a resource or script file. | projectPath, filePath |
| `get_resource_file_info` | Read metadata from a .tres resource file. | projectPath, resourcePath |
| `get_resource_import_metadata` | Get import metadata for an imported asset. | projectPath, filePath |
| `get_resource_type` | Read a .tres resource file and return its type and props. | projectPath, resourcePath |
| `get_resource_uid` | Get the UID of a resource from its .uid sidecar file. | projectPath, resourcePath |
| `get_resource_usage` | Find all scenes that reference a specific resource. | projectPath, resourcePath |
| `get_script_class_info` | Extract class info (methods, signals, vars) from a GDScript file. | projectPath, scriptPath |
| `get_script_constants` | Extract all const declarations from a GDScript file. | projectPath, scriptPath |
| `get_script_signals` | Extract all signal declarations from a GDScript file. | projectPath, scriptPath |
| `get_script_source` | Get the source code of a script in the running game. | nodePath |
| `get_script_variables` | List all var declarations in a GDScript file. | projectPath, scriptPath |
| `inspect_resource_properties` | Inspect all properties of a resource file. | projectPath, resourcePath |
| `list_gdscript_classes` | List all ClassDB class names via headless Godot. | projectPath |
| `list_import_files` | Find all .import files in the project directory. | projectPath |
| `list_resource_types` | List all .tres and .res resource files grouped by type. | projectPath |
| `list_resources_of_type` | List all resources of a given class type. | projectPath, resourceType |
| `list_scripts` | Recursively list all .gd files in a project. | projectPath |
| `list_uid_files` | Find all .uid sidecar files in the project directory. | projectPath |
| `manage_resource` | Read or modify .tres/.res resource files | projectPath, resourcePath, action |
| `manage_theme_resource` | Create/read/modify Theme .tres resources | projectPath, resourcePath, action |
| `merge_json_file` | Merge data into an existing JSON file (shallow). | projectPath, filePath, data |
| `read_file` | Read a text file from a Godot project | projectPath, filePath |
| `read_gdscript_file` | Read the full content of a GDScript file. | projectPath, scriptPath |
| `read_json_file` | Read and parse a JSON file from the project. | projectPath, filePath |
| `reload_script_at_runtime` | Hot-reload a GDScript file in the running game. | scriptPath |
| `rename_file` | Rename or move a file within the project | projectPath, filePath, newPath |
| `rename_resource` | Rename or move a resource file within the project. | projectPath, sourcePath, destPath |
| `replace_in_file` | Replace all occurrences of a string in a file. | projectPath, filePath, search, replacement |
| `resource_set_property` | Set a property value in a .tres resource file. | projectPath, resourcePath, propertyName, propertyValue |
| `script_template` | Generate a GDScript template file for a Godot base class. | projectPath, scriptPath, baseClass |
| `search_in_file` | Search for a pattern in a project file. | projectPath, filePath, pattern |
| `search_in_files` | Grep for a pattern across project files. | projectPath, pattern |
| `search_in_gdscript_files` | Search for a pattern string in all GDScript files. | projectPath, searchText |
| `search_in_scripts` | Search for a pattern across all GDScript files. | projectPath, pattern |
| `validate_script` | Run godot --headless --check-only on a GDScript file to parse-check it. | projectPath, scriptPath |
| `write_ability_cooldown_script` | Write an ability cooldown tracker script. | projectPath, scriptPath |
| `write_achievement_system_script` | Write a basic achievement tracker script. | projectPath, scriptPath |
| `write_ai_follow_player_script` | Write an AI that follows the player (2D). | projectPath, scriptPath |
| `write_area_2d_detector_script` | Write an Area2D enter/exit detector script. | projectPath, scriptPath |
| `write_area_trigger_script` | Write an Area2D trigger zone script. | projectPath, scriptPath |
| `write_boomerang_script` | Write a boomerang/returning projectile script. | projectPath, scriptPath |
| `write_boss_enemy_script` | Write a boss enemy with phases script. | projectPath, scriptPath |
| `write_buff_debuff_system_script` | Write a timed buff/debuff effect system. | projectPath, scriptPath |
| `write_bullet_pool_script` | Write an object pool for bullets/projectiles. | projectPath, scriptPath |
| `write_card_game_base_script` | Write a base card game hand/deck script. | projectPath, scriptPath |
| `write_checkpoint_script` | Write a checkpoint/respawn point GDScript. | projectPath, scriptPath |
| `write_checkpoint_system_script` | Write a checkpoint/respawn system. | projectPath, scriptPath |
| `write_chunk_loading_script` | Write a chunk-based world loading system. | projectPath, scriptPath |
| `write_climbing_system_script` | Write a ledge climbing/wall-grab script. | projectPath, scriptPath |
| `write_coin_script` | Write a collectible coin/currency GDScript. | projectPath, scriptPath |
| `write_combo_system_script` | Write a combo counter system script. | projectPath, scriptPath |
| `write_console_command_script` | Write an in-game debug console command system. | projectPath, scriptPath |
| `write_consumable_item_script` | Write a consumable pickup item script. | projectPath, scriptPath |
| `write_conveyor_belt_script` | Write a conveyor belt velocity adder script. | projectPath, scriptPath |
| `write_coyote_time_script` | Write coyote time for CharacterBody2D jumps. | projectPath, scriptPath |
| `write_crafting_system_script` | Write a crafting system with recipe support. | projectPath, scriptPath |
| `write_crosshair_script` | Write a 2D crosshair that follows the mouse. | projectPath, scriptPath |
| `write_currency_system_script` | Write a currency system with transactions. | projectPath, scriptPath |
| `write_dash_ability_script` | Write a dash ability for CharacterBody2D. | projectPath, scriptPath |
| `write_data_persistence_script` | Write a JSON-based data persistence system. | projectPath, scriptPath |
| `write_day_night_cycle_script` | Write a day/night cycle environment controller. | projectPath, scriptPath |
| `write_debug_overlay_script` | Write a debug info overlay panel script. | projectPath, scriptPath |
| `write_destructible_object_script` | Write a destructible/breakable object script. | projectPath, scriptPath |
| `write_destructible_terrain_script` | Write a grid-based destructible terrain. | projectPath, scriptPath |
| `write_dialogue_npc_script` | Write an NPC dialogue trigger script. | projectPath, scriptPath |
| `write_dialogue_script` | Write a simple dialogue/cutscene manager script. | projectPath, scriptPath |
| `write_dialogue_system_script` | Write a simple dialogue box display script. | projectPath, scriptPath |
| `write_door_script` | Write a door/gate open/close GDScript. | projectPath, scriptPath |
| `write_double_buff_pickup_script` | Write a double-damage pickup item script. | projectPath, scriptPath |
| `write_double_jump_script` | Write a double-jump CharacterBody2D script. | projectPath, scriptPath |
| `write_drag_drop_slot_script` | Write a drag-and-drop item slot UI script. | projectPath, scriptPath |
| `write_enemy_patrol_script` | Write a simple enemy patrol/chase AI script. | projectPath, scriptPath |
| `write_enemy_spawner_wave_script` | Write a wave-based enemy spawner script. | projectPath, scriptPath |
| `write_enemy_state_machine_script` | Write an AI enemy with state machine. | projectPath, scriptPath |
| `write_event_bus_script` | Write a global event bus/signal router script. | projectPath, scriptPath |
| `write_experience_level_script` | Write an XP/level progression system. | projectPath, scriptPath |
| `write_explosion_script` | Write an explosion area damage script. | projectPath, scriptPath |
| `write_fan_push_script` | Write an Area2D wind/fan push force script. | projectPath, scriptPath |
| `write_file` | Create or overwrite a text file in a Godot project | projectPath, filePath, content |
| `write_file_content` | Write content to a file in the project. | projectPath, filePath, content |
| `write_floating_text_script` | Write a floating damage/score text script. | projectPath, scriptPath |
| `write_fog_of_war_script` | Write a simple fog of war masking script. | projectPath, scriptPath |
| `write_footstep_system_script` | Write a footstep sound system for CharacterBody. | projectPath, scriptPath |
| `write_fov_cone_script` | Write a field-of-view cone detection script. | projectPath, scriptPath |
| `write_fps_counter_script` | Write an FPS counter Label script. | projectPath, scriptPath |
| `write_freeze_time_script` | Write a time freeze / slow motion script. | projectPath, scriptPath |
| `write_game_manager_script` | Write a main GameManager Autoload script. | projectPath, scriptPath |
| `write_game_over_screen_script` | Write a game over screen with retry button. | projectPath, scriptPath |
| `write_game_settings_script` | Write a game settings save/load Autoload. | projectPath, scriptPath |
| `write_gamepad_rumble_script` | Write a gamepad haptic rumble helper. | projectPath, scriptPath |
| `write_global_events_script` | Write typed global events with data payloads. | projectPath, scriptPath |
| `write_grappling_hook_script` | Write a grappling hook mechanic script. | projectPath, scriptPath |
| `write_gravity_zone_script` | Write a gravity manipulation zone script. | projectPath, scriptPath |
| `write_grid_based_movement_script` | Write a grid-based movement controller. | projectPath, scriptPath |
| `write_grid_movement_script` | Write a grid-based movement controller script. | projectPath, scriptPath |
| `write_grid_snap_script` | Write a grid-snap drag-and-drop script. | projectPath, scriptPath |
| `write_health_bar_script` | Write a health bar UI script for ProgressBar. | projectPath, scriptPath |
| `write_health_component_script` | Write a reusable health component node. | projectPath, scriptPath |
| `write_health_regeneration_script` | Write a health regen over time script. | projectPath, scriptPath |
| `write_health_system_script` | Write a reusable health system GDScript. | projectPath, scriptPath |
| `write_hit_flash_script` | Write a hit flash visual feedback script. | projectPath, scriptPath |
| `write_hitbox_hurtbox_script` | Write hitbox and hurtbox Area2D scripts. | projectPath, scriptPath |
| `write_hitbox_script` | Write a hitbox/hurtbox script for combat. | projectPath, scriptPath |
| `write_homing_missile_script` | Write a homing missile projectile script. | projectPath, scriptPath |
| `write_hotbar_ui_script` | Write a hotbar item slots UI script. | projectPath, scriptPath |
| `write_hud_script` | Write a HUD/UI update script that reacts to signals. | projectPath, scriptPath |
| `write_input_buffer_script` | Write an input buffer for frame-perfect input. | projectPath, scriptPath |
| `write_input_handler_script` | Write a centralized input handler GDScript. | projectPath, scriptPath |
| `write_input_remapping_script` | Write an input remapping UI helper script. | projectPath, scriptPath |
| `write_interactable_object_script` | Write an E-to-interact object script. | projectPath, scriptPath |
| `write_interactable_script` | Write an interactable object script (press E to use). | projectPath, scriptPath |
| `write_interaction_prompt_script` | Write a floating interaction prompt UI. | projectPath, scriptPath |
| `write_inventory_script` | Write a simple inventory/item system GDScript. | projectPath, scriptPath |
| `write_inventory_system_script` | Write a simple inventory system script. | projectPath, scriptPath |
| `write_item_pickup_script` | Write an item pickup Area2D script. | projectPath, scriptPath |
| `write_json_file` | Write data as a JSON file into the project. | projectPath, filePath |
| `write_key_door_system_script` | Write a key-and-door unlock system script. | projectPath, scriptPath |
| `write_ladder_script` | Write a ladder climb interaction script. | projectPath, scriptPath |
| `write_leaderboard_script` | Write a local leaderboard save/load script. | projectPath, scriptPath |
| `write_level_manager_script` | Write a level progression manager script. | projectPath, scriptPath |
| `write_loading_screen_script` | Write a threaded loading screen script. | projectPath, scriptPath |
| `write_localization_helper_script` | Write a tr() wrapper localization helper. | projectPath, scriptPath |
| `write_loot_drop_script` | Write a random loot drop spawner script. | projectPath, scriptPath |
| `write_loot_table_script` | Write a weighted loot table drop system. | projectPath, scriptPath |
| `write_magnet_attract_script` | Write a magnetic coin/item attractor script. | projectPath, scriptPath |
| `write_match_3_board_script` | Write a match-3 game board logic script. | projectPath, scriptPath |
| `write_minimap_dot_script` | Write a minimap dot marker component. | projectPath, scriptPath |
| `write_minimap_icon_script` | Write a minimap icon tracker for Node2D. | projectPath, scriptPath |
| `write_minimap_script` | Write a simple minimap display script. | projectPath, scriptPath |
| `write_minimap_ui_script` | Write a viewport-based minimap UI panel. | projectPath, scriptPath |
| `write_moving_platform_script` | Write a moving platform between two points. | projectPath, scriptPath |
| `write_notification_system_script` | Write a toast notification UI system. | projectPath, scriptPath |
| `write_notifications_ui_script` | Write a UI notification popup manager script. | projectPath, scriptPath |
| `write_object_pool_script` | Write a generic object pooling GDScript. | projectPath, scriptPath |
| `write_object_pooling_script` | Write an object pool for performance script. | projectPath, scriptPath |
| `write_options_menu_script` | Write an options/settings menu control script. | projectPath, scriptPath |
| `write_parachute_script` | Write a parachute slow-fall script. | projectPath, scriptPath |
| `write_parallax_background_script` | Write a parallax scrolling background. | projectPath, scriptPath |
| `write_parallax_layer_script` | Write a parallax scrolling background script. | projectPath, scriptPath |
| `write_pathfinding_agent_2d_script` | Write an AI agent using NavigationAgent2D. | projectPath, scriptPath |
| `write_pathfinding_agent_script` | Write a NavigationAgent2D-based pathfinding script. | projectPath, scriptPath |
| `write_pause_menu_script` | Write a pause menu CanvasLayer script. | projectPath, scriptPath |
| `write_pickup_script` | Write a 2D item pickup/collectible GDScript. | projectPath, scriptPath |
| `write_platform_moving_script` | Write a moving platform GDScript. | projectPath, scriptPath |
| `write_platformer_ground_script` | Write script for a static ground/platform body. | projectPath, scriptPath |
| `write_platformer_player_script` | Write a full platformer player controller. | projectPath, scriptPath |
| `write_player_3d_controller_script` | Write a CharacterBody3D FPS controller script. | projectPath, scriptPath |
| `write_player_controller_script` | Write a CharacterBody2D player controller script. | projectPath, scriptPath |
| `write_pressure_plate_script` | Write a pressure plate trigger script. | projectPath, scriptPath |
| `write_procedural_dungeon_script` | Write a simple procedural dungeon generator. | projectPath, scriptPath |
| `write_pushback_script` | Write a knockback/pushback force script. | projectPath, scriptPath |
| `write_quest_manager_script` | Write a quest manager singleton script. | projectPath, scriptPath |
| `write_quest_system_script` | Write a quest tracking system Autoload script. | projectPath, scriptPath |
| `write_ragdoll_setup_script` | Write a ragdoll physics setup helper script. | projectPath, scriptPath |
| `write_random_map_generator_script` | Write a procedural tile map generator. | projectPath, scriptPath |
| `write_resource_class_script` | Write a custom Resource class script. | projectPath, scriptPath |
| `write_resource_file_content` | Write raw content to a resource or script file. | projectPath, filePath, content |
| `write_resource_gathering_script` | Write a resource gathering/mining node script. | projectPath, scriptPath |
| `write_resource_loader_script` | Write an async resource preloader script. | projectPath, scriptPath |
| `write_resource_preloader_script` | Write a resource preloading helper script. | projectPath, scriptPath |
| `write_respawn_system_script` | Write a player respawn system script. | projectPath, scriptPath |
| `write_rpg_stats_script` | Write an RPG character stats (ATK/DEF/HP) script. | projectPath, scriptPath |
| `write_rpg_stats_system_script` | Write an RPG stats (STR/AGI/INT) system. | projectPath, scriptPath |
| `write_save_load_script` | Write a save/load game data GDScript (JSON). | projectPath, scriptPath |
| `write_save_load_system_script` | Write a save/load system with JSON. | projectPath, scriptPath |
| `write_save_screenshot_script` | Write a screenshot capture and save script. | projectPath, scriptPath |
| `write_score_manager_script` | Write a score manager autoload GDScript. | projectPath, scriptPath |
| `write_screen_border_teleport_script` | Write screen-wrap teleport for objects. | projectPath, scriptPath |
| `write_screen_flash_script` | Write a screen flash ColorRect overlay. | projectPath, scriptPath |
| `write_screen_shake_2d_script` | Write a 2D camera screen shake effect. | projectPath, scriptPath |
| `write_screen_shake_script` | Write a screen shake camera effect script. | projectPath, scriptPath |
| `write_shadow_clone_script` | Write a shadow afterimage clone script. | projectPath, scriptPath |
| `write_shield_system_script` | Write a rechargeable shield system script. | projectPath, scriptPath |
| `write_shockwave_script` | Write a shockwave radius damage script. | projectPath, scriptPath |
| `write_shop_system_script` | Write a basic shop/purchase system script. | projectPath, scriptPath |
| `write_signal_bus_script` | Write a global signal bus Autoload node. | projectPath, scriptPath |
| `write_simple_enemy_patrol_script` | Write a basic patrolling enemy AI script. | projectPath, scriptPath |
| `write_singleton_autoload_script` | Write a singleton/autoload GDScript template. | projectPath, scriptPath |
| `write_singleton_with_events_script` | Write an event bus singleton Autoload. | projectPath, scriptPath |
| `write_slide_puzzle_script` | Write a slide puzzle game logic script. | projectPath, scriptPath |
| `write_spawner_script` | Write a node spawner/instancer script. | projectPath, scriptPath |
| `write_speed_boost_pad_script` | Write a speed boost pad trigger script. | projectPath, scriptPath |
| `write_speed_boost_script` | Write a speed boost zone script. | projectPath, scriptPath |
| `write_spike_trap_script` | Write a spike trap damage trigger script. | projectPath, scriptPath |
| `write_sprite_outline_script` | Write a shader-based sprite outline script. | projectPath, scriptPath |
| `write_stamina_system_script` | Write a sprint stamina system script. | projectPath, scriptPath |
| `write_state_machine_base_script` | Write a reusable generic state machine base. | projectPath, scriptPath |
| `write_state_machine_script` | Write a generic state machine GDScript template. | projectPath, scriptPath |
| `write_status_bar_ui_script` | Write a generic status bar (health/xp) UI. | projectPath, scriptPath |
| `write_status_effect_script` | Write a status effect (burn/freeze/stun) script. | projectPath, scriptPath |
| `write_stealth_detection_script` | Write a stealth/alert detection script. | projectPath, scriptPath |
| `write_sticky_bomb_script` | Write a sticky bomb that attaches to nodes. | projectPath, scriptPath |
| `write_swimming_controller_script` | Write an underwater swimming controller. | projectPath, scriptPath |
| `write_throwable_object_script` | Write a throwable RigidBody2D object. | projectPath, scriptPath |
| `write_timer_helper_script` | Write a countdown/interval timer helper script. | projectPath, scriptPath |
| `write_timer_manager_script` | Write a reusable timer helper Autoload script. | projectPath, scriptPath |
| `write_tooltip_system_script` | Write a hover tooltip system script. | projectPath, scriptPath |
| `write_top_down_player_script` | Write a top-down CharacterBody2D player script. | projectPath, scriptPath |
| `write_top_down_shooter_script` | Write a top-down shooter player script. | projectPath, scriptPath |
| `write_tornado_force_script` | Write a spinning tornado force field script. | projectPath, scriptPath |
| `write_tower_defense_base_script` | Write a tower defense tower base script. | projectPath, scriptPath |
| `write_trail_script` | Write a Line2D motion trail effect script. | projectPath, scriptPath |
| `write_trigger_zone_script` | Write a trigger zone (Area2D) activation script. | projectPath, scriptPath |
| `write_turn_based_battle_script` | Write a turn-based battle manager script. | projectPath, scriptPath |
| `write_turn_based_combat_script` | Write a turn-based combat manager script. | projectPath, scriptPath |
| `write_vehicle_controller_script` | Write a VehicleBody3D car controller script. | projectPath, scriptPath |
| `write_vfx_manager_script` | Write a VFX/particle effect manager Autoload. | projectPath, scriptPath |
| `write_vfx_spawn_script` | Write a VFX spawner on death/hit script. | projectPath, scriptPath |
| `write_wall_jump_script` | Write a wall-jump CharacterBody2D script. | projectPath, scriptPath |
| `write_water_buoyancy_script` | Write a buoyancy physics Area2D script. | projectPath, scriptPath |
| `write_wave_spawner_script` | Write an enemy wave spawner script. | projectPath, scriptPath |
| `write_waypoint_patrol_script` | Write an AI waypoint patrol movement script. | projectPath, scriptPath |
| `write_weather_system_script` | Write a weather/environment controller script. | projectPath, scriptPath |
| `write_xp_level_system_script` | Write an XP/level progression system script. | projectPath, scriptPath |
| `write_zipline_script` | Write a zipline character mover script. | projectPath, scriptPath |

## Navigation and editor

| Tool | Description | Required arguments |
|---|---|---|
| `connect_to_godot_editor` | Connect to Godot editor plugin on port 9091. | None |
| `disconnect_from_godot_editor` | Disconnect from the Godot editor plugin. | None |
| `editor_add_node` | Add a node to the scene in Godot editor. | nodeType |
| `editor_attach_script` | Attach a script to a node in Godot editor. | nodePath, scriptPath |
| `editor_create_scene` | Create a new scene in Godot editor. | None |
| `editor_create_script` | Create a new GDScript file in Godot editor. | scriptPath |
| `editor_delete_node` | Delete the selected node in Godot editor. | None |
| `editor_duplicate_node` | Duplicate a node in the Godot editor. | None |
| `editor_focus_node` | Focus/center the viewport on a node in editor. | nodePath |
| `editor_get_filesystem_files` | List files in the Godot editor filesystem. | None |
| `editor_get_node_property` | Get a node property value in Godot editor. | nodePath, property |
| `editor_get_scene_info` | Get info about the currently open scene in editor. | None |
| `editor_get_scene_tree` | Get the full scene tree from Godot editor. | None |
| `editor_get_selected_node` | Get the currently selected node in Godot editor. | None |
| `editor_move_node` | Move a node to a new parent in Godot editor. | nodePath, newParentPath |
| `editor_open_scene` | Open a scene file in the Godot editor. | scenePath |
| `editor_redo` | Redo the last undone action in Godot editor. | None |
| `editor_reimport_file` | Reimport a file in the Godot editor filesystem. | filePath |
| `editor_run_scene` | Run the current scene from Godot editor. | None |
| `editor_save_scene` | Save the current scene in Godot editor. | None |
| `editor_select_node` | Select a node by path in the Godot editor. | nodePath |
| `editor_select_node_by_path` | Select a node in the editor scene tree. | nodePath |
| `editor_set_node_property` | Set a node property value in Godot editor. | nodePath, property, value |
| `editor_stop_scene` | Stop the running scene from Godot editor. | None |
| `editor_undo` | Undo the last action in Godot editor. | None |
| `explain_godot_concept` | Explain a Godot concept: Area2D, signals, scenes, etc. | concept |
| `get_beginner_guide` | Get a start-here guide covering common game dev workflows. | None |
| `get_godot_project_settings` | Read project.godot settings as key-value pairs. | projectPath |
| `get_godot_version` | Get the installed Godot version | None |
| `get_project_godot_version` | Get Godot version from project.godot file. | projectPath |
| `get_workflow` | Get step-by-step tool sequence for a goal (e.g. platformer). | goal |
| `godot_call` | Call one tool or execute a guarded multi-tool sequence. | None |
| `godot_start_here` | START HERE: Overview and how to use this MCP server with 1969 tools. | None |
| `godot_suggest` | Get tool suggestions for a natural language task description. | task |
| `list_tool_categories` | List all categories to navigate 1000+ tools efficiently. | None |
| `list_tools_in_category` | List all tools in a category. Call list_tool_categories first. | category |
| `print_to_godot_console` | Print a message to the Godot output console in game. | message |
| `search_tools` | Search tools by keyword in tool names. | query |

## Physics

| Tool | Description | Required arguments |
|---|---|---|
| `add_collision_shape_2d` | Add a CollisionShape2D to a physics body in a scene. | projectPath, scenePath, parentNodePath |
| `add_collision_shape_3d` | Add a CollisionShape3D to a physics body in a scene. | projectPath, scenePath, parentNodePath |
| `add_cone_twist_joint_3d` | Add a ConeTwistJoint3D node to a 3D scene file. | projectPath, scenePath |
| `add_generic_6dof_joint_3d` | Add a Generic6DOFJoint3D node to a 3D scene file. | projectPath, scenePath |
| `add_hinge_joint_3d` | Add a HingeJoint3D node to a 3D scene file. | projectPath, scenePath |
| `add_joint_2d` | Add a PinJoint2D node to a 2D scene file. | projectPath, scenePath |
| `add_rigid_body_2d` | Add a RigidBody2D node to a scene file. | projectPath, scenePath |
| `add_rigid_body_3d` | Add a RigidBody3D node to a scene file. | projectPath, scenePath |
| `add_slider_joint_3d` | Add a SliderJoint3D node to a 3D scene file. | projectPath, scenePath |
| `add_tileset_physics_layer` | Add a physics layer to a TileSet resource. | projectPath, tileSetPath |
| `apply_force_to_rigid_body` | Apply a constant force to a RigidBody in game. | nodePath |
| `apply_impulse_to_rigid_body` | Apply a linear impulse to a RigidBody in the game. | nodePath, x, y |
| `create_physics_material` | Create a PhysicsMaterial .tres resource file. | projectPath, outputPath |
| `enable_physics_body` | Enable/disable a physics body collision detection. | nodePath |
| `game_add_collision` | Add a collision shape to a physics body node | parentPath, shapeType |
| `game_create_joint` | Create a physics joint between two bodies | parentPath, jointType |
| `game_physics_2d` | Area2D queries and 2D point/shape intersections | action |
| `game_physics_3d` | Area3D queries and point/shape intersection tests | action |
| `game_physics_body` | Configure physics body properties (mass, velocity, etc.) | nodePath |
| `game_raycast` | Cast a ray and return collision results | from, to |
| `get_2d_collision_layers_names` | Get collision layer/mask names from project. | None |
| `get_collision_layer_mask` | Get collision layer and mask of a physics body. | nodePath |
| `get_collision_layer_names` | Get physics collision layer names from project settings. | projectPath |
| `get_collision_layers_names` | Read collision layer names from project.godot. | projectPath |
| `get_collision_shape_info` | Get collision shape info from a physics body in the game. | nodePath |
| `get_cone_twist_joint_3d_info` | Get ConeTwistJoint3D swing/twist span values. | nodePath |
| `get_damped_spring_joint_2d_info` | Get DampedSpringJoint2D stiffness, rest length. | nodePath |
| `get_generic_6dof_joint_info` | Get Generic6DOFJoint3D linear/angular limits. | nodePath |
| `get_groove_joint_2d_info` | Get GrooveJoint2D length and initial offset. | nodePath |
| `get_hinge_joint_3d_info` | Get HingeJoint3D parameter values. | nodePath |
| `get_physics_bodies` | List all physics bodies in the running game scene. | None |
| `get_physics_bodies_at_point` | Get 3D physics bodies at a point in the game. | None |
| `get_physics_bodies_in_area` | Get overlapping bodies in an Area3D in the game. | nodePath |
| `get_physics_body_3d_collision_layer` | Get collision layer of a 3D physics body. | nodePath |
| `get_physics_body_3d_collision_mask` | Get collision mask of a 3D physics body. | nodePath |
| `get_physics_body_collision_layer` | Get collision layer of a physics body. | nodePath |
| `get_physics_body_collision_mask` | Get collision mask of a physics body. | nodePath |
| `get_physics_body_state` | Get physics state of a body: position, velocity, sleeping. | nodePath |
| `get_physics_direct_body_state_3d` | Get linear/angular velocity of a body. | nodePath |
| `get_physics_fps` | Get physics ticks per second from the game. | None |
| `get_physics_info` | Get physics info: active bodies, collision pairs. | None |
| `get_physics_interpolation_mode` | Get the physics interpolation mode of a node. | nodePath |
| `get_physics_layers` | Get physics body collision layer masks from a node. | nodePath |
| `get_physics_server_info` | Get physics server active body count info. | None |
| `get_physics_settings` | Read physics settings from project.godot. | projectPath |
| `get_pin_joint_2d_info` | Get PinJoint2D node softness and node paths. | nodePath |
| `get_ray_cast_2d_collision` | Get collision result of a RayCast2D node. | nodePath |
| `get_ray_cast_3d_collision` | Get collision result of a RayCast3D node. | nodePath |
| `get_rigid_body_2d_info` | Get mass, velocity, freeze state of RigidBody2D. | nodePath |
| `get_rigid_body_3d_info` | Get mass, velocity, linear damp of RigidBody3D. | nodePath |
| `get_rigid_body_3d_state` | Get full physics state of a RigidBody3D node. | nodePath |
| `get_rigid_body_linear_velocity` | Get linear velocity of a RigidBody in the game. | nodePath |
| `get_slider_joint_3d_info` | Get SliderJoint3D parameter values. | nodePath |
| `raycast_3d` | Perform a 3D physics raycast in the running game. | None |
| `rigid_body_apply_impulse` | Apply an impulse to a RigidBody in the running game. | nodePath, x, y |
| `set_collision_box_3d_size` | Set size of BoxShape3D in a CollisionShape3D. | projectPath, scenePath, nodeName |
| `set_collision_capsule_2d` | Set radius/height of CapsuleShape2D in scene. | projectPath, scenePath, nodeName |
| `set_collision_capsule_3d` | Set radius/height of CapsuleShape3D in scene. | projectPath, scenePath, nodeName |
| `set_collision_layer` | Set collision_layer on a physics node in the game. | nodePath, layer |
| `set_collision_layer_name` | Set the name of a physics layer in project settings. | projectPath, layerNumber, layerName |
| `set_collision_mask` | Set collision_mask on a physics node in the game. | nodePath, mask |
| `set_collision_rect_extents` | Set extents of RectangleShape2D in CollisionShape2D. | projectPath, scenePath, nodeName |
| `set_collision_shape_2d_radius` | Set radius of a CircleShape2D in a CollisionShape2D. | projectPath, scenePath, nodeName |
| `set_collision_shape_2d_type` | Change type of CollisionShape2D (circle/rect/capsule). | projectPath, scenePath, nodeName, shapeType |
| `set_collision_shape_3d_type` | Change type of CollisionShape3D (box/sphere/capsule). | projectPath, scenePath, nodeName, shapeType |
| `set_collision_shape_disabled` | Enable or disable a CollisionShape2D/3D node. | nodePath |
| `set_collision_sphere_3d_radius` | Set radius of SphereShape3D in CollisionShape3D. | projectPath, scenePath, nodeName |
| `set_damped_spring_joint_2d_stiffness` | Set DampedSpringJoint2D stiffness. | nodePath, stiffness |
| `set_physics_body_3d_collision_layer` | Set collision layer of a 3D physics body. | nodePath |
| `set_physics_body_3d_collision_mask` | Set collision mask of a 3D physics body. | nodePath |
| `set_physics_body_collision_layer` | Set collision layer of a physics body. | nodePath |
| `set_physics_body_collision_mask` | Set collision mask of a physics body. | nodePath |
| `set_physics_fps` | Set physics ticks per second in the running game. | None |
| `set_physics_layers` | Set collision layer and mask on a physics body. | nodePath |
| `set_pin_joint_2d_softness` | Set PinJoint2D softness value. | nodePath, softness |
| `set_rigid_body_2d_freeze` | Freeze or unfreeze a RigidBody2D node. | nodePath |
| `set_rigid_body_2d_gravity_scale` | Set gravity scale on a RigidBody2D node. | nodePath |
| `set_rigid_body_2d_mass` | Set mass on a RigidBody2D node. | nodePath |
| `set_rigid_body_3d_freeze` | Freeze or unfreeze a RigidBody3D node. | nodePath |
| `set_rigid_body_3d_gravity_scale` | Set gravity scale on a RigidBody3D node. | nodePath |
| `set_rigid_body_3d_mass` | Set mass on a RigidBody3D node. | nodePath |
| `set_rigid_body_3d_sleeping` | Set sleeping state of a RigidBody3D node. | nodePath |
| `set_rigid_body_freeze` | Freeze or unfreeze a RigidBody node in the game. | nodePath, freeze |
| `set_rigid_body_linear_velocity` | Set linear velocity of a RigidBody in the game. | nodePath |
| `set_rigid_body_sleeping` | Set a RigidBody sleep state in the running game. | nodePath |
| `write_rope_physics_script` | Write a simple rope chain physics script. | projectPath, scriptPath |

## Project and release

| Tool | Description | Required arguments |
|---|---|---|
| `add_input_action_to_project` | Add an input action entry to project.godot file. | projectPath, actionName, key |
| `compare_project_settings` | Compare two project.godot files and report setting differences. | projectPath, otherProjectPath |
| `copy_project_file` | Copy a file within a Godot project directory. | projectPath, sourcePath, destPath |
| `create_project` | Create a new Godot project from scratch | projectPath, projectName |
| `create_project_directory` | Create a directory inside a Godot project. | projectPath, dirPath |
| `delete_project_file` | Delete a file from a Godot project directory. | projectPath, filePath |
| `export_list_presets` | List all export presets defined in export_presets.cfg. | projectPath |
| `export_mesh_library` | Export a scene as a MeshLibrary resource | projectPath, scenePath, outputPath |
| `export_project` | Export the project using a named export preset. | projectPath, presetName, outputPath |
| `file_exists_in_project` | Check if a file exists in the Godot project. | projectPath, filePath |
| `find_gdscript_exports` | Find all @export variables across GDScript files. | projectPath |
| `find_orphaned_project_files` | Find project assets not referenced by scenes, scripts, or settings. | projectPath |
| `get_all_node_types_in_project` | Count all node types used across the whole project. | projectPath |
| `get_input_map_from_project` | Read input action map from project.godot file. | projectPath |
| `get_project_autoloads` | Read autoload entries from project.godot file. | projectPath |
| `get_project_build_summary` | Get a comprehensive health summary of the Godot project. | projectPath |
| `get_project_description` | Get app description from project.godot. | projectPath |
| `get_project_directory_structure` | Get top-level directory structure of a project. | projectPath |
| `get_project_export_presets` | Read export_presets.cfg from a project. | projectPath |
| `get_project_file_stats` | Get aggregate file statistics for the project. | projectPath |
| `get_project_health_report` | Audit project files and report missing resource references. | projectPath |
| `get_project_info` | Retrieve metadata about a Godot project | projectPath |
| `get_project_layers` | Get layer names (physics, render, nav) from project.godot. | projectPath |
| `get_project_main_scene` | Get the main scene path from project.godot. | projectPath |
| `get_project_name` | Get the application name from project.godot. | projectPath |
| `get_project_plugins` | List enabled editor plugins in project.godot. | projectPath |
| `get_project_scene_list` | List all .tscn and .scn scene files in project. | projectPath |
| `get_project_setting` | Get a specific setting by key from project.godot. | projectPath, settingKey |
| `get_project_settings_by_category` | Get all project settings in a specific config section. | projectPath, category |
| `get_project_statistics` | Return project-wide stats: scenes, scripts, nodes, lines, plugins. | projectPath |
| `get_project_structure` | Get a tree of directories in a Godot project. | projectPath |
| `get_project_total_size` | Calculate total size of project files in bytes. | projectPath |
| `get_project_uid_map` | List uid:// mappings from the .godot uid_cache. | projectPath |
| `get_project_version` | Get the Godot version requirement from project.godot. | projectPath |
| `get_project_window_size` | Get window width/height from project.godot. | projectPath |
| `get_script_exported_properties` | Get exported vars of a GDScript script file. | projectPath, scriptPath |
| `launch_editor` | Launch Godot editor for a specific project | projectPath |
| `list_export_presets` | List all export presets in export_presets.cfg. | projectPath |
| `list_export_variables` | List all @export variables across all GDScript files. | projectPath |
| `list_exported_variables` | List all @export variables across all GDScript files. | projectPath |
| `list_project_3d_models` | Find all 3D model files in the project directory. | projectPath |
| `list_project_audio` | List all audio files (.wav, .ogg, .mp3) in the project. | projectPath |
| `list_project_audio_files` | List audio files (ogg/mp3/wav) in a project. | projectPath |
| `list_project_autoloads` | List all autoloads defined in project.godot. | projectPath |
| `list_project_files` | List project files, optionally filtered by extension | projectPath |
| `list_project_files_by_extension` | List project files with a given extension. | projectPath, extension |
| `list_project_fonts` | List all font files (.ttf, .otf, .fnt) in the project. | projectPath |
| `list_project_gdscript_files` | List all GDScript files in a Godot project. | projectPath |
| `list_project_images` | List all image files in the project directory. | projectPath |
| `list_project_import_files` | List all .import files in a Godot project. | projectPath |
| `list_project_meshes` | Find all mesh files in the project directory. | projectPath |
| `list_project_resources` | List all .tres and .res resource files in project. | projectPath |
| `list_project_scenes` | List all .tscn scene files in the project. | projectPath |
| `list_project_scripts` | List all .gd GDScript files in the project. | projectPath |
| `list_project_shaders` | List all shader files (.gdshader) in the project. | projectPath |
| `list_project_shaders_glsl` | List all GLSL shader files in a Godot project. | projectPath |
| `list_project_videos` | List all video files in the project directory. | projectPath |
| `list_projects` | List Godot projects in a directory | directory |
| `manage_docker_export` | Create Dockerfile for headless Godot export | projectPath, action |
| `manage_export_presets` | Create or modify export preset configuration | projectPath, action |
| `modify_project_settings` | Modify a project.godot setting | projectPath, section, key, value |
| `read_project_settings` | Read project.godot as structured JSON | projectPath |
| `run_project` | Run the Godot project and capture output | projectPath |
| `search_project_text` | Full-text search across all project files. | projectPath, query |
| `set_project_gravity` | Set default gravity in Godot project settings. | projectPath |
| `set_project_main_scene` | Set the main scene path in project.godot. | projectPath, scenePath |
| `set_project_name` | Set the application name in project.godot. | projectPath, name |
| `set_project_physics_fps` | Set physics ticks per second in project settings. | projectPath |
| `set_project_setting` | Set a project setting key/value in project.godot. | projectPath, section, key, value |
| `set_project_setting_runtime` | Set a Godot project setting at runtime. | settingName, value |
| `set_project_version` | Set application version in project.godot. | projectPath, version |
| `set_project_window_mode` | Set window mode in project.godot (windowed/fullscreen). | projectPath, mode |
| `set_project_window_size` | Set window width and height in project.godot. | projectPath |
| `stop_project` | Stop the currently running Godot project | None |
| `update_project_uids` | Update UID references by resaving resources (4.4+) | projectPath |
| `write_bouncy_projectile_script` | Write a bouncing ball projectile script. | projectPath, scriptPath |
| `write_projectile_script` | Write a projectile (bullet/arrow) GDScript. | projectPath, scriptPath |

## Rendering

| Tool | Description | Required arguments |
|---|---|---|
| `add_camera_3d` | Add a Camera3D node to a scene file. | projectPath, scenePath |
| `add_directional_light_3d` | Add a DirectionalLight3D node to a scene. | projectPath, scenePath |
| `add_lightmap_gi` | Add a LightmapGI node to a 3D scene file. | projectPath, scenePath |
| `add_omni_light_3d` | Add an OmniLight3D node to a scene file. | projectPath, scenePath |
| `add_ray_cast_2d_from_camera` | Add a camera-aligned RayCast2D to a 2D scene. | projectPath, scenePath |
| `add_spot_light_3d` | Add a SpotLight3D node to a scene file. | projectPath, scenePath |
| `add_sub_viewport` | Add a SubViewport node to a scene file. | projectPath, scenePath |
| `add_sub_viewport_container` | Add a SubViewportContainer node to a scene. | projectPath, scenePath |
| `add_visual_shader` | Create a VisualShader .tres resource file. | projectPath, outputPath |
| `add_world_environment` | Add a WorldEnvironment node to a scene file. | projectPath, scenePath |
| `add_xr_camera_3d` | Add an XRCamera3D node to a scene file. | projectPath, scenePath |
| `assign_shader_to_mesh` | Create and assign a shader file to a MeshInstance3D. | nodePath, shaderPath |
| `camera_2d_set_zoom` | Set the zoom of a Camera2D in the running game. | nodePath, x |
| `camera_get_info` | Get info about the active camera in the running game. | None |
| `camera_set_current` | Make a Camera2D or Camera3D node the current camera. | nodePath |
| `cast_ray_from_camera` | Cast a ray from Camera3D through screen coords. | nodePath |
| `create_environment_resource` | Create a default Environment .tres resource file. | projectPath, outputPath |
| `create_material_override` | Create a material override on a MeshInstance3D. | nodePath |
| `create_shader_file` | Create a new .gdshader file in the project. | projectPath, shaderPath |
| `create_shader_material` | Create a ShaderMaterial .tres from shader source code. | projectPath, outputPath, shaderSource |
| `create_standard_material_3d` | Create and save a StandardMaterial3D resource. | projectPath, savePath |
| `create_viewport_texture` | Get viewport texture RID from a SubViewport. | nodePath |
| `game_camera_attributes` | Configure DOF, exposure, auto-exposure on camera | None |
| `game_environment` | Get or set environment and post-processing settings | None |
| `game_get_camera` | Get active camera position, rotation, and size | None |
| `game_get_viewport_info` | Get viewport size and stretch mode from the running game. | None |
| `game_light_2d` | Create/configure 2D lights and light occluders | action |
| `game_light_3d` | Create/configure 3D lights (directional/omni/spot) | action |
| `game_render_settings` | Get/set MSAA, FXAA, TAA, scaling mode/scale | None |
| `game_set_camera` | Move or rotate the active camera | None |
| `game_set_shader_param` | Set a shader parameter on a node's material | nodePath, paramName, value |
| `game_viewport` | Create or configure a SubViewport node | None |
| `game_visual_shader` | Create and edit VisualShader graphs: add/connect/disconnect nodes | action |
| `get_2d_camera_info` | Get Camera2D zoom, offset, and position from game. | None |
| `get_3d_camera_info` | Get Camera3D properties: FOV, near, far, projection. | nodePath |
| `get_camera_2d_screen_center` | Get the screen center position of Camera2D. | nodePath |
| `get_canvas_item_material` | Get the material type on a CanvasItem. | nodePath |
| `get_current_camera` | Get the currently active camera in the game. | None |
| `get_current_camera_3d` | Get the active Camera3D path in the running game. | None |
| `get_environment_glow` | Get glow settings from a WorldEnvironment. | nodePath |
| `get_environment_info` | Get WorldEnvironment settings from running scene. | None |
| `get_environment_properties` | Get all environment settings from a WorldEnvironment. | None |
| `get_environment_property` | Get a property from the Environment resource in game. | nodePath, property |
| `get_environment_tone_map` | Get tone mapper and exposure from environment. | nodePath |
| `get_environment_variable` | Get an OS environment variable value. | varName |
| `get_light_2d_info` | Get properties of a Light2D node. | nodePath |
| `get_light_info` | Get current properties of a Light3D node. | nodePath |
| `get_light_properties` | Get properties of a Light node in the running game. | nodePath |
| `get_material_info` | Get material properties from a MeshInstance3D. | nodePath |
| `get_material_properties` | Get all material properties from a node in game. | nodePath |
| `get_material_property` | Get a material property on a MeshInstance3D. | nodePath, property |
| `get_render_info` | Get rendering stats (draw calls, triangles) from game. | None |
| `get_rendering_info` | Get GPU rendering info (objects drawn, etc). | None |
| `get_rendering_settings` | Read rendering settings from project.godot. | projectPath |
| `get_shader_global_parameter` | Get a global shader parameter in the game. | parameterName |
| `get_shader_param` | Get a uniform parameter from a ShaderMaterial. | nodePath, paramName |
| `get_shader_parameter` | Get a uniform parameter from a node's ShaderMaterial. | nodePath, paramName |
| `get_shader_params` | Get shader parameters from a ShaderMaterial in game. | nodePath |
| `get_shader_uniforms` | Get all shader uniforms from a ShaderMaterial in game. | nodePath |
| `get_sky_material_info` | Get Sky resource and material from an env. | nodePath |
| `get_sub_viewport_info` | Get SubViewport size, mode, and update mode. | nodePath |
| `get_sub_viewport_texture_rid` | Get texture RID of a SubViewport node. | nodePath |
| `get_viewport_canvas_transform` | Get the canvas transform of a Viewport. | nodePath |
| `get_viewport_render_info` | Get draw calls and vertices for a viewport. | nodePath |
| `get_viewport_size` | Get the viewport size of the running game. | None |
| `get_viewport_texture_rid` | Get the Viewport texture RID for rendering. | nodePath |
| `get_viewport_textures` | Get list of SubViewports and their textures in scene. | None |
| `get_visual_shader_connections` | Get all connections in a VisualShader type. | nodePath, shaderType |
| `get_visual_shader_info` | Get VisualShader node count and output type. | nodePath |
| `get_world_environment` | Get WorldEnvironment info from the running game. | None |
| `get_world_environment_info` | Get info from the WorldEnvironment node. | nodePath |
| `get_xr_camera_transform` | Get the XR camera world transform. | nodePath |
| `list_shader_params` | List all uniform parameters on a ShaderMaterial. | nodePath |
| `make_camera_current` | Set a Camera2D or Camera3D as the active camera. | nodePath |
| `manage_shader` | Create or read .gdshader files | projectPath, shaderPath, action |
| `material_create` | Create a new StandardMaterial3D or CanvasItemMaterial .tres file. | projectPath, materialPath |
| `reset_camera_2d` | Reset Camera2D smoothing and snap to target. | nodePath |
| `set_camera_2d_drag_margins` | Set drag margins on a Camera2D node. | nodePath |
| `set_camera_2d_limit` | Set a scroll limit on a Camera2D in the game. | nodePath, side |
| `set_camera_2d_limits` | Set boundary limits on a Camera2D node. | nodePath |
| `set_camera_2d_process_callback` | Set Camera2D process callback (idle/physics). | nodePath |
| `set_camera_2d_zoom` | Set the zoom level on a Camera2D in the game. | nodePath |
| `set_camera_3d_current` | Make a Camera3D the current camera in the game. | nodePath |
| `set_camera_3d_far` | Set far clip distance of a Camera3D node. | nodePath |
| `set_camera_3d_fov` | Set field of view of a Camera3D node. | nodePath |
| `set_camera_3d_near` | Set near clip distance of a Camera3D node. | nodePath |
| `set_camera_current` | Make a camera the current active camera in game. | nodePath |
| `set_camera_fov` | Set the field of view on a Camera3D in the game. | nodePath |
| `set_canvas_item_use_parent_material` | Set CanvasItem use_parent_material flag. | nodePath, useParentMaterial |
| `set_directional_light_color` | Set color of a DirectionalLight3D node. | nodePath |
| `set_directional_light_energy` | Set energy of a DirectionalLight3D node. | nodePath |
| `set_directional_light_shadow` | Set shadow mode on a DirectionalLight3D. | nodePath |
| `set_environment_ambient_light` | Set ambient light color on a WorldEnvironment. | nodePath |
| `set_environment_bloom` | Enable/configure bloom on a WorldEnvironment. | nodePath |
| `set_environment_brightness` | Set WorldEnvironment tonemap exposure/brightness. | None |
| `set_environment_fog` | Configure fog on a WorldEnvironment node in game. | None |
| `set_environment_glow` | Configure glow on a WorldEnvironment node in game. | None |
| `set_environment_glow_enabled` | Enable or disable glow on a WorldEnvironment. | nodePath, enabled |
| `set_environment_property` | Set a property on the WorldEnvironment in the running game. | propertyName, propertyValue |
| `set_environment_sky_color` | Set sky color on a WorldEnvironment background. | nodePath |
| `set_environment_ssao` | Enable or disable SSAO on a WorldEnvironment in game. | None |
| `set_environment_tone_map` | Set tone mapper and exposure on environment. | nodePath |
| `set_environment_tonemap` | Set tonemapping mode on a WorldEnvironment. | nodePath |
| `set_light_2d_color` | Set color of a Light2D node at runtime. | nodePath |
| `set_light_2d_energy` | Set energy of a Light2D node at runtime. | nodePath |
| `set_light_2d_texture_scale` | Set texture scale of a PointLight2D node. | nodePath |
| `set_light_3d_color` | Set the color on a Light3D node in the running game. | nodePath |
| `set_light_3d_energy` | Set the energy on a Light3D node in the running game. | nodePath |
| `set_light_color` | Set color of a Light3D node (r,g,b 0-1). | nodePath |
| `set_light_energy` | Set energy/brightness of a Light3D node. | nodePath |
| `set_light_property` | Set a property on a Light node in the running game. | nodePath, propertyName |
| `set_light_range` | Set the range on a Light3D node in the game. | nodePath |
| `set_light_shadow` | Enable or disable shadows on a Light3D in game. | nodePath |
| `set_material_albedo_color` | Set albedo color of a StandardMaterial3D on a node. | nodePath |
| `set_material_alpha_mode` | Set alpha mode on a MeshInstance3D material. | nodePath |
| `set_material_cull_mode` | Set cull mode on a MeshInstance3D material. | nodePath |
| `set_material_emission` | Set emission color on a MeshInstance3D material. | nodePath |
| `set_material_emission_color` | Set emission color of a StandardMaterial3D on node. | nodePath |
| `set_material_metallic` | Set metallic value on a MeshInstance3D material. | nodePath |
| `set_material_property` | Set a property on a MeshInstance material in the game. | nodePath, propertyName, propertyValue |
| `set_material_roughness` | Set roughness value on a MeshInstance3D material. | nodePath |
| `set_material_roughness_metallic` | Set roughness and metallic on StandardMaterial3D. | nodePath |
| `set_material_transparency` | Set transparency/alpha of a StandardMaterial3D. | nodePath |
| `set_mesh_surface_material` | Set surface material on a MeshInstance3D in game. | nodePath, materialPath |
| `set_omni_light_energy` | Set energy of an OmniLight3D node at runtime. | nodePath |
| `set_omni_light_range` | Set range of an OmniLight3D node at runtime. | nodePath |
| `set_shader_global_parameter` | Set a global shader parameter in the game. | parameterName |
| `set_shader_param` | Set a shader parameter on a ShaderMaterial in game. | nodePath, paramName |
| `set_shader_param_color` | Set a color uniform on a ShaderMaterial. | nodePath, paramName |
| `set_shader_param_vec2` | Set a vec2 uniform on a ShaderMaterial. | nodePath, paramName |
| `set_shader_param_vec3` | Set a vec3 uniform on a ShaderMaterial. | nodePath, paramName |
| `set_shader_parameter` | Set a uniform parameter on a node's ShaderMaterial. | nodePath, paramName |
| `set_shader_uniform` | Set a named uniform on a ShaderMaterial in game. | nodePath, uniformName |
| `set_sky_material` | Set the sky material on a WorldEnvironment in game. | skyMaterialPath |
| `set_spot_light_angle` | Set the spot_angle on a SpotLight3D in the game. | nodePath |
| `set_spot_light_energy` | Set energy of a SpotLight3D node at runtime. | nodePath |
| `set_sub_viewport_size` | Set size of a SubViewport node at runtime. | nodePath |
| `set_sub_viewport_update_mode` | Set update mode of SubViewport (once/always/disabled). | nodePath |
| `set_viewport_clear_mode` | Set the clear mode of a Viewport node. | nodePath, clearMode |
| `set_viewport_msaa` | Set MSAA setting on a Viewport node. | nodePath |
| `set_viewport_size` | Set the viewport/window size in the running game. | width, height |
| `shader_create` | Create a new .gdshader file with a template for a shader type. | projectPath, shaderPath |
| `shake_camera_2d` | Apply a shake effect to a Camera2D node. | nodePath |
| `subviewport_set_size` | Set the pixel size of a SubViewport in the running game. | nodePath, width, height |
| `toggle_light_2d` | Enable or disable a Light2D node at runtime. | nodePath |
| `write_2d_lighting_controller` | Write a 2D dynamic light controller script. | projectPath, scriptPath |
| `write_camera_2d_smooth_script` | Write a smooth-follow Camera2D script. | projectPath, scriptPath |
| `write_camera_follow_3d_script` | Write a 3D camera that follows a target. | projectPath, scriptPath |
| `write_camera_follow_script` | Write a camera follow/smooth script. | projectPath, scriptPath |
| `write_camera_shake_3d_script` | Write a 3D camera shake effect script. | projectPath, scriptPath |
| `write_dissolve_shader` | Write a dissolve/burn effect GDShader file. | projectPath, shaderPath |
| `write_follow_camera_3d_script` | Write a 3D third-person follow camera script. | projectPath, scriptPath |
| `write_gdshader_file` | Write a basic GDShader (.gdshader) file. | projectPath, shaderPath |
| `write_outline_shader` | Write a 2D sprite outline GDShader file. | projectPath, shaderPath |
| `write_pixelate_shader` | Write a pixelate screen effect GDShader file. | projectPath, shaderPath |
| `write_vignette_shader` | Write a vignette screen effect GDShader file. | projectPath, shaderPath |
| `write_water_surface_shader` | Write a simple water surface GDShader file. | projectPath, shaderPath |

## Runtime and specialized

| Tool | Description | Required arguments |
|---|---|---|
| `action_get_deadzone` | Get deadzone value of an InputMap action. | actionName |
| `action_has_event` | Check if an InputMap action has a key event. | actionName |
| `add_area_2d` | Add an Area2D with collision to a scene file. | projectPath, scenePath |
| `add_astar2d_point` | Add a point to an AStar2D pathfinding graph. | nodePath, pointId, x, y |
| `add_autoload` | Add an autoload singleton to the project. | projectPath, name, path |
| `add_back_buffer_copy` | Add a BackBufferCopy node to a scene file. | projectPath, scenePath |
| `add_bone_attachment_3d` | Add a BoneAttachment3D node to a scene file. | projectPath, scenePath |
| `add_canvas_modulate` | Add a CanvasModulate node to a scene file. | projectPath, scenePath |
| `add_character_body_2d` | Add a CharacterBody2D node to a scene file. | projectPath, scenePath |
| `add_character_body_3d` | Add a CharacterBody3D node to a scene file. | projectPath, scenePath |
| `add_color_rect` | Add a ColorRect node to a scene file. | projectPath, scenePath |
| `add_cpu_particles_2d` | Add a CPUParticles2D node to a scene file. | projectPath, scenePath |
| `add_cpu_particles_3d` | Add a CPUParticles3D node to a scene file. | projectPath, scenePath |
| `add_csg_box` | Add a CSGBox3D node to a scene file. | projectPath, scenePath |
| `add_csg_combiner` | Add a CSGCombiner3D node to a scene file. | projectPath, scenePath |
| `add_csg_cylinder` | Add a CSGCylinder3D node to a scene file. | projectPath, scenePath |
| `add_csg_sphere` | Add a CSGSphere3D node to a scene file. | projectPath, scenePath |
| `add_decal_3d` | Add a Decal node to a 3D scene file. | projectPath, scenePath |
| `add_fog_volume` | Add a FogVolume node to a 3D scene file. | projectPath, scenePath |
| `add_gpu_particles_2d` | Add a GPUParticles2D node to a scene file. | projectPath, scenePath |
| `add_gpu_particles_3d` | Add a GPUParticles3D node to a scene file. | projectPath, scenePath |
| `add_http_request` | Add an HTTPRequest node to a scene file. | projectPath, scenePath |
| `add_input_action` | Add a new input action to project.godot. | projectPath, actionName |
| `add_item_list_item` | Add an item to an ItemList node in the game. | nodePath, text |
| `add_item_list_item_text` | Add a text item to an ItemList node at runtime. | nodePath, text |
| `add_line_2d` | Add a Line2D node to a 2D scene file. | projectPath, scenePath |
| `add_locale_key` | Add a translation key/value pair to a .po locale file. | projectPath, localePath, msgid |
| `add_mesh_instance` | Add a MeshInstance3D with a primitive mesh to a scene. | projectPath, scenePath |
| `add_multi_mesh_instance_3d` | Add a MultiMeshInstance3D node to a scene file. | projectPath, scenePath |
| `add_navigation_agent_2d` | Add a NavigationAgent2D to a node in a scene. | projectPath, scenePath, parentNodePath |
| `add_navigation_region_2d` | Add a NavigationRegion2D node to a scene file. | projectPath, scenePath |
| `add_navigation_region_3d` | Add a NavigationRegion3D node to a scene file. | projectPath, scenePath |
| `add_nine_patch_rect` | Add a NinePatchRect node to a scene file. | projectPath, scenePath |
| `add_occluder_instance_3d` | Add an OccluderInstance3D node to a scene file. | projectPath, scenePath |
| `add_parallax_background` | Add a ParallaxBackground node to a scene file. | projectPath, scenePath |
| `add_parallax_layer` | Add a ParallaxLayer node to a scene file. | projectPath, scenePath |
| `add_path_2d_point` | Add a point to a Path2D curve. | nodePath |
| `add_path_3d_point` | Add a point to a Path3D's Curve3D. | nodePath, x, y, z |
| `add_polygon_2d` | Add a Polygon2D node to a 2D scene file. | projectPath, scenePath |
| `add_ray_cast_2d` | Add a RayCast2D node to a scene file. | projectPath, scenePath |
| `add_ray_cast_3d` | Add a RayCast3D node to a scene file. | projectPath, scenePath |
| `add_reflection_probe` | Add a ReflectionProbe node to a scene file. | projectPath, scenePath |
| `add_remote_transform_3d` | Add a RemoteTransform3D node to a scene file. | projectPath, scenePath |
| `add_signal_connection` | Add a signal connection between two nodes in a scene. | projectPath, scenePath, signal, from, to, method |
| `add_skeleton_3d` | Add a Skeleton3D node to a scene file. | projectPath, scenePath |
| `add_spring_arm_3d` | Add a SpringArm3D node to a scene file. | projectPath, scenePath |
| `add_sprite_3d` | Add a Sprite3D node to a scene file. | projectPath, scenePath |
| `add_static_body_2d` | Add a StaticBody2D node to a scene file. | projectPath, scenePath |
| `add_static_body_3d` | Add a StaticBody3D node to a scene file. | projectPath, scenePath |
| `add_texture_progress_bar` | Add a TextureProgressBar node to a scene. | projectPath, scenePath |
| `add_tile_map_layer` | Add a TileMapLayer node to a scene file. | projectPath, scenePath |
| `add_tileset_custom_data_layer` | Add a custom data layer to a TileSet. | projectPath, tileSetPath, layerName, layerType |
| `add_tileset_source` | Add an atlas source to a TileSet resource. | projectPath, tileSetPath, textureAtlasPath |
| `add_tileset_terrain_set` | Add a terrain set to a TileSet resource. | projectPath, tileSetPath |
| `add_vehicle_body_3d` | Add a VehicleBody3D node to a scene file. | projectPath, scenePath |
| `add_vehicle_wheel_3d` | Add a VehicleWheel3D node to a scene file. | projectPath, scenePath |
| `add_video_stream_player` | Add a VideoStreamPlayer node to a scene file. | projectPath, scenePath |
| `add_visible_on_screen_notifier_2d` | Add a VisibleOnScreenNotifier2D to a scene. | projectPath, scenePath |
| `add_visible_on_screen_notifier_3d` | Add VisibleOnScreenNotifier3D to a scene file. | projectPath, scenePath |
| `add_voxel_gi` | Add a VoxelGI node to a 3D scene file. | projectPath, scenePath |
| `add_xr_origin_3d` | Add an XROrigin3D node to a scene file. | projectPath, scenePath |
| `analyze_signal_flow` | Parse a scene and return all signal connections as a graph. | projectPath, scenePath |
| `append_rich_text` | Append BBCode text to a RichTextLabel node. | nodePath |
| `apply_central_impulse_2d` | Apply a central impulse to a RigidBody2D. | nodePath |
| `apply_central_impulse_3d` | Apply a central impulse to a RigidBody3D. | nodePath |
| `apply_impulse_3d` | Apply a 3D impulse to a RigidBody3D node. | nodePath |
| `apply_physical_bone_impulse` | Apply an impulse to a PhysicalBone3D node. | nodePath, x, y, z |
| `apply_torque_impulse_3d` | Apply a torque impulse to a RigidBody3D. | nodePath, x, y, z |
| `area_get_overlapping` | Get bodies/areas overlapping an Area node in the game. | nodePath |
| `assert_screen_text` | Assert that expected text is visible in the running game UI. | text |
| `bake_navigation_mesh_3d` | Trigger NavigationRegion3D mesh bake. | nodePath |
| `base64_decode` | Base64 decode a string via Godot's Marshalls. | encoded |
| `base64_encode` | Base64 encode a string via Godot's Marshalls. | text |
| `batch_get_properties` | Get multiple properties from multiple nodes at once. | queries |
| `batch_set_properties` | Set multiple properties on multiple nodes in one call. | operations |
| `batch_set_property` | Set a property on all nodes of a given type in a scene file. | projectPath, scenePath, nodeType, propertyKey, propertyValue |
| `blend_shape_get_values` | Get all blend shape values from a MeshInstance3D. | nodePath |
| `blend_shape_set_value` | Set a blend shape value on a MeshInstance3D in game. | nodePath |
| `canvas_layer_set` | Set a CanvasLayer layer number in the running game. | nodePath, layer |
| `canvas_layer_set_layer` | Set the layer number of a CanvasLayer in the game. | nodePath, layer |
| `capture_frames` | Capture N screenshots over successive game frames. | None |
| `cast_ray_2d_in_game` | Cast a 2D ray in the running game physics world. | None |
| `cast_ray_in_game` | Cast a 3D ray in the running game physics world. | None |
| `character_body_set_velocity` | Set velocity on a CharacterBody in the running game. | nodePath, x, y |
| `check_area_2d_monitoring` | Check if Area2D monitoring is enabled. | nodePath |
| `class_exists` | Check if a class name exists in Godot's ClassDB. | className |
| `clear_gridmap` | Clear all cells from a GridMap node. | nodePath |
| `clear_item_list` | Clear all items from an ItemList in the game. | nodePath |
| `clear_path_2d` | Remove all points from a Path2D curve. | nodePath |
| `clear_print_output` | Clear the print output buffer in the running game. | None |
| `clear_rich_text` | Clear all text from a RichTextLabel node. | nodePath |
| `clear_tilemap_layer` | Clear all tiles in a TileMap layer in game. | nodePath |
| `compare_screenshots` | Compare current screenshot to a reference file by hash. | referencePath |
| `connect_astar2d_points` | Connect two points in an AStar2D graph. | nodePath, id1, id2 |
| `connect_signal_in_game` | Connect a signal from one node to another in game. | sourcePath, signalName, targetPath, methodName |
| `count_code_lines` | Count code/comment/blank lines across all GDScript files. | projectPath |
| `create_array_mesh` | Create an empty ArrayMesh .tres resource file. | projectPath, outputPath |
| `create_enet_peer` | Create and connect an ENetMultiplayerPeer. | address, port |
| `create_enet_server` | Create an ENetMultiplayerPeer server. | port |
| `create_image_from_color` | Create a solid-color Image and save to file. | projectPath, outputPath, r, g, b |
| `create_localization_csv` | Create a CSV translation file template for multiple locales. | projectPath, outputPath, languages |
| `create_navigation_mesh` | Create a NavigationMesh .tres resource file. | projectPath, outputPath |
| `create_websocket_peer` | Connect a WebSocketPeer to a URL. | url |
| `curve_create` | Create a Curve .tres resource with specified control points. | projectPath, curvePath, points |
| `datetime_to_unix_time` | Convert a date/time dict to Unix timestamp. | year, month, day |
| `debugger_evaluate` | Evaluate a GDScript expression in the running game context. | expression |
| `debugger_get_stack` | Get the current call stack from the running game. | None |
| `debugger_list_breakpoints` | List all MCP-injected breakpoints in the project. | projectPath |
| `debugger_set_breakpoint` | Inject or remove a GDScript breakpoint at a file line. | projectPath, scriptPath, line |
| `detect_circular_dependencies` | Build a dependency graph from .tscn ext_resource entries and detect cycles. | projectPath |
| `disconnect_multiplayer` | Close the current multiplayer peer connection in game. | None |
| `disconnect_signal` | Disconnect a signal connection on a node. | nodePath, signalName, targetPath, targetMethod |
| `disconnect_signal_in_game` | Disconnect a signal connection in the running game. | sourcePath, signalName, targetPath, methodName |
| `emit_gpu_particles_3d_subemitter` | Emit subemitter particles on GPUParticles3D. | nodePath |
| `emit_signal_in_game` | Emit a signal on a node in the running game. | nodePath, signalName |
| `enable_ray_cast_2d` | Enable or disable a RayCast2D node. | nodePath |
| `enable_ray_cast_3d` | Enable or disable a RayCast3D node. | nodePath |
| `erase_input_action` | Remove an action from InputMap at runtime. | actionName |
| `erase_tilemap_cell` | Erase a cell from a TileMap at given coordinates. | nodePath, x, y |
| `find_all_todos` | Find all TODO/FIXME/HACK comments in GDScript files. | projectPath |
| `find_circular_dependencies` | Detect circular extends dependencies in GDScript files. | projectPath |
| `find_class_inheritors` | Find all scripts that extend a given class name. | projectPath, baseClass |
| `find_deprecated_apis` | Find deprecated Godot 3 API patterns in GDScript files. | projectPath |
| `find_large_textures` | Find textures larger than a given file size limit. | projectPath |
| `find_signal_connections` | Scan all .tscn files for [connection signal=...] lines and return them. | projectPath |
| `find_skeleton_3d_bone_by_name` | Find a bone index by name in Skeleton3D. | nodePath, boneName |
| `flip_sprite` | Set flip_h/flip_v on a Sprite2D in the game. | nodePath |
| `force_garbage_collect` | Force GDScript garbage collection in the game. | None |
| `force_ray_cast_update` | Force a RayCast2D or RayCast3D to update immediately. | nodePath |
| `game_3d_effects` | Create ReflectionProbe, Decal, or FogVolume | parentPath, effectType |
| `game_await_signal` | Await a signal with timeout and return args | nodePath, signalName |
| `game_bone_pose` | Get or set bone poses on a Skeleton3D node | nodePath |
| `game_call_method` | Call a method on any node in the running game with optional arguments | nodePath, method |
| `game_canvas` | Create/configure CanvasLayer and CanvasModulate | action |
| `game_canvas_draw` | 2D drawing: line/rect/circle/polygon/text/clear | action |
| `game_click` | Click at a position in the running Godot game window | x, y |
| `game_connect_signal` | Connect a signal from one node to a method on another node in the running game | nodePath, signalName, targetPath, method |
| `game_create_timer` | Create a Timer node with configuration | None |
| `game_csg` | Create/configure CSG nodes with boolean operations | action |
| `game_debug_draw` | Draw debug lines, spheres, or boxes in 3D | action |
| `game_disconnect_signal` | Disconnect a signal connection in the running game | nodePath, signalName, targetPath, method |
| `game_emit_signal` | Emit a signal on a node in the running game, optionally with arguments | nodePath, signalName |
| `game_eval` | Execute GDScript in the running game. Use "return" for values. | code |
| `game_gamepad` | Send gamepad button or axis input event | type, index, value |
| `game_get_errors` | Get new push_error/push_warning messages since last call | None |
| `game_get_fps_history` | Get recent FPS samples from the running game. | None |
| `game_get_logs` | Get new print output from the running game since last call | None |
| `game_get_property` | Get a property value from any node in the running game by its path | nodePath, property |
| `game_gi` | Create/configure VoxelGI or LightmapGI | parentPath, giType |
| `game_gridmap` | GridMap set/get/clear cells and query used cells | nodePath, action |
| `game_http_request` | HTTP GET/POST/PUT/DELETE with headers and body | url |
| `game_input_action` | Manage runtime InputMap actions and strength | action |
| `game_input_state` | Query pressed keys, mouse position, connected pads | None |
| `game_key_hold` | Hold a key down without auto-releasing | None |
| `game_key_press` | Send a key press or input action to the running game | None |
| `game_key_release` | Release a previously held key | None |
| `game_list_signals` | List all signals on a node with connections | nodePath |
| `game_locale` | Set/get locale and translate strings at runtime | action |
| `game_mesh_instance` | Create MeshInstance3D with primitive meshes | parentPath, meshType |
| `game_mouse_drag` | Drag mouse between two points over N frames | fromX, fromY, toX, toY |
| `game_mouse_move` | Move the mouse in the running Godot game | x, y |
| `game_multimesh` | Create/configure MultiMeshInstance3D for instancing | action |
| `game_multiplayer` | ENet multiplayer create server/client/disconnect | action |
| `game_navigate_path` | Query a navigation path between two points | start, end |
| `game_navigation_3d` | Create/configure NavigationRegion3D and bake | action |
| `game_os_info` | Get platform, locale, screen, adapter, memory info | None |
| `game_parallax` | Create/configure ParallaxBackground and layers | action |
| `game_path_2d` | Path2D/Curve2D management and AnimatedSprite2D | action |
| `game_path_3d` | Create Path3D/Curve3D and manage curve points | action |
| `game_pause` | Pause or unpause the running game | None |
| `game_performance` | Get performance metrics (FPS, memory, draw calls) | None |
| `game_procedural_mesh` | Generate meshes via ArrayMesh from vertex data | parentPath, vertices |
| `game_process_mode` | Set node process mode (pausable/always/disabled) | nodePath, mode |
| `game_rpc` | Call or configure RPC methods on nodes | nodePath, action, method |
| `game_screenshot` | Screenshot the running game (returns base64 PNG) | None |
| `game_scroll` | Send mouse scroll wheel event at position | x, y |
| `game_serialize_state` | Save or load node tree state as JSON | None |
| `game_set_debug_visible` | Toggle debug draw mode in the running game. | None |
| `game_set_particles` | Configure GPUParticles2D/3D node properties | nodePath |
| `game_set_property` | Set a property on a node in the running game | nodePath, property, value |
| `game_set_time_scale` | Set time_scale for slow/fast motion in the game. | timeScale |
| `game_shape_2d` | Line2D/Polygon2D point manipulation | nodePath, action |
| `game_skeleton_ik` | SkeletonIK3D start/stop/set target position | nodePath, action |
| `game_sky` | Create/configure Sky with procedural/physical sky | action |
| `game_terrain` | Create/modify terrain meshes from heightmap data | action |
| `game_tilemap` | Get or set cells in a TileMapLayer node | nodePath, action |
| `game_time_scale` | Get/set Engine.time_scale and timing info | None |
| `game_touch` | Simulate touch press/release/drag and gestures | action, x, y |
| `game_video` | Video playback control: play, pause, stop, seek on VideoStreamPlayer | action |
| `game_wait` | Wait N frames in the running game | None |
| `game_websocket` | WebSocket client connect/disconnect/send messages | action |
| `game_window` | Get/set window size, fullscreen, title, position | None |
| `game_world_settings` | Get/set gravity, physics FPS, and world settings | None |
| `gdextension_list` | List all GDExtension library files in the project. | projectPath |
| `generate_mesh_normals` | Regenerate normals on a mesh resource (headless). | projectPath, meshPath |
| `get_action_strength` | Get analog strength of an input action (0.0 to 1.0). | actionName |
| `get_actions_for_key` | Get InputMap actions triggered by a keycode. | keycode |
| `get_all_custom_signals` | Find all custom signal definitions across all GDScript files. | projectPath |
| `get_all_performance_monitors` | Get all key Godot Performance monitor values. | None |
| `get_animated_sprite_2d_frame` | Get current frame of an AnimatedSprite2D. | nodePath |
| `get_asset_preload_list` | Find all ResourcePreloader nodes in scene files. | projectPath |
| `get_astar2d_id_path` | Get point ID path from AStar2D A* search. | nodePath, fromId, toId |
| `get_astar2d_point_count` | Get the number of points in an AStar2D node. | nodePath |
| `get_astar2d_point_path` | Get Vector2 path from AStar2D A* search. | nodePath, fromId, toId |
| `get_astar3d_point_path` | Get Vector3 path from AStar3D A* search. | nodePath, fromId, toId |
| `get_atlas_texture_info` | Get AtlasTexture region and atlas resource. | nodePath |
| `get_autoloads` | List all autoloads/singletons from project.godot. | projectPath |
| `get_blend_parameter` | Get a blend parameter value from AnimationTree. | nodePath, paramName |
| `get_blend_shape_count` | Get blend shape count of a MeshInstance3D in game. | nodePath |
| `get_blend_shape_value` | Get a blend shape value on a MeshInstance3D. | nodePath |
| `get_bone_attachment_3d_info` | Get BoneAttachment3D bone name and index. | nodePath |
| `get_bone_global_pose` | Get the global pose of a Skeleton3D bone in game. | nodePath |
| `get_bone_index` | Get index of a bone by name in Skeleton3D. | nodePath, boneName |
| `get_bone_rest_transform` | Get rest transform of a bone in Skeleton3D. | nodePath, boneName |
| `get_canvas_layers` | Get all CanvasLayer nodes in the running game. | None |
| `get_character_body_2d_info` | Get velocity and state of a CharacterBody2D. | nodePath |
| `get_character_body_3d_info` | Get velocity/state of a CharacterBody3D. | nodePath |
| `get_character_body_3d_velocity` | Get velocity of a CharacterBody3D node. | nodePath |
| `get_character_body_velocity` | Get the velocity of a CharacterBody node in game. | nodePath |
| `get_children_count` | Get the child count of a node in the running game. | nodePath |
| `get_class_api` | Get methods, properties, and signals of a Godot class. | projectPath, className |
| `get_class_inheritance` | Get parent class chain for a Godot class. | className |
| `get_class_method_list` | List methods of any Godot class via ClassDB. | className |
| `get_class_property_list` | List properties of any Godot class via ClassDB. | className |
| `get_class_signal_list` | List signals of any Godot class via ClassDB. | className |
| `get_clipboard` | Get the system clipboard text from the running game. | None |
| `get_colliding_bodies_3d` | Get all bodies colliding with a PhysicsBody3D. | nodePath |
| `get_color_in_game` | Get a Color property from a node in the running game. | nodePath |
| `get_color_picker_value` | Get the color from a ColorPicker node in game. | nodePath |
| `get_color_rect_color` | Get the color of a ColorRect in the game. | nodePath |
| `get_connected_joypads` | Get list of connected joypad/gamepad devices. | None |
| `get_connected_peers` | Get connected peer IDs from the MultiplayerAPI in game. | None |
| `get_cpu_count` | Get the CPU core count from the running game. | None |
| `get_csg_combined_faces` | Get the face count of a CSGShape3D combined mesh. | nodePath |
| `get_csg_shape_info` | Get CSGShape operation and snap value. | nodePath |
| `get_datetime_dict` | Get current date and time as a dictionary. | None |
| `get_debug_output` | Get the current debug output and errors | None |
| `get_decal_3d_info` | Get Decal3D size, texture, and albedo mix. | nodePath |
| `get_display_info` | Get screen size, DPI, and window info from game. | None |
| `get_display_server_info` | Get display server info: screen count, window list. | None |
| `get_distance_3d` | Get the distance between two Node3D nodes in game. | nodePathA, nodePathB |
| `get_distance_to_3d` | Get distance between two Node3D nodes. | nodePath, targetPath |
| `get_editor_inspector_object` | Get the object inspected in the editor. | None |
| `get_editor_plugin_list` | List all EditorPlugin scripts in the addons folder. | projectPath |
| `get_editor_undo_redo_history` | Get the undo/redo history length in editor. | None |
| `get_enet_connection_status` | Get the ENet multiplayer peer connection status. | None |
| `get_engine_target_fps` | Get the current Engine.max_fps and physics tick rate. | None |
| `get_engine_time_scale` | Get the current Engine time scale. | None |
| `get_engine_version` | Get the Godot engine version from the game. | None |
| `get_engine_version_in_game` | Get the Godot engine version from the running game. | None |
| `get_font_glyph_count` | Get the glyph count of a FontFile resource. | projectPath, fontPath |
| `get_font_info` | Get info about a font file in the project. | projectPath, fontPath |
| `get_game_fps` | Get the current frames per second of the running game. | None |
| `get_game_mouse_position` | Get current mouse position in the game viewport. | None |
| `get_game_resolution` | Get current game window resolution and scale. | None |
| `get_game_screen_size` | Get the game window screen size in pixels. | None |
| `get_game_time_elapsed` | Get total time in seconds since the game started. | None |
| `get_gdextension_info` | Read a .gdextension file and return its config. | projectPath, extensionPath |
| `get_global_mouse_position` | Get the global mouse position in the game. | None |
| `get_global_transform_3d` | Get the global transform of a Node3D in the game. | nodePath |
| `get_gpu_particles_3d_info` | Get GPUParticles3D emitting, amount, lifetime. | nodePath |
| `get_gridmap_bake_mesh` | Get the baked mesh bounds of a GridMap. | nodePath |
| `get_gridmap_cell_item` | Get the item type at GridMap cell coordinates. | nodePath, x, y, z |
| `get_gridmap_cell_size` | Get the cell size of a GridMap. | nodePath |
| `get_gridmap_mesh_library_items` | Get item IDs from GridMap's MeshLibrary. | nodePath |
| `get_gridmap_used_cells` | Get all non-empty cell positions in a GridMap. | nodePath |
| `get_h_slider_value` | Get current value from an HSlider node. | nodePath |
| `get_http_client_status` | Get status of an HTTPClient node in the game. | nodePath |
| `get_http_response` | Get the response body from an HTTPRequest node. | nodePath |
| `get_image_info` | Get width, height, format of an Image resource. | nodePath |
| `get_import_settings` | Get the .import settings for an asset file. | projectPath, assetPath |
| `get_input_action_list` | List all input actions defined in project.godot. | projectPath |
| `get_input_action_strength` | Get analog strength (0-1) of an input action. | actionName |
| `get_input_map` | Get all input actions and their mappings from project.godot. | projectPath |
| `get_input_map_actions` | Get all registered InputMap action names. | None |
| `get_input_state` | Get the current input action states in the game. | None |
| `get_item_list_count` | Get item count of an ItemList node. | nodePath |
| `get_item_list_info` | Get ItemList item count and selection mode. | nodePath |
| `get_item_list_items` | Get all items from an ItemList node in game. | nodePath |
| `get_item_list_selected` | Get selected items from an ItemList in game. | nodePath |
| `get_joy_axis` | Get the value of a joystick/gamepad axis. | None |
| `get_joy_count` | Get the number of joypads connected in game. | None |
| `get_joy_name` | Get the name of a joypad by device index in game. | None |
| `get_last_http_response` | Get response from a named HTTPRequest node. | nodePath |
| `get_line_edit_text` | Get the current text from a LineEdit in game. | nodePath |
| `get_loaded_gdextensions` | List all loaded GDExtension plugins in the running game. | None |
| `get_locale` | Get current system locale string from OS. | None |
| `get_locale_info` | Get the OS locale, language, and country code. | None |
| `get_max_fps` | Get the current maximum FPS cap. | None |
| `get_memory_usage` | Get current static memory usage and peak memory usage from OS. | None |
| `get_mesh_aabb` | Get axis-aligned bounding box of a MeshInstance3D. | nodePath |
| `get_mesh_instance_bounds` | Get world-space bounds of a MeshInstance3D. | nodePath |
| `get_mesh_surface_count` | Get the surface count of a MeshInstance3D in game. | nodePath |
| `get_mesh_surface_count_rt` | Get the number of surfaces in a MeshInstance3D mesh. | nodePath |
| `get_mesh_vertex_count` | Get vertex count of a Mesh in MeshInstance3D. | nodePath |
| `get_mouse_mode` | Get current mouse cursor mode. | None |
| `get_mouse_position` | Get the current mouse position in the running game. | None |
| `get_multimesh_instance_count` | Get visible instance count of MultiMeshInstance3D. | nodePath |
| `get_multiplayer_authority` | Get the multiplayer authority of a node. | nodePath |
| `get_multiplayer_peer_id` | Get the local peer ID in a multiplayer session. | None |
| `get_navigation_agent_2d_path` | Get current navigation path of NavigationAgent2D. | nodePath |
| `get_navigation_agent_2d_target` | Get target position of a NavigationAgent2D. | nodePath |
| `get_navigation_agent_3d_info` | Get NavigationAgent3D target, velocity info. | nodePath |
| `get_navigation_agent_3d_next_path_pos` | Get next path position from NavigationAgent3D. | nodePath |
| `get_navigation_agent_3d_path` | Get current navigation path of NavigationAgent3D. | nodePath |
| `get_navigation_agent_target` | Get the target position from a NavigationAgent in game. | nodePath |
| `get_navigation_agent_velocity` | Get next safe velocity from NavigationAgent2D/3D. | nodePath |
| `get_navigation_agents` | List all NavigationAgent nodes in the running game. | None |
| `get_navigation_map_rid` | Get the navigation map RID for a NavigationAgent. | nodePath |
| `get_navigation_path` | Get a nav path between two 3D points in the game. | None |
| `get_navigation_region_3d_baked` | Check if NavigationRegion3D has baked navmesh. | nodePath |
| `get_navigation_region_3d_enabled` | Check if a NavigationRegion3D is enabled. | nodePath |
| `get_network_info` | Get multiplayer/network info from the running game. | None |
| `get_network_latency` | Get estimated network latency to multiplayer server. | None |
| `get_network_peer_count` | Get number of connected peers in session. | None |
| `get_next_path_position` | Get next path position from NavigationAgent in game. | nodePath |
| `get_nine_patch_info` | Get margins and draw_center from NinePatchRect. | nodePath |
| `get_nine_patch_rect_info` | Get NinePatchRect patch margins and texture. | nodePath |
| `get_object_id` | Get the Object instance_id of a node in the game. | nodePath |
| `get_os_info` | Get OS name, locale, and system info from game. | None |
| `get_os_name` | Get the OS/platform name from the running game. | None |
| `get_overlapping_areas` | Get overlapping areas of an Area node in game. | nodePath |
| `get_overlapping_areas_2d` | Get areas overlapping an Area2D node. | nodePath |
| `get_overlapping_areas_3d` | Get areas overlapping an Area3D node. | nodePath |
| `get_overlapping_bodies` | Get overlapping bodies of an Area node in game. | nodePath |
| `get_overlapping_bodies_2d` | Get bodies overlapping an Area2D node. | nodePath |
| `get_overlapping_bodies_3d` | Get bodies overlapping an Area3D node. | nodePath |
| `get_particle_info` | Get info about a particle system node. | nodePath |
| `get_particle_state` | Get the state of a particle emitter node in game. | nodePath |
| `get_particles_amount` | Get the emission amount from a Particles node in game. | nodePath |
| `get_particles_info` | Get particle emitter info from a node in the game. | nodePath |
| `get_path_2d_baked_length` | Get the baked length of a Path2D curve. | nodePath |
| `get_path_2d_length` | Get the total length of a Path2D curve in game. | nodePath |
| `get_path_2d_point_count` | Get number of points in a Path2D/Curve2D. | nodePath |
| `get_path_3d_baked_length` | Get baked length of a Path3D's Curve3D. | nodePath |
| `get_path_3d_point_count` | Get the number of points in a Path3D curve. | nodePath |
| `get_path_3d_point_position` | Get position of a point in a Path3D curve. | nodePath, idx |
| `get_path_follower_2d_offset` | Get progress offset of a PathFollow2D. | nodePath |
| `get_performance_counters` | Get all performance monitor counter values from the game. | None |
| `get_performance_monitor` | Get a performance metric by name (e.g. render/fps). | monitor |
| `get_performance_monitor_value` | Get a single Godot Performance monitor value. | monitorName |
| `get_physical_bone_3d_info` | Get PhysicalBone3D joint type and parameters. | nodePath |
| `get_print_output` | Get recent print() output from the running game. | None |
| `get_process_state` | Get the process enabled states of a node in game. | nodePath |
| `get_processor_name` | Get CPU name from the OS singleton. | None |
| `get_progress_bar_value` | Get the value of a ProgressBar in the game. | nodePath |
| `get_random_int` | Get a random integer in a range via Godot. | min, max |
| `get_range_value` | Get value from a Range node (Slider, SpinBox, etc.). | nodePath |
| `get_ray_cast_collider` | Get the collider hit by a RayCast in the game. | nodePath |
| `get_runtime_input_actions` | List input actions and bindings in the running game. | None |
| `get_screen_count` | Get the number of displays available in game. | None |
| `get_screen_dpi` | Get the DPI and size of the primary screen. | None |
| `get_screen_resolution` | Get current screen size and window size. | None |
| `get_screen_size` | Get the screen/window size in the running game. | None |
| `get_signal_connection_list` | List connections for a signal on a node. | nodePath, signalName |
| `get_signal_connections` | Find signal connections in a .tscn scene file. | projectPath, scenePath |
| `get_signal_connections_all` | List all signal connections across all scene files. | projectPath |
| `get_signal_list` | Get all signals defined on a node in the game. | nodePath |
| `get_skeleton_3d_bone_global_pose` | Get global pose of a Skeleton3D bone. | nodePath, boneIndex |
| `get_skeleton_3d_bone_name` | Get the name of a bone by index in Skeleton3D. | nodePath, boneIndex |
| `get_skeleton_3d_info` | Get bone count and names from a Skeleton3D node. | nodePath |
| `get_skeleton_bone_count` | Get the bone count of a Skeleton3D in the game. | nodePath |
| `get_skeleton_bone_names` | List all bone names in a Skeleton3D in game. | nodePath |
| `get_skeleton_bone_pose` | Get local pose of a bone by name in Skeleton3D. | nodePath, boneName |
| `get_skeleton_physical_bones_simulating` | Check if skeleton simulates physical bones. | skeletonPath |
| `get_slider_step` | Get step and page values from a Slider. | nodePath |
| `get_slider_value` | Get the value from a Slider node in the game. | nodePath |
| `get_soft_body_3d_info` | Get SoftBody3D simulation precision and damping. | nodePath |
| `get_spin_box_value` | Get the current value of a SpinBox node in game. | nodePath |
| `get_spring_arm_3d_info` | Get SpringArm3D spring length and collision mask. | nodePath |
| `get_sprite_2d_frame_count` | Get total frame count of a Sprite2D sprite sheet. | nodePath |
| `get_sprite_texture` | Get the texture path of a Sprite2D in the game. | nodePath |
| `get_string_length` | Get length and byte count of a string in Godot. | text |
| `get_system_memory_info` | Get total/free RAM and VRAM from OS. | None |
| `get_text_edit_text` | Get the text content from a TextEdit in game. | nodePath |
| `get_text_mesh_info` | Get TextMesh text, font size, and depth. | nodePath |
| `get_texture_2d_size` | Get width and height of a Texture2D resource. | nodePath |
| `get_texture_flags` | Get filter and repeat flags of a Texture2D. | nodePath |
| `get_texture_rect_info` | Get TextureRect stretch mode, flip, and size. | nodePath |
| `get_texture_rect_texture` | Get the texture resource path of a TextureRect. | nodePath |
| `get_ticks_msec` | Get engine ticks in milliseconds since start. | None |
| `get_ticks_usec` | Get engine ticks in microseconds since start. | None |
| `get_tilemap_cell_at` | Get tile source info at a cell in a TileMap. | nodePath |
| `get_tilemap_cell_source_id` | Get source ID of a TileMap cell at coords. | nodePath, x, y |
| `get_tilemap_info` | Get TileMap layers, tile size, and cell count from game. | nodePath |
| `get_tilemap_layer_count` | Get the number of layers in a TileMap in game. | nodePath |
| `get_tilemap_used_cells` | Get list of used cells in a TileMap layer. | nodePath |
| `get_tilemap_used_rect` | Get the used cell rect of a TileMap in game. | nodePath |
| `get_tileset_source_count` | Get the number of sources in a TileSet file. | projectPath, tileSetPath |
| `get_tileset_sources` | List tile sources in a TileSet resource file. | projectPath, tilesetPath |
| `get_time_in_game` | Get current tick/time info from the running game. | None |
| `get_time_scale` | Get the current time scale from the game. | None |
| `get_time_since_start` | Get elapsed time since game start in seconds. | None |
| `get_timer_one_shot` | Get whether a Timer fires once or repeats. | nodePath |
| `get_timer_time_left` | Get remaining time on a Timer node. | nodePath |
| `get_timer_wait_time` | Get the wait_time of a Timer node. | nodePath |
| `get_unix_time` | Get current Unix timestamp from the Godot engine. | None |
| `get_vehicle_body_3d_info` | Get VehicleBody3D speed, engine force, brake. | nodePath |
| `get_vehicle_body_speed` | Get the speed of a VehicleBody3D in the game. | nodePath |
| `get_video_stream_position` | Get current playback position of VideoStreamPlayer. | nodePath |
| `get_visible_rect` | Get the visible rectangle of the 2D viewport. | None |
| `get_websocket_peer_state` | Get WebSocketPeer ready state and close code. | None |
| `get_window_info` | Get size, position, fullscreen state of window. | None |
| `get_xr_anchor_info` | Get XRAnchor3D position and confidence. | nodePath |
| `get_xr_interface_list` | List available XR interfaces in Godot. | None |
| `get_xr_is_tracking` | Check if XR tracking is active. | None |
| `grab_focus` | Give keyboard focus to a Control node in the game. | nodePath |
| `gradient_create` | Create a Gradient .tres resource with colors and offsets. | projectPath, gradientPath, colors, offsets |
| `gridmap_clear` | Clear all cells in a GridMap in the running game. | nodePath |
| `gridmap_get_used_cells` | Get all used cells in a GridMap in the running game. | nodePath |
| `gridmap_set_cell` | Set a cell in a GridMap node in the running game. | nodePath, x, y, z, itemIndex |
| `has_signal` | Check if a node has a specific signal. | nodePath, signalName |
| `hash_string_md5` | Compute MD5 hash of a string in Godot. | text |
| `hash_string_sha256` | Compute SHA-256 hash of a string in Godot. | text |
| `hide_popup` | Hide a Popup node. | nodePath |
| `http_request_get` | Make HTTP GET request from a running Godot game. | url |
| `http_request_post` | Make HTTP POST request from a running Godot game. | url, body |
| `import_get_config` | Read the .import file next to a resource and return it as parsed JSON. | projectPath, resourcePath |
| `import_list_presets` | Scan project for all .import files, group by importer= type, return summary. | projectPath |
| `import_reimport` | Run godot --headless --import to reimport all resources in the project. | projectPath |
| `import_set_config` | Write/merge settings into the .import file for a resource. | projectPath, resourcePath, settings |
| `initialize_xr_interface` | Initialize an XR interface by name. | interfaceName |
| `install_editor_plugin` | Install the packaged Godot MCP editor plugin into a project. | projectPath |
| `instantiate_class_check` | Check if a class can be instantiated in the game. | className |
| `is_action_just_pressed` | Check if input action was pressed this frame. | actionName |
| `is_action_just_released` | Check if input action was released this frame. | actionName |
| `is_action_pressed` | Check if an input action is pressed in the game. | actionName |
| `is_character_body_3d_on_floor` | Check if CharacterBody3D is on the floor. | nodePath |
| `is_character_on_floor` | Check if a CharacterBody is on the floor in game. | nodePath |
| `is_game_paused` | Check if the game's SceneTree is currently paused. | None |
| `is_input_action_pressed` | Check if an input action is currently pressed. | actionName |
| `is_key_pressed` | Check if a keyboard key is currently pressed. | keycode |
| `is_multiplayer_authority` | Check if local peer is authority for a node. | nodePath |
| `is_multiplayer_server` | Check if this peer is the multiplayer server. | None |
| `is_navigation_agent_2d_finished` | Check if NavigationAgent2D reached its target. | nodePath |
| `is_navigation_agent_3d_finished` | Check if NavigationAgent3D reached its target. | nodePath |
| `is_navigation_agent_3d_target_reachable` | Check if NavigationAgent3D target is reachable. | nodePath |
| `is_navigation_finished` | Check if a NavigationAgent reached its target in game. | nodePath |
| `is_ray_cast_colliding` | Check if a RayCast node is colliding in game. | nodePath |
| `is_timer_stopped` | Check if a Timer node is stopped. | nodePath |
| `is_video_stream_playing` | Check if a VideoStreamPlayer is playing. | nodePath |
| `item_list_add_item` | Add an item to an ItemList in the running game. | nodePath, label |
| `json_parse_in_godot` | Parse a JSON string to a Godot value. | jsonString |
| `json_stringify_in_godot` | Serialize a value to JSON string in Godot. | data |
| `line_edit_set_text` | Set the text of a LineEdit in the running game. | nodePath |
| `list_all_autoloads` | List all autoload singletons defined in project.godot. | projectPath |
| `list_all_signal_connections` | List all signals and connections on a node. | nodePath |
| `list_connected_signals_in_game` | List all signal connections on a node in game. | nodePath |
| `list_custom_classes` | List all class_name declarations across all GDScript files. | projectPath |
| `list_input_actions` | List all input actions defined in the project. | None |
| `list_system_fonts` | List all available system fonts via Godot. | projectPath |
| `load_sprite` | Load a sprite into a Sprite2D node | projectPath, scenePath, nodePath, texturePath |
| `locale_list_tr_calls` | Scan GDScript files for tr() translation key calls. | projectPath |
| `look_at_3d` | Make a Node3D look at a world position. | nodePath |
| `look_at_target` | Make a Node3D look at a world-space target in game. | nodePath |
| `make_http_request` | Send an HTTP request from an HTTPRequest node in game. | nodePath, url |
| `manage_autoloads` | Add, remove, or list autoloads in a Godot project | projectPath, action |
| `manage_ci_pipeline` | Create/read GitHub Actions workflow for automated Godot exports | projectPath, action |
| `manage_input_map` | Add, remove, or list input actions and bindings | projectPath, action |
| `manage_layers` | List/set named layer definitions in project | projectPath, action |
| `manage_plugins` | List/enable/disable editor plugins | projectPath, action |
| `manage_translations` | List/add/remove translation files in project | projectPath, action |
| `map_to_local_tilemap` | Convert TileMap map coords to local position. | nodePath, x, y |
| `map_to_world` | Convert TileMap cell coords to world position. | nodePath |
| `monitor_properties` | Record node property values over N frames for analysis. | queries |
| `move_and_slide_character` | Call move_and_slide on a CharacterBody in game. | nodePath |
| `move_toward_3d` | Move a Node3D toward a target position in game. | nodePath |
| `multimesh_set_instance_count` | Set the instance count of a MultiMesh in the running game. | nodePath, count |
| `multimesh_set_instance_transform` | Set a MultiMesh instance transform in the running game. | nodePath, instanceIndex |
| `navigation_agent_set_target` | Set the target position of a NavigationAgent in game. | nodePath |
| `open_url_in_browser` | Open a URL in the system browser from the game. | url |
| `overlap_sphere_3d` | Find all bodies in a sphere area in the running game. | None |
| `particle_restart` | Restart a GPUParticles or CPUParticles node. | nodePath |
| `particle_set_emitting` | Start or stop particle emission on a Particles node. | nodePath, emitting |
| `path_2d_add_point` | Add a point to a Path2D curve in a scene file. | projectPath, scenePath, x, y |
| `path_3d_add_point` | Add a point to a Path3D curve in a scene file. | projectPath, scenePath, x, y, z |
| `path2d_set_points` | Set the curve points on a Path2D in the running game. | nodePath, points |
| `pause_game` | Pause the game's SceneTree (stops _process on all nodes). | None |
| `pin_soft_body_3d_point` | Pin a SoftBody3D vertex to fix it in place. | nodePath, pointIndex |
| `play_video_stream` | Play the VideoStreamPlayer node. | nodePath |
| `plugin_disable` | Disable a plugin in project.godot by its addons/ path. | projectPath, pluginPath |
| `plugin_enable` | Enable a plugin in project.godot by its addons/ path. | projectPath, pluginPath |
| `plugin_list` | List all plugins in the project and their enabled state. | projectPath |
| `progress_bar_set_value` | Set the value of a ProgressBar in the running game. | nodePath, value |
| `ray_cast_force_update` | Force a RayCast to update collision in the game. | nodePath |
| `release_focus` | Release keyboard focus from a Control node. | nodePath |
| `remove_autoload` | Remove an autoload singleton from the project. | projectPath, name |
| `remove_input_action` | Remove an input action from project.godot. | projectPath, actionName |
| `remove_item_list_item` | Remove an item from an ItemList by index. | nodePath, idx |
| `remove_path_3d_point` | Remove a point from a Path3D's Curve3D. | nodePath, idx |
| `remove_signal_connection` | Remove a signal connection from a scene file. | projectPath, scenePath, signal, from, to, method |
| `replay_recording` | Replay a recorded input sequence in the running game. | events |
| `reset_skeleton_3d_pose` | Reset all bone poses on a Skeleton3D to rest. | nodePath |
| `reset_skeleton_pose` | Reset all Skeleton3D bone poses to rest in game. | nodePath |
| `restart_gpu_particles_3d` | Restart GPUParticles3D emission. | nodePath |
| `restart_particles` | Restart a particle emitter node in the running game. | nodePath |
| `rich_text_append` | Append BBCode text to a RichTextLabel in the game. | nodePath, bbcode |
| `rpc_call` | Call a remote procedure (RPC) on a node method. | nodePath, methodName |
| `run_stress_test` | Run the game for N frames and report FPS and node leaks. | None |
| `sample_path_2d_baked` | Sample a point on a baked Path2D at offset. | nodePath |
| `sample_path_3d_at_offset` | Sample Path3D Curve3D at a baked offset. | nodePath, offset |
| `send_message_to_game` | Send a custom message to the running game MCP server. | messageType |
| `send_multiplayer_rpc` | Call an RPC method on a node for a peer in game. | nodePath, methodName |
| `send_websocket_text` | Send a text message via a WebSocketPeer node. | nodePath, message |
| `set_2d_speed_scale` | Set speed scale of a Node2D or AnimationPlayer. | nodePath |
| `set_angular_velocity` | Set angular_velocity on a RigidBody in the game. | nodePath |
| `set_animated_sprite_2d_speed` | Set playback speed of AnimatedSprite2D. | nodePath |
| `set_blend_parameter` | Set a blend parameter value in AnimationTree. | nodePath, paramName |
| `set_blend_shape_value` | Set a blend shape value on a MeshInstance3D. | nodePath |
| `set_bone_attachment_3d_bone_name` | Set the bone name on a BoneAttachment3D. | nodePath, boneName |
| `set_bone_pose` | Set the local pose of a Skeleton3D bone in game. | nodePath |
| `set_box_shape_size_3d` | Set extents on a BoxShape3D collision shape. | nodePath |
| `set_canvas_item_clip` | Enable/disable clipping on a CanvasItem node. | nodePath |
| `set_capsule_shape_size` | Set radius/height on a CapsuleShape2D/3D shape. | nodePath |
| `set_character_body_2d_velocity` | Set velocity on a CharacterBody2D node. | nodePath |
| `set_character_body_3d_velocity` | Set velocity of a CharacterBody3D node. | None |
| `set_character_body_velocity` | Set the velocity on a CharacterBody in the game. | nodePath |
| `set_check_box_pressed` | Set the pressed state of a CheckBox in game. | nodePath |
| `set_circle_shape_radius` | Set radius on a CircleShape2D collision shape. | nodePath |
| `set_clipboard` | Set the system clipboard text from the running game. | text |
| `set_color_picker_color` | Set the color on a ColorPicker node in game. | nodePath, r, g, b |
| `set_color_rect_color` | Set the color on a ColorRect in the game. | nodePath |
| `set_compressor_threshold` | Set threshold on an AudioEffectCompressor. | busName, effectIndex |
| `set_csg_shape_operation` | Set CSGShape3D boolean operation (0=Union,1=Intersect,2=Subtract). | nodePath, operation |
| `set_decal_3d_albedo_mix` | Set the albedo mix of a Decal3D node. | nodePath, albedoMix |
| `set_decal_3d_size` | Set the size of a Decal3D node. | nodePath, x, y, z |
| `set_delay_dry` | Set dry on an AudioEffectDelay on a bus. | busName, effectIndex |
| `set_display_mode` | Set the window display mode in the running game. | None |
| `set_engine_target_fps` | Set Engine.max_fps at runtime. | fps |
| `set_engine_time_scale` | Set Engine time scale (1.0=normal, 0.5=half speed). | timeScale |
| `set_eq_band_gain` | Set a band gain on an AudioEffectEQ on a bus. | busName, effectIndex, bandIndex |
| `set_font_default_size` | Set default size of a FontFile resource. | projectPath, fontPath, size |
| `set_global_transform_3d` | Set the global position of a Node3D in the game. | nodePath |
| `set_gpu_particles_3d_amount` | Set the particle amount on GPUParticles3D. | nodePath, amount |
| `set_gpu_particles_3d_lifetime` | Set particle lifetime on GPUParticles3D. | nodePath, lifetime |
| `set_gpu_particles_3d_one_shot` | Set GPUParticles3D one_shot mode. | nodePath, oneShot |
| `set_gravity_scale` | Set gravity_scale on a RigidBody in the running game. | nodePath, gravityScale |
| `set_gridmap_cell_item` | Set item at GridMap cell. itemId -1 clears cell. | nodePath, x, y, z, itemId |
| `set_h_slider_value` | Set value on an HSlider node. | nodePath, value |
| `set_line_edit_text` | Set the text on a LineEdit node in the game. | nodePath, text |
| `set_linear_velocity` | Set linear_velocity on a RigidBody in the game. | nodePath |
| `set_max_fps` | Set the maximum FPS cap for the running game. | maxFps |
| `set_mesh_instance_cast_shadow` | Set shadow casting mode on MeshInstance3D. | nodePath |
| `set_mesh_lod_bias` | Set LOD bias on a MeshInstance3D node. | nodePath |
| `set_mesh_transparency` | Set transparency value on a MeshInstance3D node. | nodePath |
| `set_mouse_mode` | Set mouse mode: visible/hidden/captured/confined. | None |
| `set_multimesh_instance_color` | Set color of one MultiMesh instance. | nodePath, instanceIndex |
| `set_multimesh_instance_count` | Set visible instance count on MultiMeshInstance3D. | nodePath, count |
| `set_multimesh_instance_transform_3d` | Set transform of one MultiMesh instance. | nodePath, instanceIndex |
| `set_multiplayer_authority` | Set the multiplayer authority of a node. | nodePath |
| `set_navigation_agent_2d_target` | Set the target position of NavigationAgent2D. | nodePath |
| `set_navigation_agent_3d_target` | Set the target position of NavigationAgent3D. | nodePath |
| `set_navigation_agent_target` | Set the target position on a NavigationAgent in game. | nodePath |
| `set_navigation_region_3d_enabled` | Enable or disable a NavigationRegion3D. | nodePath, enabled |
| `set_nine_patch_draw_center` | Set draw_center on a NinePatchRect node. | nodePath |
| `set_nine_patch_margins` | Set margins on a NinePatchRect node. | nodePath |
| `set_particle_amount` | Set emission amount of a CPUParticles2D/3D or GPU node. | nodePath |
| `set_particle_emission_rate` | Set emission amount/lifetime on a particle node in game. | nodePath |
| `set_particle_explosiveness` | Set explosiveness of a particle system node. | nodePath |
| `set_particle_lifetime` | Set lifetime of particles in a particle system. | nodePath |
| `set_particle_one_shot` | Set one-shot mode on a particle system node. | nodePath |
| `set_particle_randomness` | Set randomness of a particle system node. | nodePath |
| `set_particle_speed_scale` | Set speed scale of a particle system node. | nodePath |
| `set_particles_amount` | Set the emission amount on a Particles node in game. | nodePath |
| `set_particles_emitting` | Start or stop particle emission in the running game. | nodePath |
| `set_particles_explosiveness` | Set explosiveness on a particles node (0-1). | nodePath |
| `set_particles_lifetime` | Set particle lifetime on a particles node. | nodePath |
| `set_particles_one_shot` | Set one-shot mode on a particles node. | nodePath |
| `set_process_enabled` | Enable or disable process on a node in the game. | nodePath |
| `set_progress_bar_max` | Set max_value of a ProgressBar node. | nodePath |
| `set_progress_bar_value` | Set the value on a ProgressBar node in the game. | nodePath |
| `set_range_min_max` | Set min/max on a Range node (Slider, SpinBox). | nodePath |
| `set_range_value` | Set value on a Range node (Slider, SpinBox, etc.). | nodePath, value |
| `set_ray_cast_2d_target` | Set the target position of a RayCast2D node. | nodePath |
| `set_ray_cast_3d_target` | Set the target position of a RayCast3D node. | nodePath |
| `set_ray_cast_enabled` | Enable or disable a RayCast node in the game. | nodePath |
| `set_rect_shape_size` | Set size on a RectangleShape2D collision shape. | nodePath |
| `set_reverb_room_size` | Set room_size on an AudioEffectReverb on a bus. | busName, effectIndex |
| `set_reverb_wet` | Set wet (mix) on an AudioEffectReverb on a bus. | busName, effectIndex |
| `set_rich_text_bbcode` | Set BBCode text on a RichTextLabel node. | nodePath, text |
| `set_skeleton_3d_bone_enabled` | Enable or disable a Skeleton3D bone. | nodePath, boneIndex |
| `set_skeleton_3d_bone_pose_position` | Set a bone pose position on Skeleton3D. | nodePath, boneIndex |
| `set_skeleton_bone_pose_position` | Set position of a bone in Skeleton3D. | nodePath, boneName |
| `set_skeleton_bone_pose_rotation` | Set a bone pose rotation in a Skeleton3D in game. | nodePath, boneName |
| `set_slider_step` | Set step size of a HSlider or VSlider. | nodePath, step |
| `set_slider_value` | Set the value on a Slider node in the game. | nodePath |
| `set_soft_body_3d_simulation_precision` | Set SoftBody3D simulation precision. | nodePath, precision |
| `set_spin_box_value` | Set the value on a SpinBox node in the game. | nodePath |
| `set_spring_arm_3d_length` | Set the spring length on a SpringArm3D node. | nodePath, springLength |
| `set_sprite_2d_flip` | Set horizontal/vertical flip on a Sprite2D node. | nodePath |
| `set_sprite_2d_frame` | Set the current frame of an animated Sprite2D. | nodePath |
| `set_sprite_2d_hframes` | Set horizontal frame count of a Sprite2D sprite sheet. | nodePath |
| `set_sprite_2d_vframes` | Set vertical frame count of a Sprite2D sprite sheet. | nodePath |
| `set_sprite_hframes` | Set horizontal frame count on a Sprite2D. | nodePath |
| `set_sprite_region_enabled` | Enable/disable texture region on a Sprite2D. | nodePath |
| `set_sprite_region_rect` | Set texture region rect on a Sprite2D. | nodePath |
| `set_sprite_texture` | Set the texture on a Sprite2D in the game. | nodePath, texturePath |
| `set_sprite_vframes` | Set vertical frame count on a Sprite2D. | nodePath |
| `set_text_edit_text` | Set the text content on a TextEdit in the game. | nodePath, text |
| `set_texture_rect_flip` | Flip TextureRect horizontally/vertically. | nodePath |
| `set_texture_rect_stretch` | Set stretch mode on a TextureRect node. | nodePath |
| `set_texture_rect_stretch_mode` | Set TextureRect stretch mode (0-6). | nodePath, stretchMode |
| `set_texture_rect_texture` | Set the texture on a TextureRect in the game. | nodePath, texturePath |
| `set_tilemap_cell` | Set a tile at a cell position in a TileMap. | nodePath |
| `set_tilemap_layer_enabled` | Enable or disable a TileMap layer in game. | nodePath |
| `set_time_scale` | Set Engine.time_scale in the running game. | None |
| `set_timer_one_shot` | Set whether a Timer fires once (true) or repeats (false). | nodePath |
| `set_timer_wait_time` | Set the wait_time of a Timer node. | nodePath, waitTime |
| `set_vehicle_body_3d_engine_force` | Set VehicleBody3D engine force value. | nodePath, engineForce |
| `set_vehicle_brake` | Set the brake force on a VehicleBody3D in game. | nodePath |
| `set_vehicle_engine_force` | Set the engine force on a VehicleBody3D in game. | nodePath |
| `set_vehicle_steering` | Set the steering on a VehicleBody3D in game. | nodePath |
| `set_video_stream_volume` | Set volume on a VideoStreamPlayer node. | nodePath |
| `set_window_always_on_top` | Set always-on-top mode for the game window. | None |
| `set_window_borderless` | Set borderless window mode at runtime. | None |
| `set_window_fullscreen` | Set window fullscreen mode at runtime. | None |
| `set_window_position` | Set window position on screen. | x, y |
| `set_window_size` | Set the game window size from the running game. | width, height |
| `set_window_title` | Set the game window title. | title |
| `set_xr_world_scale` | Set the XR world scale factor. | scale |
| `setup_enet_multiplayer` | Set up ENetMultiplayerPeer as server or client in game. | mode |
| `show_dialog` | Show a dialog node (AcceptDialog/etc.) in game. | nodePath |
| `simulate_action_press` | Simulate pressing an input action in the running game. | actionName |
| `simulate_action_release` | Simulate releasing an input action in the running game. | actionName |
| `simulate_input_action` | Simulate an input action press/release in the game. | actionName |
| `skeleton_get_bones` | Get bones from a Skeleton2D or Skeleton3D in the game. | nodePath |
| `skeleton_set_bone_pose` | Set a bone pose on a Skeleton2D or Skeleton3D in the game. | nodePath, boneName |
| `slider_set_value` | Set the value of a Slider node in the running game. | nodePath, value |
| `sort_item_list` | Sort items in an ItemList alphabetically. | nodePath |
| `sphere_cast_3d` | Cast a 3D sphere and get the first hit. | fromX, fromY, fromZ, toX, toY, toZ, radius |
| `spring_arm_3d_set_length` | Set the spring length of a SpringArm3D in the game. | nodePath, springLength |
| `spriteframes_add_frame` | Add a frame (texture) to a SpriteFrames animation (uses headless Godot). | projectPath, spriteframesPath, animationName, texturePath |
| `spriteframes_create` | Create a SpriteFrames .tres resource file (uses headless Godot). | projectPath, spriteframesPath |
| `start_recording` | Start recording input events for later replay. | None |
| `start_timer` | Start a Timer node in the running game. | nodePath |
| `stop_recording` | Stop input recording and return the event sequence. | None |
| `stop_timer` | Stop a Timer node in the running game. | nodePath |
| `stop_video_stream` | Stop the VideoStreamPlayer node. | nodePath |
| `texture_rect_set_texture` | Set the texture of a TextureRect in the running game. | nodePath, texturePath |
| `tilemap_clear` | Clear all cells in a TileMap layer in the running game. | nodePath |
| `tilemap_get_used_cells` | Get all used cell coords in a TileMap layer in the running game. | nodePath |
| `tilemap_set_cell` | Set a cell in a TileMap node in the running game. | nodePath, x, y, sourceId |
| `tileset_add_source` | Add a TileSetAtlasSource to an existing TileSet .tres (uses headless Godot). | projectPath, tilesetPath, texturePath |
| `tileset_create` | Create a new TileSet .tres resource file (uses headless Godot). | projectPath, tilesetPath |
| `timer_set_wait_time` | Set the wait_time of a Timer node in the running game. | nodePath, waitTime |
| `timer_start` | Start a Timer node in the running game. | nodePath |
| `timer_stop` | Stop a Timer node in the running game. | nodePath |
| `unix_time_to_datetime` | Convert Unix timestamp to a date/time dict. | unixTime |
| `unpause_game` | Unpause the game's SceneTree (resumes processing). | None |
| `unpin_soft_body_3d_point` | Unpin a previously pinned SoftBody3D vertex. | nodePath, pointIndex |
| `vcs_branch_list` | Run git branch -a in the projectPath and return array of branch names. | projectPath |
| `vcs_checkout` | Run git checkout <branch> in the projectPath. | projectPath, branch |
| `vcs_commit` | Run git commit -m <message> in the projectPath. | projectPath, message |
| `vcs_diff` | Run git diff [file?] in the projectPath. | projectPath |
| `vcs_stage` | Run git add on specified files (or "." for all) in the projectPath. | projectPath, files |
| `vcs_status` | Run git status --short in the projectPath and return parsed output. | projectPath |
| `visibility_notifier_set_rect` | Set the Rect of a VisibleOnScreenNotifier2D in the game. | nodePath, width, height |
| `wait_for_signal` | Wait for a signal from a node in the running game. | nodePath, signalName |
| `warp_mouse` | Warp the mouse cursor to a position in the game. | x, y |
| `world_to_map` | Convert world position to TileMap cell coords. | nodePath |

## Scenes and nodes

| Tool | Description | Required arguments |
|---|---|---|
| `add_accept_dialog_to_scene` | Add an AcceptDialog node to a scene file. | projectPath, scenePath |
| `add_anchor_3d_to_scene` | Add an Anchor3D node to a scene. | projectPath, scenePath |
| `add_animatable_body_2d_to_scene` | Add AnimatableBody2D node to a scene file. | projectPath, scenePath |
| `add_animatable_body_3d_to_scene` | Add AnimatableBody3D node to a scene file. | projectPath, scenePath |
| `add_animated_sprite_3d_to_scene` | Add an AnimatedSprite3D node to a scene file. | projectPath, scenePath |
| `add_animation_tree_to_scene` | Add an AnimationTree node to a scene file. | projectPath, scenePath |
| `add_area_3d_to_scene` | Add an Area3D node to a scene file. | projectPath, scenePath |
| `add_aspect_ratio_container_to_scene` | Add an AspectRatioContainer node to a scene file. | projectPath, scenePath |
| `add_audio_listener_2d_to_scene` | Add AudioListener2D node to a scene file. | projectPath, scenePath |
| `add_billboard_3d_to_scene` | Add a billboard Sprite3D node to a scene file. | projectPath, scenePath |
| `add_bone_2d_to_scene` | Add Bone2D node to a scene file. | projectPath, scenePath |
| `add_bone_attachment_3d_to_scene` | Add a BoneAttachment3D node to a scene file. | projectPath, scenePath |
| `add_box_container_to_scene` | Add an HBoxContainer or VBoxContainer to a scene. | projectPath, scenePath |
| `add_camera_2d_to_scene` | Add a Camera2D node to a scene file. | projectPath, scenePath |
| `add_camera_3d_to_scene` | Add a Camera3D node to a scene file. | projectPath, scenePath |
| `add_canvas_group_to_scene` | Add CanvasGroup node to a scene file. | projectPath, scenePath |
| `add_canvas_layer_to_scene` | Add a CanvasLayer node to a scene file. | projectPath, scenePath |
| `add_center_container_to_scene` | Add a CenterContainer node to a scene file. | projectPath, scenePath |
| `add_character_body_2d_to_scene` | Add a CharacterBody2D node to a scene file. | projectPath, scenePath |
| `add_character_body_3d_to_scene` | Add a CharacterBody3D node to a scene file. | projectPath, scenePath |
| `add_check_box_to_scene` | Add CheckBox toggle node to a scene file. | projectPath, scenePath |
| `add_check_button_to_scene` | Add a CheckButton node to a scene file. | projectPath, scenePath |
| `add_child_node_in_game` | Instantiate a scene and add as child in game. | parentNodePath, scenePath |
| `add_code_edit_to_scene` | Add a CodeEdit node to a scene file. | projectPath, scenePath |
| `add_collision_polygon_2d_to_scene` | Add a CollisionPolygon2D node to a scene file. | projectPath, scenePath |
| `add_collision_polygon_3d_to_scene` | Add a CollisionPolygon3D node to a scene file. | projectPath, scenePath |
| `add_collision_shape_2d_to_scene` | Add a CollisionShape2D node to a scene file. | projectPath, scenePath |
| `add_collision_shape_3d_to_scene` | Add a CollisionShape3D node to a scene file. | projectPath, scenePath |
| `add_color_picker_button_to_scene` | Add a ColorPickerButton node to a scene file. | projectPath, scenePath |
| `add_color_picker_to_scene` | Add ColorPicker widget node to a scene file. | projectPath, scenePath |
| `add_color_rect_to_scene` | Add a ColorRect node to a scene file. | projectPath, scenePath |
| `add_confirmation_dialog_to_scene` | Add a ConfirmationDialog node to a scene file. | projectPath, scenePath |
| `add_cpu_particles_2d_to_scene` | Add a CPUParticles2D node to a scene file. | projectPath, scenePath |
| `add_cpu_particles_3d_to_scene` | Add a CPUParticles3D node to a scene file. | projectPath, scenePath |
| `add_csg_box_to_scene` | Add a CSGBox3D node to a scene file. | projectPath, scenePath |
| `add_csg_combiner_to_scene` | Add a CSGCombiner3D node to a scene file. | projectPath, scenePath |
| `add_csg_cylinder_to_scene` | Add a CSGCylinder3D node to a scene file. | projectPath, scenePath |
| `add_csg_sphere_to_scene` | Add a CSGSphere3D node to a scene file. | projectPath, scenePath |
| `add_csg_torus_to_scene` | Add a CSGTorus3D node to a scene file. | projectPath, scenePath |
| `add_decal_to_scene` | Add a Decal node to a scene file. | projectPath, scenePath |
| `add_directional_light_2d_to_scene` | Add a DirectionalLight2D node to a scene file. | projectPath, scenePath |
| `add_directional_light_3d_to_scene` | Add a DirectionalLight3D node to a scene file. | projectPath, scenePath |
| `add_file_dialog_to_scene` | Add a FileDialog node to a scene file. | projectPath, scenePath |
| `add_flow_container_to_scene` | Add an HFlowContainer or VFlowContainer to a scene. | projectPath, scenePath |
| `add_fog_volume_to_scene` | Add a FogVolume node to a scene file. | projectPath, scenePath |
| `add_gpu_particles_2d_to_scene` | Add a GPUParticles2D node to a scene file. | projectPath, scenePath |
| `add_gpu_particles_3d_to_scene` | Add a GPUParticles3D node to a scene file. | projectPath, scenePath |
| `add_graph_edit_to_scene` | Add a GraphEdit node to a scene file. | projectPath, scenePath |
| `add_graph_node_to_scene` | Add a GraphNode node to a scene file. | projectPath, scenePath |
| `add_grid_container_to_scene` | Add a GridContainer to a scene. | projectPath, scenePath |
| `add_groove_joint_2d_to_scene` | Add a GrooveJoint2D node to a scene file. | projectPath, scenePath |
| `add_h_scroll_bar_to_scene` | Add HScrollBar node to a scene file. | projectPath, scenePath |
| `add_h_separator_to_scene` | Add HSeparator line node to a scene file. | projectPath, scenePath |
| `add_h_slider_to_scene` | Add HSlider node to a scene file. | projectPath, scenePath |
| `add_h_split_container_to_scene` | Add an HSplitContainer to a scene. | projectPath, scenePath |
| `add_hflow_container_to_scene` | Add an HFlowContainer node to a scene file. | projectPath, scenePath |
| `add_hinge_joint_3d_to_scene` | Add a HingeJoint3D node to a scene file. | projectPath, scenePath |
| `add_http_request_to_scene` | Add an HTTPRequest node to a scene file. | projectPath, scenePath |
| `add_item_list_to_scene` | Add an ItemList node to a scene file. | projectPath, scenePath |
| `add_joint_2d_damped_spring_to_scene` | Add a DampedSpringJoint2D node to a scene file. | projectPath, scenePath |
| `add_joint_2d_groove_to_scene` | Add a GrooveJoint2D node to a scene file. | projectPath, scenePath |
| `add_joint_2d_pin_to_scene` | Add a PinJoint2D node to a scene file. | projectPath, scenePath |
| `add_joint_3d_to_scene` | Add a Generic6DOFJoint3D node to a scene file. | projectPath, scenePath |
| `add_label_3d_to_scene` | Add Label3D node (3D world space text) to scene. | projectPath, scenePath |
| `add_light_occluder_2d_to_scene` | Add LightOccluder2D node to a scene file. | projectPath, scenePath |
| `add_lightmap_gi_to_scene` | Add a LightmapGI node to a scene file. | projectPath, scenePath |
| `add_line_2d_to_scene` | Add a Line2D node to a scene file. | projectPath, scenePath |
| `add_link_button_to_scene` | Add a LinkButton node to a scene file. | projectPath, scenePath |
| `add_margin_container_to_scene` | Add a MarginContainer node to a scene file. | projectPath, scenePath |
| `add_marker_2d_to_scene` | Add a Marker2D node to a scene file. | projectPath, scenePath |
| `add_marker_3d_to_scene` | Add a Marker3D node to a scene file. | projectPath, scenePath |
| `add_menu_button_to_scene` | Add a MenuButton node to a scene file. | projectPath, scenePath |
| `add_mesh_instance_2d_to_scene` | Add a MeshInstance2D node to a scene file. | projectPath, scenePath |
| `add_mesh_instance_3d_to_scene` | Add MeshInstance3D node to a scene file. | projectPath, scenePath |
| `add_multi_mesh_instance_3d_to_scene` | Add a MultiMeshInstance3D node to a scene file. | projectPath, scenePath |
| `add_multiplayer_spawner_to_scene` | Add a MultiplayerSpawner node to a scene file. | projectPath, scenePath |
| `add_multiplayer_synchronizer_to_scene` | Add a MultiplayerSynchronizer to a scene file. | projectPath, scenePath |
| `add_navigation_agent_2d_to_scene` | Add a NavigationAgent2D node to a scene file. | projectPath, scenePath |
| `add_navigation_agent_3d_to_scene` | Add a NavigationAgent3D node to a scene file. | projectPath, scenePath |
| `add_navigation_link_2d_to_scene` | Add NavigationLink2D to a scene file. | projectPath, scenePath |
| `add_navigation_link_3d_to_scene` | Add NavigationLink3D to a scene file. | projectPath, scenePath |
| `add_navigation_obstacle_2d_to_scene` | Add NavigationObstacle2D to a scene file. | projectPath, scenePath |
| `add_navigation_obstacle_3d_to_scene` | Add NavigationObstacle3D to a scene file. | projectPath, scenePath |
| `add_navigation_region_2d_to_scene` | Add a NavigationRegion2D node to a scene file. | projectPath, scenePath |
| `add_navigation_region_3d_to_scene` | Add a NavigationRegion3D node to a scene file. | projectPath, scenePath |
| `add_nine_patch_rect_to_scene` | Add a NinePatchRect node to a scene file. | projectPath, scenePath |
| `add_node` | Add a node to an existing scene | projectPath, scenePath, nodeType, nodeName |
| `add_node_2d_to_scene` | Add a plain Node2D node to a scene file. | projectPath, scenePath |
| `add_node_3d_to_scene` | Add a plain Node3D node to a scene file. | projectPath, scenePath |
| `add_node_to_group` | Add a node to a group in a scene file. | projectPath, scenePath, nodeName, groupName |
| `add_node_to_group_in_game` | Add a node to a group in the running game. | nodePath, groupName |
| `add_node_to_group_runtime` | Add a node to a group in the running game. | nodePath, groupName |
| `add_occluder_3d_to_scene` | Add an OccluderInstance3D node to a scene file. | projectPath, scenePath |
| `add_occluder_instance_3d_to_scene` | Add an OccluderInstance3D to a scene file. | projectPath, scenePath |
| `add_omni_light_3d_to_scene` | Add an OmniLight3D node to a scene file. | projectPath, scenePath |
| `add_open_xr_camera_3d_to_scene` | Add OpenXRCamera3D node to a scene file. | projectPath, scenePath |
| `add_open_xr_controller_to_scene` | Add OpenXRController3D to a scene file. | projectPath, scenePath |
| `add_open_xr_hand_to_scene` | Add an OpenXRHand node to a scene file. | projectPath, scenePath |
| `add_open_xr_hand_tracker_to_scene` | Add OpenXRHandTracker to a scene file. | projectPath, scenePath |
| `add_open_xr_origin_to_scene` | Add OpenXROrigin3D node to a scene file. | projectPath, scenePath |
| `add_option_button_to_scene` | Add an OptionButton node to a scene file. | projectPath, scenePath |
| `add_panel_container_to_scene` | Add a PanelContainer node to a scene file. | projectPath, scenePath |
| `add_panel_to_scene` | Add a Panel control node to a scene. | projectPath, scenePath |
| `add_parallax_2d_to_scene` | Add Parallax2D node to a scene file (Godot 4.3+). | projectPath, scenePath |
| `add_path_2d_node` | Add a Path2D node to a scene file. | projectPath, scenePath |
| `add_path_2d_to_scene` | Add a Path2D node to a scene. | projectPath, scenePath |
| `add_path_3d_to_scene` | Add Path3D node (3D bezier path) to a scene. | projectPath, scenePath |
| `add_path_follow_2d_to_scene` | Add a PathFollow2D node to a scene file. | projectPath, scenePath |
| `add_path_follow_3d_to_scene` | Add a PathFollow3D node to a scene file. | projectPath, scenePath |
| `add_physical_bone_2d_to_scene` | Add PhysicalBone2D node to a scene file. | projectPath, scenePath |
| `add_physical_bone_3d_to_scene` | Add PhysicalBone3D node to a scene file. | projectPath, scenePath |
| `add_physics_body_3d_static_to_scene` | Add a StaticBody3D node to a scene file. | projectPath, scenePath |
| `add_pin_joint_2d_to_scene` | Add a PinJoint2D node to a scene file. | projectPath, scenePath |
| `add_point_light_2d_to_scene` | Add a PointLight2D node to a scene file. | projectPath, scenePath |
| `add_polygon_2d_to_scene` | Add a Polygon2D node to a scene file. | projectPath, scenePath |
| `add_popup_menu_to_scene` | Add a PopupMenu node to a scene file. | projectPath, scenePath |
| `add_popup_panel_to_scene` | Add a PopupPanel node to a scene file. | projectPath, scenePath |
| `add_ray_cast_2d_to_scene` | Add a RayCast2D node to a scene file. | projectPath, scenePath |
| `add_ray_cast_3d_to_scene` | Add a RayCast3D node to a scene file. | projectPath, scenePath |
| `add_reflection_probe_to_scene` | Add a ReflectionProbe node to a scene file. | projectPath, scenePath |
| `add_remote_transform_2d_to_scene` | Add a RemoteTransform2D node to a scene file. | projectPath, scenePath |
| `add_remote_transform_3d_to_scene` | Add a RemoteTransform3D node to a scene file. | projectPath, scenePath |
| `add_rich_text_label_to_scene` | Add a RichTextLabel node to a scene file. | projectPath, scenePath |
| `add_rigid_body_2d_to_scene` | Add a RigidBody2D node to a scene file. | projectPath, scenePath |
| `add_scene_instance` | Add a PackedScene instance to a scene file. | projectPath, parentScenePath, packedScenePath |
| `add_scene_tree_timer_via_code` | Create a SceneTree one-shot timer in the game. | None |
| `add_scroll_container_to_scene` | Add a ScrollContainer node to a scene file. | projectPath, scenePath |
| `add_separator_to_scene` | Add an HSeparator node to a scene file. | projectPath, scenePath |
| `add_shape_cast_2d_to_scene` | Add a ShapeCast2D node to a scene file. | projectPath, scenePath |
| `add_shape_cast_3d_to_scene` | Add a ShapeCast3D node to a scene file. | projectPath, scenePath |
| `add_skeleton_2d_to_scene` | Add Skeleton2D node to a scene file. | projectPath, scenePath |
| `add_skeleton_3d_to_scene` | Add a Skeleton3D node to a scene file. | projectPath, scenePath |
| `add_skeleton_ik_3d_to_scene` | Add SkeletonIK3D node to a scene file. | projectPath, scenePath |
| `add_soft_body_3d_to_scene` | Add a SoftBody3D node to a scene file. | projectPath, scenePath |
| `add_split_container_to_scene` | Add a SplitContainer node to a scene file. | projectPath, scenePath |
| `add_spot_light_3d_to_scene` | Add a SpotLight3D node to a scene file. | projectPath, scenePath |
| `add_spring_arm_3d_to_scene` | Add a SpringArm3D node to a scene file. | projectPath, scenePath |
| `add_spring_joint_2d_to_scene` | Add a DampedSpringJoint2D node to a scene file. | projectPath, scenePath |
| `add_sprite_3d_to_scene` | Add Sprite3D node (3D billboard sprite) to scene. | projectPath, scenePath |
| `add_static_body_2d_to_scene` | Add a StaticBody2D node to a scene file. | projectPath, scenePath |
| `add_sub_viewport_container_to_scene` | Add a SubViewportContainer to a scene file. | projectPath, scenePath |
| `add_sub_viewport_to_scene` | Add a SubViewport node to a scene file. | projectPath, scenePath |
| `add_tab_bar_to_scene` | Add a TabBar node to a scene file. | projectPath, scenePath |
| `add_tab_container_to_scene` | Add a TabContainer node to a scene file. | projectPath, scenePath |
| `add_text_edit_to_scene` | Add a TextEdit node to a scene file. | projectPath, scenePath |
| `add_texture_button_to_scene` | Add a TextureButton node to a scene file. | projectPath, scenePath |
| `add_texture_progress_bar_to_scene` | Add a TextureProgressBar node to a scene file. | projectPath, scenePath |
| `add_texture_rect_to_scene` | Add a TextureRect node to a scene file. | projectPath, scenePath |
| `add_tile_map_to_scene` | Add a TileMap node to a scene. | projectPath, scenePath |
| `add_timer_to_scene` | Add a Timer node to a scene file. | projectPath, scenePath |
| `add_to_scene_at_runtime` | Add a new typed child node to a parent in game. | nodeType, parentNodePath |
| `add_tree_to_scene` | Add a Tree UI widget node to a scene file. | projectPath, scenePath |
| `add_tween_to_scene` | Add a Node anchor for tweens to a scene file. | projectPath, scenePath |
| `add_v_scroll_bar_to_scene` | Add VScrollBar node to a scene file. | projectPath, scenePath |
| `add_v_separator_to_scene` | Add a VSeparator node to a scene file. | projectPath, scenePath |
| `add_v_slider_to_scene` | Add VSlider node to a scene file. | projectPath, scenePath |
| `add_v_split_container_to_scene` | Add a VSplitContainer to a scene. | projectPath, scenePath |
| `add_vehicle_body_3d_to_scene` | Add a VehicleBody3D node to a scene file. | projectPath, scenePath |
| `add_vehicle_wheel_3d_to_scene` | Add a VehicleWheel3D node to a scene file. | projectPath, scenePath |
| `add_vflow_container_to_scene` | Add a VFlowContainer node to a scene file. | projectPath, scenePath |
| `add_visibility_notifier_2d_to_scene` | Add VisibleOnScreenNotifier2D to scene. | projectPath, scenePath |
| `add_visible_on_screen_notifier_3d_to_scene` | Add VisibleOnScreenNotifier3D to a scene file. | projectPath, scenePath |
| `add_visual_instance_3d_to_scene` | Add a VisualInstance3D to a scene. | projectPath, scenePath |
| `add_visual_shader_node` | Add a node to a VisualShader graph. | nodePath, nodeType, shaderType |
| `add_voxel_gi_to_scene` | Add a VoxelGI node to a scene file. | projectPath, scenePath |
| `add_window_to_scene` | Add Window node (separate OS window) to scene. | projectPath, scenePath |
| `add_world_environment_to_scene` | Add a WorldEnvironment node to a scene file. | projectPath, scenePath |
| `add_xr_camera_3d_to_scene` | Add an XRCamera3D node to a scene file. | projectPath, scenePath |
| `add_xr_controller_3d_to_scene` | Add an XRController3D node to a scene file. | projectPath, scenePath |
| `add_xr_origin_3d_to_scene` | Add an XROrigin3D node to a scene file. | projectPath, scenePath |
| `align_node_to_path` | Move a node to a position along a Path in game. | nodePath, pathNodePath |
| `analyze_scene_complexity` | Return complexity metrics for a scene: node count, depth, scripts, signals. | projectPath, scenePath |
| `animation_tree_get_state` | Get AnimationTree state and blend params in game. | nodePath |
| `animation_tree_set_param` | Set an AnimationTree blend parameter in the game. | nodePath, paramPath |
| `animtree_add_state` | Add a state to an AnimationStateMachine at runtime. | nodePath, stateName, animationName |
| `animtree_add_transition` | Add a transition between two AnimationStateMachine states. | nodePath, fromState, toState |
| `animtree_get_structure` | Get the full AnimationStateMachine state graph structure. | nodePath |
| `animtree_remove_state` | Remove a state from an AnimationStateMachine at runtime. | nodePath, stateName |
| `animtree_remove_transition` | Remove a transition between two AnimationStateMachine states. | nodePath, fromState, toState |
| `apply_node_2d_local_transform` | Apply a local transform to a Node2D. | nodePath, tx, ty |
| `assert_node_state` | Get a property from a node at runtime and compare to expectedValue. | nodePath, property, expectedValue |
| `batch_create_scenes` | Create multiple empty .tscn files in one batch call. | projectPath, scenes |
| `batch_rename_nodes` | Batch rename nodes in a scene via find/replace on names. | projectPath, scenePath, renames |
| `batch_set_node_property_runtime` | Set a property on multiple nodes in the running game. | nodePaths, propertyName |
| `broadcast_to_group` | Call a method on all nodes in a group. | groupName, methodName |
| `call_group_method` | Call a method on all nodes in a group in game. | groupName, methodName |
| `call_method_on_node` | Call a method on a node in the running game. | nodePath, methodName |
| `call_node_method` | Call any method on a node in the running game. | nodePath, methodName |
| `change_scene_to` | Change the active scene in the running game. | scenePath |
| `change_scene_to_file` | Change the running game to a different scene file. | scenePath |
| `check_node_has_children` | Check if a node in a scene has child nodes. | projectPath, scenePath, nodeName |
| `compare_scene_nodes` | Compare nodes between two scene files and show differences. | projectPath, scenePath1, scenePath2 |
| `connect_visual_shader_nodes` | Connect two nodes in a VisualShader graph. | nodePath, shaderType, fromNode, fromPort, toNode, toPort |
| `count_nodes_by_class` | Count nodes of a class in the running scene tree. | className |
| `count_scene_nodes` | Count the number of nodes in a .tscn scene file. | projectPath, scenePath |
| `create_http_request_node` | Add HTTPRequest node child to a parent node. | nodePath |
| `create_node_path` | Compute the NodePath to a node within a scene file. | projectPath, scenePath, nodeName |
| `create_packed_scene_from_script` | Create a PackedScene from a GDScript class. | projectPath, scriptPath, outputPath |
| `create_scene` | Create a new Godot scene file | projectPath, scenePath |
| `cross_scene_set_property` | Like batch_set_property but across ALL .tscn files in project. | projectPath, nodeType, propertyKey, propertyValue |
| `delete_node_from_scene` | Delete a node from a scene file. | projectPath, scenePath, nodeName |
| `delete_scene` | Delete a .tscn scene file. Refuses if it is the project main scene. | projectPath, scenePath |
| `disconnect_visual_shader_nodes` | Disconnect two nodes in a VisualShader graph. | nodePath, shaderType, fromNode, fromPort, toNode, toPort |
| `duplicate_node` | Find a node by path in a .tscn file and insert a copy with a new name. | projectPath, scenePath, nodePath |
| `duplicate_node_in_game` | Duplicate a node at runtime in the running game. | nodePath |
| `duplicate_node_in_scene` | Duplicate a node and add it to the same scene. | projectPath, scenePath, nodeName |
| `duplicate_node_runtime` | Duplicate a node in the running game scene tree. | nodePath |
| `duplicate_scene` | Copy a scene file to a new path. | projectPath, sourcePath, destPath |
| `duplicate_scene_file` | Copy a .tscn file to a new path in the project. | projectPath, sourcePath, destPath |
| `emit_signal_on_node` | Emit a signal on a node in the running game. | nodePath, signalName |
| `fade_in_node` | Fade a node in by tweening alpha from 0 to 1. | nodePath |
| `fade_out_node` | Fade a node out by tweening alpha from 1 to 0. | nodePath |
| `find_nearby_nodes` | Find nodes within a radius of a 2D/3D world position. | position, radius |
| `find_node_by_name` | Find a node by name in the running game scene tree. | searchName |
| `find_node_by_type_in_scene` | Find first node of a given type in scene file. | projectPath, scenePath, nodeType |
| `find_node_references` | Find all files referencing a given node name or path string. | projectPath, nodeName |
| `find_nodes_by_class` | Find all nodes of a class in the running game. | className |
| `find_nodes_by_group` | Find all nodes in a group in the current scene. | groupName |
| `find_nodes_by_property` | Find scene nodes where a property matches a given value. | projectPath, scenePath, propertyName |
| `find_nodes_by_script` | Find all nodes in the running game using a given script. | scriptPath |
| `find_nodes_by_type` | Find all nodes of a given type/class across all .tscn files in the project. | projectPath, nodeType |
| `find_nodes_in_group` | Find all nodes belonging to a group in running game. | groupName |
| `find_nodes_with_property` | Find scene nodes that have a specific property set. | projectPath, propertyName |
| `find_scene_nodes_by_script` | Find all nodes in scenes that use a specific script. | projectPath, scriptPath |
| `find_scenes_using_resource` | Find scenes that reference a given resource path. | projectPath, resourcePath |
| `find_scenes_with_node_type` | Find scenes that contain a specific node type. | projectPath, nodeType |
| `flash_node` | Flash a node by tweening alpha 0→1 quickly (visual feedback). | nodePath |
| `flash_node_color` | Flash a CanvasItem to a color and back. | nodePath |
| `free_node_runtime` | Free (delete) a node from the running game scene. | nodePath |
| `game_animation_tree` | AnimationTree state machine travel and params | nodePath, action |
| `game_change_scene` | Switch to a different scene file in the running game | scenePath |
| `game_find_nodes_by_class` | Find all nodes of a specific class type in the running game | className |
| `game_get_node_info` | Get node info: class, properties, signals, methods, children | nodePath |
| `game_get_nodes_in_group` | Get all nodes belonging to a specific group in the running game | group |
| `game_get_scene_tree` | Get scene tree structure of the running game | None |
| `game_instantiate_scene` | Load a PackedScene and add it as a child of a node in the running game | scenePath |
| `game_manage_group` | Add or remove a node from a group, or list groups | action |
| `game_reload_scene` | Reload the current scene in the running game. | None |
| `game_remove_node` | Remove and free a node from the running game's scene tree | nodePath |
| `game_reparent_node` | Move a node to a new parent in the running game's scene tree | nodePath, newParentPath |
| `game_spawn_node` | Create a new node of any type at runtime | type |
| `game_ui_tree` | Tree control: get/select/collapse/add/remove items | nodePath, action |
| `get_animation_tree_active` | Check if an AnimationTree is active in the game. | nodePath |
| `get_animation_tree_parameter` | Get a parameter from an AnimationTree in game. | nodePath, parameter |
| `get_animation_tree_state` | Get active state of an AnimationTree node. | nodePath |
| `get_button_group` | Get the ButtonGroup resource of a Button. | nodePath |
| `get_children_of_node` | Get immediate children of a node in the game. | nodePath |
| `get_current_scene_name` | Get the name of the currently active scene. | None |
| `get_editor_current_scene_path` | Get the path of the scene open in the editor. | None |
| `get_editor_selected_nodes` | Get the names of nodes selected in the editor. | None |
| `get_groups_all` | List all node groups defined across all scene files. | projectPath |
| `get_node_2d_global_transform` | Get global transform of a Node2D. | nodePath |
| `get_node_2d_position` | Get the global position of a Node2D in the game. | nodePath |
| `get_node_2d_transform` | Get full transform of a Node2D in the running game. | nodePath |
| `get_node_3d_global_position` | Get global world position of a Node3D. | nodePath |
| `get_node_3d_global_rotation` | Get global world rotation (degrees) of Node3D. | nodePath |
| `get_node_3d_global_transform` | Get global Transform3D of a Node3D. | nodePath |
| `get_node_3d_transform` | Get full transform of a Node3D in the running game. | nodePath |
| `get_node_animation_tracks` | Get animation tracks targeting a node in a scene file. | projectPath, scenePath, targetNodeName |
| `get_node_at_position_2d` | Get the topmost node at a 2D screen position in game. | None |
| `get_node_child_count` | Get the number of children a node has in the game. | nodePath |
| `get_node_child_names` | Get the names of all children of a node in the game. | nodePath |
| `get_node_child_paths` | Get paths of all direct children of a node. | nodePath |
| `get_node_class` | Get the class name of a node in the running game. | nodePath |
| `get_node_class_name` | Get the class name of a node in the running game. | nodePath |
| `get_node_connections_count` | Count incoming signal connections on a node. | nodePath |
| `get_node_constant` | Get the value of a class constant from a node in game. | nodePath, constantName |
| `get_node_count_by_type` | Count occurrences of each node type across all scenes. | projectPath |
| `get_node_count_in_scene` | Count total nodes in the current scene. | None |
| `get_node_count_in_scene_file` | Count nodes in a .tscn scene file (headless). | projectPath, scenePath |
| `get_node_count_in_tree` | Get total node count in the running scene tree. | None |
| `get_node_custom_minimum_size` | Get the custom_minimum_size of a Control in game. | nodePath |
| `get_node_groups` | Get the groups assigned to a node in a scene file. | projectPath, scenePath, nodePath |
| `get_node_groups_in_game` | Get all groups a node belongs to in the game. | nodePath |
| `get_node_incoming_connections` | Get all incoming signal connections to a node. | nodePath |
| `get_node_material` | Get material info from a MeshInstance3D or Sprite2D node. | nodePath |
| `get_node_metadata` | Get all metadata entries on a node in the game. | nodePath |
| `get_node_metadata_in_game` | Get all metadata set on a node in the running game. | nodePath |
| `get_node_method_list` | Get all methods available on a node in game. | nodePath |
| `get_node_modulate` | Get the modulate color (RGBA) of a CanvasItem node. | nodePath |
| `get_node_multiplayer_authority` | Get the multiplayer authority of a node. | nodePath |
| `get_node_name` | Get the name of a node in the running game. | nodePath |
| `get_node_owner` | Get the owner of a node in a scene file. | projectPath, scenePath, nodeName |
| `get_node_owner_path` | Get the owner node path of a node in running game. | nodePath |
| `get_node_parent_path` | Get the path of a node's parent node. | nodePath |
| `get_node_path` | Get the full NodePath string of a node. | nodePath |
| `get_node_process_mode` | Get the process_mode of a Node in the running game. | nodePath |
| `get_node_property` | Get any property value from a node in game. | nodePath, property |
| `get_node_property_in_scene` | Get a property value from a node in a scene file. | projectPath, scenePath, nodeName, propertyName |
| `get_node_property_list` | Get all properties with types from a node in game. | nodePath |
| `get_node_property_raw` | Get the raw text value of a property from a .tscn node. | projectPath, scenePath, nodeName, propertyName |
| `get_node_rect` | Get the global Rect2 bounding box of a Control node. | nodePath |
| `get_node_rid` | Get the RID (Resource ID) of a node. | nodePath |
| `get_node_script_path` | Get the script path of a node in a scene file. | projectPath, scenePath, nodeName |
| `get_node_self_modulate` | Get self_modulate color of a CanvasItem node. | nodePath |
| `get_node_signal_connections` | Get all signal connections for a node in a scene file. | projectPath, scenePath, nodeName |
| `get_node_signal_list` | List all signals available on a node. | nodePath |
| `get_node_transform` | Get position, rotation, and scale of a node in a scene. | projectPath, scenePath, nodeName |
| `get_node_unique_name` | Get the unique name (%) of a node in running game. | nodePath |
| `get_node_visibility` | Get the visible state of a node in the running game. | nodePath |
| `get_node_visible` | Get visibility state of a CanvasItem or 3D node. | nodePath |
| `get_node_z_index` | Get the Z-index of a CanvasItem node in the game. | nodePath |
| `get_nodes_in_group` | Get all nodes in a group in the running game. | groupName |
| `get_nodes_in_group_runtime` | Get all nodes in a group in the running game. | groupName |
| `get_nodes_of_class` | Get all nodes of a specific class in running scene. | className |
| `get_nodes_with_script` | Find nodes that have a script attached. | None |
| `get_parent_of_node` | Get the parent node path in the running game. | nodePath |
| `get_range_node_info` | Get value, min, max of a Range-derived node. | nodePath |
| `get_runtime_scene_list` | List all loaded scenes in the running game. | None |
| `get_scene_as_tree` | Parse a scene file and return its node tree as JSON. | projectPath, scenePath |
| `get_scene_by_main_script` | Find scenes whose root node uses a given script. | projectPath, scriptPath |
| `get_scene_change_history` | Get scene change history from the running game. | None |
| `get_scene_current_fps` | Get current FPS from the running scene. | None |
| `get_scene_dependencies` | Parse a .tscn file's [ext_resource lines and return all resource dependencies. | projectPath, scenePath |
| `get_scene_dependency_graph` | Build a dependency graph for every scene in a project. | projectPath |
| `get_scene_embedded_scripts` | Find inline GDScript embedded in .tscn scene files. | projectPath |
| `get_scene_external_resources` | List all ext_resource entries in a scene file. | projectPath, scenePath |
| `get_scene_file_connections` | Parse signal connections from a .tscn file. | projectPath, scenePath |
| `get_scene_file_content` | Return the raw text content of a .tscn file. | projectPath, scenePath |
| `get_scene_inheritance_chain` | Trace the inheritance chain of a scene file. | projectPath, scenePath |
| `get_scene_inheritance_info` | Get the inheritance chain of a scene file. | projectPath, scenePath |
| `get_scene_metadata` | Get the header metadata of a .tscn scene file. | projectPath, scenePath |
| `get_scene_node_count` | Count nodes in all .tscn files in the project. | projectPath |
| `get_scene_node_list` | Parse and list all nodes from a .tscn scene file. | projectPath, scenePath |
| `get_scene_node_path` | Get the full scene path of a named node in a scene. | projectPath, scenePath, nodeName |
| `get_scene_node_types` | List all unique node types used across the project scenes. | projectPath |
| `get_scene_resource_dependencies` | List resources (.tres files) used in a scene. | projectPath, scenePath |
| `get_scene_resource_paths` | Get all ext_resource paths from a .tscn file. | projectPath, scenePath |
| `get_scene_root_node` | Get the root node type and name from a scene file. | projectPath, scenePath |
| `get_scene_root_type` | Get the root node class of a scene file. | projectPath, scenePath |
| `get_scene_script_assignments` | Find which scripts are assigned to scenes. | projectPath |
| `get_scene_size` | Get file size and node/connection counts of a scene. | projectPath, scenePath |
| `get_scene_statistics_all` | Get node/connection counts for all scenes in the project. | projectPath |
| `get_scene_sub_resources` | List all sub_resource entries in a scene file. | projectPath, scenePath |
| `get_scene_subresources` | Get all sub_resource blocks from a .tscn file. | projectPath, scenePath |
| `get_scene_tree_paused` | Check if the SceneTree is paused in the running game. | None |
| `get_scene_tree_snapshot` | Get a snapshot of the full running scene tree. | None |
| `get_scene_unique_nodes` | Get all nodes with unique names (% prefix). | rootPath |
| `get_tree_structure` | Get the full scene tree as nested JSON from the running game. | None |
| `get_ui_scene_setup_guide` | Guide to setting up a UI/HUD scene in Godot. | None |
| `get_visual_shader_node_list` | Get all node IDs in a VisualShader type. | nodePath, shaderType |
| `has_node_metadata` | Check if a node has a metadata key in game. | nodePath, key |
| `hide_node` | Hide a node (visible=false) in the running game. | nodePath |
| `instantiate_scene_at_runtime` | Instantiate a scene at a position in the running game. | scenePath |
| `is_node_in_group` | Check if a node belongs to a specific group. | nodePath, groupName |
| `is_node_inside_tree` | Check if a node path exists in the running game tree. | nodePath |
| `kill_tweens_on_node` | Kill all active tweens on a node in the game. | nodePath |
| `list_all_groups` | List all node groups used across all scenes in the project. | projectPath |
| `list_node_metadata` | List all metadata keys on a node at runtime. | nodePath |
| `list_node_properties_in_scene` | List all properties of a node in a scene file. | projectPath, scenePath, nodeName |
| `list_nodes_without_scripts` | List nodes in scene that have no script attached. | projectPath, scenePath |
| `list_scene_connections` | List all signal connections defined in a scene file. | projectPath, scenePath |
| `list_scene_signals` | List all signals defined in scripts within a scene. | projectPath, scenePath |
| `list_scene_unique_names` | List all nodes with a unique name (%) in a scene. | projectPath, scenePath |
| `list_signals_on_node` | List all signals defined on a node in game. | nodePath |
| `look_at_from_node` | Make a Node3D look at a target position. | nodePath, targetX, targetY, targetZ |
| `manage_scene_signals` | List/add/remove signal connections in .tscn files | projectPath, scenePath, action |
| `manage_scene_structure` | Rename/duplicate/move nodes within .tscn scenes | projectPath, scenePath, action, nodePath |
| `modify_scene_node` | Modify node properties in a scene file (headless) | projectPath, scenePath, nodePath, properties |
| `move_node` | Change a node sibling index in a .tscn file. | projectPath, scenePath, nodePath, newIndex |
| `move_node_child_to_back` | Move a child node to the back of its parent draw order. | nodePath |
| `move_node_child_to_front` | Move a child node to the front of its parent draw order. | nodePath |
| `node_add_to_group_runtime` | Add a node to a group in the running game. | nodePath, groupName |
| `node_get_meta` | Get metadata entries from a node in a scene file. | projectPath, scenePath, nodeName |
| `node_get_meta_runtime` | Get metadata from a node in the running game. | nodePath |
| `node_get_visible_runtime` | Get the visibility of a node in the running game. | nodePath |
| `node_remove_from_group_runtime` | Remove a node from a group in the running game. | nodePath, groupName |
| `node_remove_meta` | Remove a metadata entry from a node in a scene file. | projectPath, scenePath, nodeName, metaKey |
| `node_set_meta` | Set a metadata entry on a node in a scene file. | projectPath, scenePath, nodeName, metaKey, metaValue |
| `node_set_meta_runtime` | Set metadata on a node in the running game. | nodePath, metaKey, metaValue |
| `node_set_modulate` | Set the modulate color of a CanvasItem in the game. | nodePath |
| `node_set_visible_runtime` | Toggle a node visible/hidden in the running game. | nodePath, visible |
| `node_set_z_index` | Set the z_index of a Node2D in the running game. | nodePath, zIndex |
| `open_scene` | Launch the Godot editor with a specific scene open. | projectPath, scenePath |
| `read_scene` | Read scene file as JSON node tree (headless) | projectPath, scenePath |
| `read_scene_file_raw` | Read raw text content of a .tscn scene file. | projectPath, scenePath |
| `reload_current_scene` | Reload the current scene in the running game. | None |
| `remove_node_from_game` | Remove and free a node from the running game. | nodePath |
| `remove_node_from_group` | Remove a node from a group in a scene file. | projectPath, scenePath, nodeName, groupName |
| `remove_node_from_group_in_game` | Remove a node from a group in the running game. | nodePath, groupName |
| `remove_node_from_group_runtime` | Remove a node from a group in running game. | nodePath, groupName |
| `remove_node_in_game` | Queue free (remove) a node in the running game. | nodePath |
| `remove_node_metadata` | Remove a metadata key from a node at runtime. | nodePath, metaKey |
| `remove_scene_node` | Remove a node from a scene file (headless) | projectPath, scenePath, nodePath |
| `remove_visual_shader_node` | Remove a node from a VisualShader graph. | nodePath, shaderType, nodeId |
| `rename_node` | Rename a node in a scene file, updating child path refs. | projectPath, scenePath, oldName, newName |
| `rename_node_in_scene` | Rename a node inside a scene file. | projectPath, scenePath, nodeName, newName |
| `rename_node_runtime` | Rename a node at runtime by its current path. | nodePath, newName |
| `reorder_node` | Move a node up or down among its siblings in a scene. | projectPath, scenePath, nodeName, direction |
| `reparent_node_in_game` | Move a node to a new parent in the running game. | nodePath, newParentPath |
| `reparent_node_in_scene` | Move a node to a new parent in a scene file. | projectPath, scenePath, nodeName, newParentPath |
| `reset_node_3d_transform` | Reset position/rotation/scale of a Node3D to default. | nodePath |
| `rotate_node_2d` | Rotate a Node2D by an angle (radians) in the game. | nodePath |
| `rotate_node_3d` | Set Euler rotation on a Node3D in the running game. | nodePath |
| `rotate_node_x` | Rotate a Node3D by degrees around local X axis. | nodePath |
| `rotate_node_y` | Rotate a Node3D by degrees around local Y axis. | nodePath |
| `rotate_node_z` | Rotate a Node3D by degrees around local Z axis. | nodePath |
| `save_scene` | Save changes to a scene file | projectPath, scenePath |
| `save_scene_at_runtime` | Save the current running scene to a .tscn file. | outputPath |
| `scale_node_2d` | Set the scale on a Node2D in the running game. | nodePath |
| `scale_node_3d` | Set the scale on a Node3D in the running game. | nodePath |
| `scene_batch_rename_nodes` | Rename all nodes matching a prefix in a scene file. | projectPath, scenePath, oldPrefix, newPrefix |
| `scene_create_inherited` | Create an inherited .tscn scene that extends a base scene. | projectPath, baseScenePath, newScenePath |
| `scene_list_resources` | List all external resource references in a scene file. | projectPath, scenePath |
| `scene_list_sub_resources` | List all inline sub-resources defined in a scene file. | projectPath, scenePath |
| `scene_node_count` | Count the number of nodes in a scene file. | projectPath, scenePath |
| `scene_profiler_start` | Start scene processing profiler in the running game. | None |
| `scene_profiler_stop` | Stop profiler and return processing time results. | None |
| `scene_replace_node_type` | Replace all nodes of one type with another in a scene. | projectPath, scenePath, fromType, toType |
| `scene_set_node_property_batch` | Set a property on all nodes of a type in a scene. | projectPath, scenePath, nodeType, propertyName, propertyValue |
| `scene_set_root_type` | Change the root node type in a scene file header. | projectPath, scenePath, newType |
| `scene_set_unique_name` | Toggle the unique_name_in_owner flag on a node in a .tscn file. | projectPath, scenePath, nodePath, enabled |
| `scene_toggle_node_visible` | Toggle the visible property of a node in a scene. | projectPath, scenePath, nodeName, visible |
| `set_all_nodes_in_group_visible` | Show/hide all nodes in a group. | groupName |
| `set_animation_tree_active` | Set the active state of an AnimationTree in game. | nodePath |
| `set_animation_tree_parameter` | Set a parameter on an AnimationTree in game. | nodePath, parameter |
| `set_button_group` | Set a ButtonGroup on a Button node. | nodePath, groupPath |
| `set_group_process` | Enable/disable processing for all nodes in group. | groupName |
| `set_group_property` | Set a property on all nodes in a group. | groupName, propertyName, value |
| `set_joint_3d_node_paths` | Set NodeA/NodeB paths on a Joint3D node. | nodePath, nodeA, nodeB |
| `set_main_scene` | Set the main scene in project.godot | projectPath, scenePath |
| `set_node_2d_position` | Set the global position of a Node2D in the game. | nodePath |
| `set_node_custom_minimum_size` | Set the custom_minimum_size of a Control in game. | nodePath |
| `set_node_groups` | Set the groups for a node in a scene file. | projectPath, scenePath, nodePath, groups |
| `set_node_metadata` | Set a metadata entry on a node in the running game. | nodePath, key |
| `set_node_metadata_in_game` | Set a metadata key on a node in the running game. | nodePath, key |
| `set_node_modulate` | Set the modulate color (RGBA) of a CanvasItem node. | nodePath |
| `set_node_multiplayer_authority` | Set the multiplayer authority of a node. | nodePath |
| `set_node_name` | Rename a node in the running game scene tree. | nodePath, newName |
| `set_node_owner` | Set the owner of a node (for scene saving). | nodePath, ownerPath |
| `set_node_position_in_scene` | Set position of a 2D/3D node in a scene file. | projectPath, scenePath, nodeName |
| `set_node_process` | Set process or physics_process on a node in game. | nodePath |
| `set_node_process_mode` | Set process_mode of a Node (inherit/always/pausable/etc). | nodePath, mode |
| `set_node_property` | Set any property on a scene node in the .tscn file. | projectPath, scenePath, nodeName, propertyName, propertyValue |
| `set_node_property_in_scene` | Set a property on a node in a scene file. | projectPath, scenePath, nodeName, propertyName, propertyValue |
| `set_node_rotation_in_scene` | Set rotation of a node in a scene file (degrees). | projectPath, scenePath, nodeName |
| `set_node_scale_in_scene` | Set scale of a node in a scene file. | projectPath, scenePath, nodeName |
| `set_node_self_modulate` | Set self_modulate color of a CanvasItem node. | nodePath |
| `set_node_transform` | Set position, rotation, or scale of a node in a scene. | projectPath, scenePath, nodeName |
| `set_node_unique_name` | Set or clear unique_name_in_owner on a scene node. | projectPath, scenePath, nodeName |
| `set_node_visible` | Set visibility of a CanvasItem or 3D node. | nodePath |
| `set_node_z_index` | Set the z_index of a Node2D in the running game. | nodePath, zIndex |
| `set_range_node_min_max` | Set min/max bounds of a Range node. | nodePath, min, max |
| `set_range_node_value` | Set current value of a Range node. | nodePath, value |
| `set_visual_shader_node_position` | Set position of a node in VisualShader graph. | nodePath, shaderType, nodeId, posX, posY |
| `shake_node` | Shake a node's position by tweening it rapidly. | nodePath |
| `show_node` | Show a node (visible=true) in the running game. | nodePath |
| `toggle_node_visibility` | Toggle visibility on a node in the running game. | nodePath |
| `translate_node_global` | Translate a Node3D along global world axes. | nodePath |
| `translate_node_local` | Translate a Node3D along its local axes. | nodePath |
| `tween_node_alpha` | Tween a CanvasItem modulate alpha to target. | nodePath |
| `tween_node_position_2d` | Tween a Node2D to a target 2D position. | nodePath |
| `tween_node_rotation` | Tween a node's rotation to a target (degrees). | nodePath |
| `tween_node_scale` | Tween a Node2D scale to a target value. | nodePath |
| `validate_scene_file` | Validate a .tscn scene file for structural integrity. | projectPath, scenePath |
| `validate_scene_physics` | Check if physics bodies in scene have collision shapes. | projectPath, scenePath |
| `wait_for_node` | Wait until a node path exists in the scene tree. | nodePath |
| `write_cutscene_player_script` | Write a cutscene/cinematic player script. | projectPath, scriptPath |
| `write_cutscene_trigger_script` | Write a trigger zone for cutscene activation. | projectPath, scriptPath |
| `write_scene_manager_script` | Write a named scene manager singleton. | projectPath, scriptPath |
| `write_scene_transition_script` | Write a scene transition manager script. | projectPath, scriptPath |
| `write_skill_tree_script` | Write a skill tree with unlock conditions. | projectPath, scriptPath |

## UI

| Tool | Description | Required arguments |
|---|---|---|
| `add_aspect_ratio_container` | Add an AspectRatioContainer node to a scene. | projectPath, scenePath |
| `add_flow_container` | Add an HFlowContainer or VFlowContainer to a scene. | projectPath, scenePath |
| `add_grid_container` | Add a GridContainer node to a scene file. | projectPath, scenePath |
| `add_label_3d` | Add a Label3D node to a scene file. | projectPath, scenePath |
| `add_option_button_item` | Add an item to an OptionButton in the game. | nodePath, label |
| `add_popup_menu_item` | Add an item to a PopupMenu in the running game. | nodePath, label |
| `add_scroll_container` | Add a ScrollContainer node to a scene file. | projectPath, scenePath |
| `add_split_container` | Add an HSplitContainer or VSplitContainer to a scene. | projectPath, scenePath |
| `add_tab_container` | Add a TabContainer node to a scene file. | projectPath, scenePath |
| `add_touch_screen_button` | Add a TouchScreenButton node to a scene file. | projectPath, scenePath |
| `append_rich_text_label_bbcode` | Append BBCode text to a RichTextLabel. | nodePath, bbcode |
| `clear_popup_menu` | Clear all items from a PopupMenu in the game. | nodePath |
| `clear_rich_text_label` | Clear all text from a RichTextLabel. | nodePath |
| `click_button` | Simulate a click on a Button node in the game. | nodePath |
| `click_button_by_text` | Find and click a Button node by its text label. | text |
| `control_set_size` | Set a Control node size and size flags in the running game. | nodePath |
| `game_get_ui` | Get visible UI elements from the running game | None |
| `game_quit` | Gracefully quit the running game. | None |
| `game_ui_control` | Set focus, anchors, tooltip, mouse filter on Control | nodePath, action |
| `game_ui_item_list` | ItemList/OptionButton: get/select/add/remove items | nodePath, action |
| `game_ui_menu` | PopupMenu/MenuBar: add/remove/get menu items | nodePath, action |
| `game_ui_popup` | Show/hide/popup for Popup/Dialog/Window nodes | nodePath, action |
| `game_ui_range` | ProgressBar/Slider/SpinBox/ColorPicker get/set | nodePath, action |
| `game_ui_tabs` | TabContainer/TabBar: get/set current tab | nodePath, action |
| `game_ui_text` | LineEdit/TextEdit/RichTextLabel text operations | nodePath, action |
| `game_ui_theme` | Apply theme overrides to a Control node | nodePath, overrides |
| `generate_uuid_v4` | Generate a random UUID v4 string in Godot. | None |
| `get_button_text` | Get the text of a Button node in the game. | nodePath |
| `get_check_button_state` | Get pressed state of a CheckButton/CheckBox. | nodePath |
| `get_container_children_info` | Get child sizes in a Container node. | nodePath |
| `get_control_anchor` | Get anchor values of a Control node (left/top/right/bottom). | nodePath |
| `get_control_focus` | Check if a Control node has focus. | nodePath |
| `get_control_focus_owner` | Get the currently focused Control in viewport. | nodePath |
| `get_control_position` | Get the position of a Control node in its parent. | nodePath |
| `get_control_rect` | Get position and size of a Control node. | nodePath |
| `get_control_size` | Get the current size of a Control node in game. | nodePath |
| `get_control_theme_type` | Get the theme_type_variation of a Control node. | nodePath |
| `get_editor_theme_color` | Get a theme color from a Control node in game. | nodePath, colorName |
| `get_fps_3d_setup_guide` | Step-by-step guide to set up a 3D FPS game. | None |
| `get_grid_container_columns` | Get column count of a GridContainer. | nodePath |
| `get_label_3d_info` | Get Label3D text, font size, and billboard mode. | nodePath |
| `get_label_font_size` | Get the font size of a Label in the running game. | nodePath |
| `get_label_text` | Get the text of a Label or RichTextLabel in game. | nodePath |
| `get_mouse_button_state` | Get bitmask of pressed mouse buttons. | None |
| `get_option_button_selected` | Get the selected item from an OptionButton in game. | nodePath |
| `get_panel_stylebox` | Get the stylebox name override on a Panel in game. | nodePath |
| `get_platformer_2d_setup_guide` | Step-by-step guide to set up a 2D platformer. | None |
| `get_popup_menu_item_count` | Get the item count of a PopupMenu. | nodePath |
| `get_rich_text_label_info` | Get RichTextLabel text, bbcode, and scroll. | nodePath |
| `get_rich_text_label_line_count` | Get total line count of a RichTextLabel. | nodePath |
| `get_rich_text_label_text` | Get text content of a RichTextLabel node. | nodePath |
| `get_scroll_container_scroll` | Get scroll position of a ScrollContainer. | nodePath |
| `get_split_container_offset` | Get split offset of a HSplitContainer. | nodePath |
| `get_tab_container_current_tab` | Get current tab index of a TabContainer. | nodePath |
| `get_tab_container_tab` | Get the current tab of a TabContainer in game. | nodePath |
| `get_theme_info` | Get default font, size, color from a Control theme. | nodePath |
| `get_top_down_2d_setup_guide` | Step-by-step guide for a top-down 2D game. | None |
| `get_ui_theme_defaults` | Read default theme font/size from project settings. | projectPath |
| `get_uid` | Get the UID for a specific file in a Godot project (for Godot 4.4+) | projectPath, filePath |
| `get_xr_controller_input` | Get XR controller axis and button input. | controllerId |
| `is_button_pressed` | Get the pressed state of a Button in the game. | nodePath |
| `label_set_text` | Set the text of a Label or RichTextLabel in the game. | nodePath, text |
| `option_button_add_item` | Add an item to an OptionButton in the running game. | nodePath, label |
| `popup_menu_add_item` | Add an item to a PopupMenu in the running game. | nodePath, label |
| `quit_game` | Quit the running Godot game instance. | None |
| `scroll_rich_text_label_to_line` | Scroll a RichTextLabel to a specific line. | nodePath, line |
| `set_button_disabled` | Enable or disable a Button node. | nodePath |
| `set_button_pressed` | Set the pressed state of a Button in the game. | nodePath |
| `set_button_text` | Set the text on a Button node in the game. | nodePath |
| `set_check_button_state` | Set pressed state of a CheckButton/CheckBox. | nodePath |
| `set_control_anchor` | Set anchor preset of a Control node. | nodePath |
| `set_control_anchor_preset` | Set anchor preset on a Control (e.g. full_rect, center). | nodePath |
| `set_control_focus` | Give keyboard focus to a Control node. | nodePath |
| `set_control_focus_mode` | Set focus mode on a Control node. | nodePath |
| `set_control_focus_owner` | Give keyboard focus to a Control node. | nodePath |
| `set_control_offset` | Set offset (position) on a Control node. | nodePath |
| `set_control_position` | Set the position of a Control node in game. | nodePath |
| `set_control_size` | Set the size of a Control node in the game. | nodePath |
| `set_control_theme_type` | Set theme_type_variation override on a Control. | nodePath, themeType |
| `set_grid_container_columns` | Set column count of a GridContainer. | nodePath, columns |
| `set_h_box_container_separation` | Set HBoxContainer/VBoxContainer separation. | nodePath, separation |
| `set_label_3d_billboard` | Set Label3D billboard mode (0=disabled, 1=enabled). | nodePath, billboardMode |
| `set_label_3d_font_size` | Set the font size of a Label3D node. | nodePath, fontSize |
| `set_label_3d_text` | Set the text content of a Label3D node. | nodePath, text |
| `set_label_color` | Set the font color of a Label in the game. | nodePath |
| `set_label_font_size` | Set the font size of a Label in the running game. | nodePath |
| `set_label_horizontal_alignment` | Set horizontal alignment on a Label in the game. | nodePath |
| `set_label_text` | Set the text on a Label or RichTextLabel in game. | nodePath |
| `set_option_button_selected` | Set the selected index on an OptionButton in game. | nodePath |
| `set_panel_border_color` | Set Panel border color via StyleBoxFlat theme override. | nodePath |
| `set_panel_stylebox_color` | Set Panel background color via StyleBoxFlat override. | nodePath |
| `set_rich_text_label_bbcode` | Set BBCode text on a RichTextLabel in the game. | nodePath, text |
| `set_rich_text_label_text` | Set BBCode text on a RichTextLabel node. | nodePath |
| `set_scroll_container_scroll` | Set scroll position of a ScrollContainer. | nodePath, scrollH, scrollV |
| `set_split_container_offset` | Set split offset of a split container. | nodePath, offset |
| `set_tab_container_current` | Set the current tab on a TabContainer in game. | nodePath |
| `set_tab_container_current_tab` | Set current tab of a TabContainer by index. | nodePath, tabIndex |
| `set_tab_container_tab` | Set the current tab on a TabContainer in game. | nodePath |
| `set_theme_color` | Set a theme color override on a Control node. | nodePath, colorName |
| `set_theme_font_size` | Set default font size in a Control's theme override. | nodePath |
| `show_popup_menu` | Show a PopupMenu at a position in the game. | nodePath |
| `theme_set_color_override` | Set a theme color override on a Control in the game. | nodePath, colorName |
