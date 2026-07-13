import fs from 'fs-extra';
import path from 'path';
import { fileURLToPath } from 'url';

// Get the directory name
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Make the build/index.js file executable
fs.chmodSync(path.join(__dirname, '..', 'build', 'index.js'), '755');

// Copy the scripts directory to the build directory
try {
  // Ensure the build/scripts directory exists
  fs.ensureDirSync(path.join(__dirname, '..', 'build', 'scripts'));
  
  // Copy the godot_operations.gd file
  fs.copyFileSync(
    path.join(__dirname, '..', 'src', 'scripts', 'godot_operations.gd'),
    path.join(__dirname, '..', 'build', 'scripts', 'godot_operations.gd')
  );
  
  // Copy the mcp_interaction_server.gd file
  fs.copyFileSync(
    path.join(__dirname, '..', 'src', 'scripts', 'mcp_interaction_server.gd'),
    path.join(__dirname, '..', 'build', 'scripts', 'mcp_interaction_server.gd')
  );

  // Copy the editor plugin into build/godot-editor-plugin/addons/godot_mcp_editor/
  const pluginDest = path.join(__dirname, '..', 'build', 'godot-editor-plugin', 'addons', 'godot_mcp_editor');
  fs.ensureDirSync(pluginDest);
  fs.copyFileSync(
    path.join(__dirname, '..', 'src', 'scripts', 'editor_mcp_server.gd'),
    path.join(pluginDest, 'editor_mcp_server.gd')
  );
  fs.copyFileSync(
    path.join(__dirname, '..', 'src', 'scripts', 'plugin.cfg'),
    path.join(pluginDest, 'plugin.cfg')
  );

  console.log('Successfully copied scripts to build/scripts');
  console.log('Successfully packaged editor plugin to build/godot-editor-plugin/');
} catch (error) {
  console.error('Error copying scripts:', error);
  process.exit(1);
}

console.log('Build scripts completed successfully!');
