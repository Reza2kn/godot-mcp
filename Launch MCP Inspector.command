#!/bin/bash
cd "$(dirname "$0")"
export GODOT_PATH="/Applications/Godot.app/Contents/MacOS/Godot"
npx @modelcontextprotocol/inspector --port 6969 build/index.js
