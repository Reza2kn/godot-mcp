# 🎮 Godot MCP — 1,969 Tools. Full Editor Parity. AI-Native Game Dev.

[![MCP Server](https://badge.mcpx.dev?type=server)](https://modelcontextprotocol.io/introduction)
[![Made with Godot](https://img.shields.io/badge/Made%20with-Godot-478CBF?style=flat&logo=godot%20engine&logoColor=white)](https://godotengine.org)
[![TypeScript](https://img.shields.io/badge/TypeScript-3178C6?style=flat&logo=typescript&logoColor=white)](https://www.typescriptlang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-red.svg)](https://opensource.org/licenses/MIT)
[![Tools: 1969](https://img.shields.io/badge/Tools-1%2C969-brightgreen)](https://github.com/Reza2kn/godot-mcp)
[![npm](https://img.shields.io/npm/v/godot-mcp-1969)](https://www.npmjs.com/package/godot-mcp-1969)
[![CI](https://github.com/Reza2kn/godot-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/Reza2kn/godot-mcp/actions/workflows/ci.yml)

> **Anything you can do in the Godot editor, an AI can now do via MCP.**
>
> 1,969 real tools. Progressive discovery so even tiny models don't get lost. Full parity with the Godot 4 UI.

---

## 🚀 What Is This?

This is a [Model Context Protocol](https://modelcontextprotocol.io/) (MCP) server that gives AI assistants **complete control** over the Godot 4 game engine — matching every capability of the Godot editor UI.

Whether you're using **Claude**, **GPT-4o**, **Gemini**, or a **local model running on Ollama**, this server lets your AI:

- 🏗️ **Create** projects, scenes, nodes, and scripts from scratch
- 🎮 **Control** a running game in real-time (move nodes, spawn enemies, play audio, fire particles)
- ✏️ **Edit** the Godot editor itself live (select nodes, undo/redo, save scenes)
- 🧠 **Generate** complete game systems (inventory, AI, combat, save/load, UI, dialogue...)
- 🔍 **Inspect** any node, resource, signal, or property at runtime
- 🧭 **Navigate** 1,969 tools progressively — even tiny models won't get overwhelmed

---

## ✨ Why This Exists

The original [godot-mcp by Tugcan Topaloglu](https://github.com/tugcantopaloglu/godot-mcp) was an amazing foundation. It proved AI-controlled Godot was possible at scale. But it had ~150 tools.

We built this from the ground up with **1,969 tools** — one for every meaningful thing you can do in the Godot editor. Not inflated. Not duplicated. All real, all useful.

And we added something the MCP ecosystem is still figuring out: **progressive tool discovery** — so even the weakest local model can navigate 1,969 tools without hallucinating names or burning context.

---

## 🗂️ What's Covered (1,969 Tools Across Everything)

| Category | What's Inside |
|----------|---------------|
| 🧭 **Navigation** | `godot_start_here`, `godot_suggest`, `search_tools`, `get_workflow`, category browsing |
| 📁 **Project** | Create, open, run, stop, export, configure Godot projects |
| 🎬 **Scene Editing** | Create/edit .tscn files, add/delete/rename/move/reparent nodes, set properties |
| 2️⃣ **2D Nodes** | Every 2D node: Sprite2D, CharacterBody2D, TileMap, Area2D, lights, joints, shapes... |
| 3️⃣ **3D Nodes** | MeshInstance3D, Camera3D, Lights, CSG, VehicleBody3D, Skeleton3D, GridMap... |
| 🖼️ **UI / Control** | Button, Label, Container, ProgressBar, RichTextLabel, PopupMenu, TabContainer... |
| 🎮 **Runtime Control** | Move/rotate/scale nodes, set properties, spawn scenes — while the game runs |
| ⚡ **Physics** | Forces, impulses, joints 2D/3D, raycast, spherecast, SoftBody3D, VehicleBody3D |
| 🔊 **Audio** | Play/stop/pause, bus management, 3D spatial audio, audio effects, pooling |
| 📷 **Camera** | Camera2D/3D, FOV, zoom, SpringArm3D, SubViewport, XR camera |
| 📝 **Scripts & Signals** | Read/write GDScript, connect/emit signals, inspect methods and class hierarchy |
| 🧪 **GDScript Templates** | 100+ ready-to-use scripts: platformer, FPS, AI enemy, dialogue, inventory... |
| 🎭 **Animation** | AnimationPlayer, AnimationTree, state machine, blend times, track editing |
| 🌍 **Rendering** | WorldEnvironment, fog, glow, tone mapping, sky, VisualShader node graph |
| 🧩 **Resources** | TileSet, SpriteFrames, Materials, Fonts, Gradients, AnimationLibrary |
| 🗺️ **Navigation Mesh** | NavigationAgent2D/3D, NavigationRegion, pathfinding, mesh baking |
| 🕶️ **XR / VR / AR** | XRInterface, XRController, XRAnchor, world scale, tracking state |
| 🔧 **Editor Plugin** | Live editor: select nodes, undo/redo, save scene, inspect, reimport assets |
| 💾 **File I/O** | Read/write files, list directories, JSON, CSV, binary, zip archives |
| ⏰ **Time & Crypto** | Unix time, SHA256, MD5, UUID, base64, datetime conversion |
| 🌐 **Networking** | ENet, WebSocket, HTTP, multiplayer peer setup |
| 🔍 **Diagnostics** | Validate scenes, find missing scripts, check collisions, project analysis |

---

## 🧭 Progressive Discovery — The Key Innovation

> 💡 **The problem:** Dumping 1,969 tool schemas at a model on startup destroys its context and performance. Even the best models hallucinate or get confused. This is the #1 unsolved problem with large MCP servers.

> ✅ **Our solution:** Two modes. The model only ever sees what it can handle.

### 🔍 Discovery Mode — for local models, demos, noob-friendly AI

```bash
GODOT_MCP_DISCOVERY_MODE=true
```

Model sees **20 tools** at startup instead of 1,969:

| Tool | What It Does |
|------|-------------|
| `godot_start_here` | Explains the whole system in one call — always call this first |
| `godot_suggest` | `task="make a character jump"` → returns 3-5 perfect tool names |
| `godot_call` | **Universal dispatcher** — calls any of the 1,969 tools by name |
| `search_tools` | Keyword search across all tool names |
| `list_tool_categories` | Shows all categories with counts |
| `list_tools_in_category` | Shows all tools in one category |
| `get_beginner_guide` | Step-by-step Godot MCP walkthrough |
| `get_workflow` | Structured workflow for platformer, FPS, audio, UI, etc. |
| `explain_godot_concept` | "What is a CharacterBody2D?" → real explanation |
| + 11 core tools | `create_project`, `run_project`, `create_scene`, `create_script`, etc. |

**A typical discovery session:**
```
Model calls: godot_start_here
→ "Call godot_suggest to find the right tool for your task"

Model calls: godot_suggest task="make an enemy that chases the player"
→ [write_enemy_state_machine_script, write_waypoint_patrol_script, write_pathfinding_agent_2d_script]

Model calls: godot_call name="write_enemy_state_machine_script" args={projectPath: "...", scriptPath: "..."}
→ ✅ Full AI enemy script with idle/patrol/chase/attack states written to disk
```

No hallucinations. No context overflow. Works on 7B models.

### 🔥 Full Mode — for large models and power users

```bash
# Default. No env var needed.
```

All 1,969 tools exposed directly. Claude, GPT-4o, Gemini — use this.

---

## 🛠️ How It Works — Three Execution Paths

```
┌────────────────────────────────────────────────────────────┐
│                AI Model (Claude / GPT / Ollama)             │
└───────────────────────────┬────────────────────────────────┘
                            │ MCP protocol (stdio)
┌───────────────────────────▼────────────────────────────────┐
│              Godot MCP Server (Node.js / TypeScript)        │
└─────┬──────────────────────┬──────────────────┬────────────┘
      │                      │                  │
      ▼                      ▼                  ▼
 🖥️ Headless Godot      🎮 TCP :9090        ✏️ TCP :9091
  File/resource ops    Live game control   Live editor control
  No game needed       Requires run_project  Requires plugin
```

| Path | Tools | Requires |
|------|-------|---------|
| **Headless** | Scene editing, resources, scripts, exports | Just Godot installed |
| **Runtime :9090** | Move nodes, spawn, physics, audio, camera | `run_project` first |
| **Editor :9091** | Select nodes, undo/redo, save, inspect | Editor plugin installed |

---

## 📦 Installation

### 1️⃣ Prerequisites

- **Godot 4.x** — [godotengine.org/download](https://godotengine.org/download)
- **Node.js 18+** — [nodejs.org](https://nodejs.org/)
- An MCP client (Claude Desktop, VS Code + Continue, Cursor, open-webui...)

### 2️⃣ Install

**From npm:** [godot-mcp-1969 on npm](https://www.npmjs.com/package/godot-mcp-1969)
```bash
npm install -g godot-mcp-1969
```

**From source:**
```bash
git clone https://github.com/Reza2kn/godot-mcp.git
cd godot-mcp
npm install
npm run build
```

### 3️⃣ Configure Your Client

#### 🤖 Claude Desktop

`~/Library/Application Support/Claude/claude_desktop_config.json` (macOS)
`%APPDATA%\Claude\claude_desktop_config.json` (Windows)

```json
{
  "mcpServers": {
    "godot": {
      "command": "node",
      "args": ["/absolute/path/to/godot-mcp/build/index.js"],
      "env": {
        "GODOT_PATH": "/Applications/Godot.app/Contents/MacOS/Godot"
      }
    }
  }
}
```

#### 🎛️ Conductor / Codex

Build the repository, then register the server globally with Codex. Conductor
uses the same Codex MCP configuration:

```bash
codex mcp add godot \
  --env GODOT_PATH=/Applications/Godot.app/Contents/MacOS/Godot \
  --env GODOT_MCP_DISCOVERY_MODE=true \
  -- node /absolute/path/to/godot-mcp/build/index.js
codex mcp get godot
```

Start a new Conductor/Codex session after registration so it discovers the new
server. Discovery mode is recommended: the client sees 20 tools, while all
1,969 remain callable through `godot_call`.

For local models / demos — add discovery mode:
```json
"env": {
  "GODOT_PATH": "/Applications/Godot.app/Contents/MacOS/Godot",
  "GODOT_MCP_DISCOVERY_MODE": "true"
}
```

#### 🖱️ VS Code (Continue extension)

`.continue/config.json`:
```json
{
  "mcpServers": [
    {
      "name": "godot",
      "command": "node",
      "args": ["/absolute/path/to/godot-mcp/build/index.js"],
      "env": {
        "GODOT_PATH": "/Applications/Godot.app/Contents/MacOS/Godot"
      }
    }
  ]
}
```

#### 🦙 Ollama / LM Studio / Any Local Model

```bash
GODOT_PATH=/Applications/Godot.app/Contents/MacOS/Godot \
GODOT_MCP_DISCOVERY_MODE=true \
node /path/to/godot-mcp/build/index.js
```

### 4️⃣ Find Your Godot Executable

| Platform | Default Path |
|----------|-------------|
| 🍎 macOS | `/Applications/Godot.app/Contents/MacOS/Godot` |
| 🪟 Windows | `C:\Program Files\Godot\Godot_v4.x-stable_win64.exe` |
| 🐧 Linux | `/usr/local/bin/godot` or `~/godot/godot` |

---

## 🎮 Quick Start — Your First AI-Made Game

### 🌱 Zero to running game in ~2 minutes

Tell your AI: *"Create a 2D platformer project at ~/Games/MyPlatformer with a player, a ground, and a camera"*

The AI will call these tools in sequence:
```
create_project          → ~/Games/MyPlatformer
create_scene            → Player.tscn (CharacterBody2D)
add_collision_shape_2d_to_scene  → CapsuleShape2D (REQUIRED for physics!)
add_animated_sprite_2d_to_scene  → AnimatedSprite2D visuals
write_platformer_player_script   → res://scripts/player.gd
attach_script_to_node_in_scene   → attach player.gd to root
create_scene            → Level.tscn (Node2D)
add_static_body_2d_to_scene      → ground platform
add_collision_shape_2d_to_scene  → BoxShape2D floor
instance_scene          → Player.tscn into Level.tscn
add_camera_2d_to_scene           → smooth follow camera
run_project             → 🎮 Game is running!
```

### ⚡ Runtime control while playing

```
"Move the player to the center of the screen"
→ set_node_position_2d  nodePath="Player"  x=540  y=300

"Spawn 5 enemies at random positions"
→ spawn_node  × 5

"Play the explosion sound and shake the camera"
→ play_audio_stream + write_camera_shake_3d_script
```

### 🧠 Generate a complete game system

```
"Add inventory, save/load, and a quest system to my game"
→ write_inventory_system_script   → res://scripts/inventory.gd
→ write_save_load_system_script   → res://scripts/save_manager.gd
→ write_quest_manager_script      → res://scripts/quest_manager.gd
→ set_project_autoload (×3)       → registered as singletons
```

---

## 🧪 GDScript Templates — 100+ Scripts, One Command Each

```bash
# Gameplay systems
write_platformer_player_script       # Full gravity + jump + run
write_top_down_shooter_script        # 8-dir movement + shooting
write_enemy_state_machine_script     # idle/patrol/chase/attack AI
write_vehicle_controller_script      # VehicleBody3D car physics
write_double_jump_script             # Double-jump with coyote time
write_wall_jump_script               # Wall-jump CharacterBody2D
write_grappling_hook_script          # Physics grapple mechanic
write_dash_ability_script            # Dodge with cooldown

# Systems & managers
write_save_load_system_script        # JSON save/load
write_inventory_system_script        # Stacking inventory + signals
write_quest_manager_script           # Progress tracking
write_dialogue_system_script         # Branching dialogue + choices
write_audio_manager_script           # Singleton pooled audio
write_achievement_system_script      # Achievement unlocking
write_state_machine_base_script      # Generic reusable state machine
write_signal_bus_script              # Global event bus autoload

# UI components
write_health_component_script        # Reusable health node
write_pause_menu_script              # Pause + resume + quit
write_status_bar_ui_script           # Generic health/XP bar
write_hotbar_ui_script               # Hotbar item slots
write_minimap_ui_script              # Viewport-based minimap
write_tooltip_system_script          # Hover tooltips
write_drag_drop_slot_script          # Drag-and-drop item slots
write_fps_counter_script             # FPS overlay label

# World & environment
write_day_night_cycle_script         # Time cycle with signals
write_weather_system_script          # Weather state machine
write_procedural_dungeon_script      # Procedural room generation
write_chunk_loading_script           # Chunk-based world loading
write_fog_of_war_script              # Vision masking

# Physics & interaction
write_explosion_script               # Radius damage area
write_water_buoyancy_script          # Buoyancy force area
write_conveyor_belt_script           # Moving surface velocity
write_ladder_script                  # Climbable ladder
write_zipline_script                 # Zipline mover
write_pressure_plate_script          # Trigger plate
write_door_script                    # Animated open/close door
write_ragdoll_setup_script           # Ragdoll physics helper

# ... and 60+ more
```

---

## 🖥️ Editor Plugin (Optional but 🔥)

For **live Godot editor control** — select nodes, undo/redo operations, save scenes — install the editor plugin:

```
Ask your AI: "Install the Godot editor plugin for my project"
AI calls: install_editor_plugin projectPath="/path/to/your/project"
```

Then in Godot Editor: **Project → Project Settings → Plugins → Enable "Godot MCP Editor"**

You'll see an **Agent Control dock** appear. Now the AI can:

| Tool | Effect in Editor |
|------|-----------------|
| `editor_select_node_by_path` | Highlights a node in the scene tree |
| `get_editor_selected_nodes` | Reads whatever you currently have selected |
| `editor_undo` / `editor_redo` | Undo/redo in the editor |
| `editor_save_scene` | Saves the current scene |
| `get_editor_filesystem_files` | Lists files in any project folder |
| `get_editor_inspector_object` | Reads the object in the Inspector panel |

---

## 🤖 For Local Model Users (Ollama, LM Studio, Jan)

**Always use discovery mode with local/small models.** Models under 30B parameters struggle with 1,969 tool schemas.

```bash
GODOT_MCP_DISCOVERY_MODE=true node build/index.js
```

Then prompt your model to start with:
> *"Call godot_start_here first to understand how to use this MCP server"*

The model will understand the system in one call and navigate everything through `godot_suggest` + `godot_call`. No context overflow. No hallucinated tool names.

### 🧪 Tested local models (in discovery mode):

| Model | Quality | Notes |
|-------|---------|-------|
| **Qwen2.5-Coder 14B+** | ⭐⭐⭐⭐⭐ | Best local option for game dev |
| **DeepSeek-Coder-V2 16B** | ⭐⭐⭐⭐⭐ | Excellent multi-step reasoning |
| **Llama 3.3 70B** | ⭐⭐⭐⭐ | Solid, needs good prompting |
| **Mistral 22B** | ⭐⭐⭐ | Works for simple tasks |
| **Llama 3.1 8B** | ⭐⭐ | Use discovery mode, keep prompts tight |

---

## 🎬 For YouTubers & Content Creators

Hey! If you made a video on the original godot-mcp — **this is the full-power sequel.** Here's your content roadmap:

### 🔥 High-impact demo ideas

**"AI builds a complete platformer from zero"** ⏱️ ~5 min clip
```
Start: empty folder
End: running game with player, ground, camera, physics
Tools used: ~12 in sequence
```

**"1,969 things an AI can do in Godot"** ⏱️ ~3 min clip
```
Call list_tool_categories → show the scope
Pick one category, browse it, demo a tool live
```

**"Local model plays Godot with only 20 tools"** ⏱️ ~8 min clip
```
GODOT_MCP_DISCOVERY_MODE=true + Ollama
Show progressive discovery in action
Tiny model, huge capability
```

**"AI generates a complete RPG system"** ⏱️ ~10 min clip
```
write_inventory_system_script
write_quest_manager_script
write_dialogue_system_script
write_save_load_system_script
→ 4 complete systems in 30 seconds
```

**"AI controls the running game in real-time"** ⏱️ ~5 min clip
```
run_project → game is live
set_node_position_2d → player teleports
spawn_node → enemy appears
apply_impulse_to_rigid_body → physics explosion
play_audio_stream → sound plays
```

### 📋 Recording setup

```bash
# Clone and build (2 min setup)
git clone https://github.com/Reza2kn/godot-mcp.git
cd godot-mcp
npm install && npm run build

# For local model demos (clean 20-tool UI)
GODOT_PATH=/path/to/godot \
GODOT_MCP_DISCOVERY_MODE=true \
node build/index.js

# For Claude / full power demos
GODOT_PATH=/path/to/godot \
node build/index.js
```

---

## 📚 Workflows (Step-by-Step Guides)

Call `get_workflow goal="..."` to get a numbered checklist:

| Goal | Steps |
|------|-------|
| `"platformer"` | 11 steps: CharacterBody2D → CollisionShape → Script → Camera → Test |
| `"fps"` | 11 steps: CharacterBody3D → Camera3D → Mouse look → World → Lighting |
| `"top down"` | 9 steps: 8-direction movement → TileMap walls → Camera smoothing |
| `"audio"` | Background music + SFX bus setup + runtime control |
| `"ui"` | CanvasLayer → HBoxContainer → Label → ProgressBar → anchor to screen |
| `"physics"` | Body type guide → collision shapes → forces vs impulses |
| `"signals"` | Connect → emit → custom signals → one-shot connections |
| `"animation"` | AnimatedSprite2D → SpriteFrames → AnimationPlayer → blend times |

---

## 🔧 Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GODOT_PATH` | auto-detect | Full path to the Godot 4 executable |
| `GODOT_MCP_DISCOVERY_MODE` | `false` | `true` = expose 20 tools only (best for local models) |
| `GODOT_PROJECTS_DIR` | `~/GodotProjects` | Default directory for new projects |
| `GODOT_MCP_RUNTIME_PORT` | `9090` | Runtime bridge port; in Conductor defaults to `CONDUCTOR_PORT+8` |
| `GODOT_MCP_EDITOR_PORT` | `9091` | Editor bridge port; in Conductor defaults to `CONDUCTOR_PORT+9` |
| `GODOT_MCP_ALLOWED_ROOTS` | unrestricted | Platform-delimited filesystem roots the MCP may access |
| `GODOT_MCP_CONFIRM_DESTRUCTIVE` | `false` | Require `confirmDestructive=true` for destructive tool families |
| `GODOT_MCP_MAX_RESPONSE_BYTES` | unlimited | Optional cap for individual text responses |

---

## 🏗️ Project Structure

```
src/
├── index.ts                      ← MCP server (1,969 tools, ~50,000 lines)
└── scripts/
    ├── godot_operations.gd       ← Headless GDScript (file & resource ops)
    ├── mcp_interaction_server.gd ← Runtime TCP server (port 9090, 1,000+ commands)
    └── editor_mcp_server.gd      ← Editor plugin TCP server (port 9091)

build/
├── index.js                      ← Compiled MCP server
├── scripts/                      ← GDScript files (copied at build time)
└── godot-editor-plugin/          ← Packaged Godot editor plugin
    └── addons/godot_mcp_editor/
```

## ✅ Verification and Release Checks

Run `npm test` before release. It rebuilds the package, runs the unit suite, and
launches real MCP clients to verify full mode exposes 1,969 unique tools,
discovery mode exposes 20 tools, discovery names are dispatchable, and hidden
tools remain reachable through `godot_call`. The protocol suite also invokes
every one of the 1,969 advertised names and fails on any unknown route, protocol
exception, invalid result envelope, or server crash.

Start with the [documentation index](docs/README.md), or jump directly to:

- [Complete generated tool reference](docs/tool-reference.md)
- [Godot verification and troubleshooting](docs/VERIFICATION.md)
- [Verified multi-tool workflows](docs/WORKFLOWS.md)
- [Architecture and port model](docs/ARCHITECTURE.md)
- [Security policy](SECURITY.md)
- [Support and compatibility](SUPPORT.md)
- [Changelog](CHANGELOG.md)
- [Release procedure](docs/RELEASE.md)

Useful maintainer commands:

```bash
npm run docs:generate  # regenerate all 1,969 schemas and the reference
npm run verify:godot   # real offline + runtime + analysis workflow
npm run benchmark      # discovery/full startup, payload, and call timings
```

---

## 🙏 Acknowledgments

This project builds on [godot-mcp](https://github.com/tugcantopaloglu/godot-mcp) by [Tugcan Topaloglu](https://github.com/tugcantopaloglu) — the ~150-tool server whose architecture (TypeScript MCP server + headless GDScript ops + TCP runtime bridge) we took and pushed all the way to 1,969. The original spark for AI-controlled Godot came from [Solomon Elias (Coding-Solo)](https://github.com/Coding-Solo). Both deserve credit. 🙌

---

## 📜 License

MIT — build games, make tutorials, ship products, teach students, run livestreams. Go wild. 🎮

---

<div align="center">

**1,969 tools. Built for AI. Zero BS.**

[⭐ Star this repo](https://github.com/Reza2kn/godot-mcp) · [📦 npm](https://www.npmjs.com/package/godot-mcp-1969) · [🐛 Issues](https://github.com/Reza2kn/godot-mcp/issues)

</div>
