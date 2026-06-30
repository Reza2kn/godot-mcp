#!/usr/bin/env node
/**
 * Godot MCP Server
 *
 * This MCP server provides tools for interacting with the Godot game engine.
 * It enables AI assistants to launch the Godot editor, run Godot projects,
 * capture debug output, and control project execution.
 */

import { fileURLToPath } from 'url';
import { join, dirname, basename, normalize } from 'path';
import { existsSync, readdirSync, readFileSync, writeFileSync, copyFileSync, unlinkSync, mkdirSync, renameSync } from 'fs';
import { spawn, execFile } from 'child_process';
import { promisify } from 'util';
import { createConnection, Socket } from 'net';

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ErrorCode,
  ListToolsRequestSchema,
  McpError,
} from '@modelcontextprotocol/sdk/types.js';

import {
  PARAMETER_MAPPINGS,
  REVERSE_PARAMETER_MAPPINGS,
  normalizeParameters,
  convertCamelToSnakeCase,
  validatePath,
  createErrorResponse,
  isGodot44OrLater,
  type OperationParams,
} from './utils.js';

// Check if debug mode is enabled
const DEBUG_MODE: boolean = process.env.DEBUG === 'true';
const GODOT_DEBUG_MODE: boolean = true; // Always use GODOT DEBUG MODE

const execFileAsync = promisify(execFile);

// Derive __filename and __dirname in ESM
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

/**
 * Interface representing a running Godot process
 */
interface GodotProcess {
  process: any;
  output: string[];
  errors: string[];
}

/**
 * Interface for server configuration
 */
interface GodotServerConfig {
  godotPath?: string;
  debugMode?: boolean;
  godotDebugMode?: boolean;
  strictPathValidation?: boolean; // New option to control path validation behavior
}

/**
 * Interface for a TCP connection to the running game
 */
interface GameConnection {
  socket: Socket | null;
  connected: boolean;
  responseBuffer: string;
  pendingResolve: ((value: any) => void) | null;
  projectPath: string | null;
}

/**
 * Main server class for the Godot MCP server
 */
class GodotServer {
  private server: Server;
  private activeProcess: GodotProcess | null = null;
  private godotPath: string | null = null;
  private operationsScriptPath: string;
  private interactionScriptPath: string;
  private validatedPaths: Map<string, boolean> = new Map();
  private strictPathValidation: boolean = false;
  private gameConnection: GameConnection = {
    socket: null,
    connected: false,
    responseBuffer: '',
    pendingResolve: null,
    projectPath: null,
  };
  private lastErrorIndex: number = 0;
  private lastLogIndex: number = 0;
  private readonly INTERACTION_PORT = 9090;
  private readonly AUTOLOAD_NAME = 'McpInteractionServer';

  constructor(config?: GodotServerConfig) {
    // Apply configuration if provided
    let debugMode = DEBUG_MODE;
    let godotDebugMode = GODOT_DEBUG_MODE;

    if (config) {
      if (config.debugMode !== undefined) {
        debugMode = config.debugMode;
      }
      if (config.godotDebugMode !== undefined) {
        godotDebugMode = config.godotDebugMode;
      }
      if (config.strictPathValidation !== undefined) {
        this.strictPathValidation = config.strictPathValidation;
      }

      // Store and validate custom Godot path if provided
      if (config.godotPath) {
        const normalizedPath = normalize(config.godotPath);
        this.godotPath = normalizedPath;
        this.logDebug(`Custom Godot path provided: ${this.godotPath}`);

        // Validate immediately with sync check
        if (!this.isValidGodotPathSync(this.godotPath)) {
          console.warn(`[SERVER] Invalid custom Godot path provided: ${this.godotPath}`);
          this.godotPath = null; // Reset to trigger auto-detection later
        }
      }
    }

    // Set the path to the operations script
    this.operationsScriptPath = join(__dirname, 'scripts', 'godot_operations.gd');
    this.interactionScriptPath = join(__dirname, 'scripts', 'mcp_interaction_server.gd');
    if (debugMode) console.error(`[DEBUG] Operations script path: ${this.operationsScriptPath}`);

    // Initialize the MCP server
    this.server = new Server(
      {
        name: 'godot-mcp',
        version: '0.1.0',
      },
      {
        capabilities: {
          tools: {},
        },
      }
    );

    // Set up tool handlers
    this.setupToolHandlers();

    // Error handling
    this.server.onerror = (error) => console.error('[MCP Error]', error);

    // Cleanup on exit
    process.on('SIGINT', async () => {
      await this.cleanup();
      process.exit(0);
    });
  }

  /**
   * Log debug messages if debug mode is enabled
   * Using stderr instead of stdout to avoid interfering with JSON-RPC communication
   */
  private logDebug(message: string): void {
    if (DEBUG_MODE) {
      console.error(`[DEBUG] ${message}`);
    }
  }


  /**
   * Synchronous validation for constructor use
   * This is a quick check that only verifies file existence, not executable validity
   * Full validation will be performed later in detectGodotPath
   * @param path Path to check
   * @returns True if the path exists or is 'godot' (which might be in PATH)
   */
  private isValidGodotPathSync(path: string): boolean {
    try {
      this.logDebug(`Quick-validating Godot path: ${path}`);
      return path === 'godot' || existsSync(path);
    } catch (error) {
      this.logDebug(`Invalid Godot path: ${path}, error: ${error}`);
      return false;
    }
  }

  /**
   * Validate if a Godot path is valid and executable
   */
  private async isValidGodotPath(path: string): Promise<boolean> {
    // Check cache first
    if (this.validatedPaths.has(path)) {
      return this.validatedPaths.get(path)!;
    }

    try {
      this.logDebug(`Validating Godot path: ${path}`);

      // Check if the file exists (skip for 'godot' which might be in PATH)
      if (path !== 'godot' && !existsSync(path)) {
        this.logDebug(`Path does not exist: ${path}`);
        this.validatedPaths.set(path, false);
        return false;
      }

      // Try to execute Godot with --version flag
      // Using execFileAsync with argument array to prevent command injection
      await execFileAsync(path, ['--version']);

      this.logDebug(`Valid Godot path: ${path}`);
      this.validatedPaths.set(path, true);
      return true;
    } catch (error) {
      this.logDebug(`Invalid Godot path: ${path}, error: ${error}`);
      this.validatedPaths.set(path, false);
      return false;
    }
  }

  /**
   * Detect the Godot executable path based on the operating system
   */
  private async detectGodotPath() {
    // If godotPath is already set and valid, use it
    if (this.godotPath && await this.isValidGodotPath(this.godotPath)) {
      this.logDebug(`Using existing Godot path: ${this.godotPath}`);
      return;
    }

    // Check environment variable next
    if (process.env.GODOT_PATH) {
      const normalizedPath = normalize(process.env.GODOT_PATH);
      this.logDebug(`Checking GODOT_PATH environment variable: ${normalizedPath}`);
      if (await this.isValidGodotPath(normalizedPath)) {
        this.godotPath = normalizedPath;
        this.logDebug(`Using Godot path from environment: ${this.godotPath}`);
        return;
      } else {
        this.logDebug(`GODOT_PATH environment variable is invalid`);
      }
    }

    // Auto-detect based on platform
    const osPlatform = process.platform;
    this.logDebug(`Auto-detecting Godot path for platform: ${osPlatform}`);

    const possiblePaths: string[] = [
      'godot', // Check if 'godot' is in PATH first
    ];

    // Add platform-specific paths
    if (osPlatform === 'darwin') {
      possiblePaths.push(
        '/Applications/Godot.app/Contents/MacOS/Godot',
        '/Applications/Godot_4.app/Contents/MacOS/Godot',
        `${process.env.HOME}/Applications/Godot.app/Contents/MacOS/Godot`,
        `${process.env.HOME}/Applications/Godot_4.app/Contents/MacOS/Godot`,
        `${process.env.HOME}/Library/Application Support/Steam/steamapps/common/Godot Engine/Godot.app/Contents/MacOS/Godot`
      );
    } else if (osPlatform === 'win32') {
      possiblePaths.push(
        'C:\\Program Files\\Godot\\Godot.exe',
        'C:\\Program Files (x86)\\Godot\\Godot.exe',
        'C:\\Program Files\\Godot_4\\Godot.exe',
        'C:\\Program Files (x86)\\Godot_4\\Godot.exe',
        `${process.env.USERPROFILE}\\Godot\\Godot.exe`
      );
    } else if (osPlatform === 'linux') {
      possiblePaths.push(
        '/usr/bin/godot',
        '/usr/local/bin/godot',
        '/snap/bin/godot',
        `${process.env.HOME}/.local/bin/godot`
      );
    }

    // Try each possible path
    for (const path of possiblePaths) {
      const normalizedPath = normalize(path);
      if (await this.isValidGodotPath(normalizedPath)) {
        this.godotPath = normalizedPath;
        this.logDebug(`Found Godot at: ${normalizedPath}`);
        return;
      }
    }

    // If we get here, we couldn't find Godot
    this.logDebug(`Warning: Could not find Godot in common locations for ${osPlatform}`);
    console.error(`[SERVER] Could not find Godot in common locations for ${osPlatform}`);
    console.error(`[SERVER] Set GODOT_PATH=/path/to/godot environment variable or pass { godotPath: '/path/to/godot' } in the config to specify the correct path.`);

    if (this.strictPathValidation) {
      // In strict mode, throw an error
      throw new Error(`Could not find a valid Godot executable. Set GODOT_PATH or provide a valid path in config.`);
    } else {
      // Fallback to a default path in non-strict mode; this may not be valid and requires user configuration for reliability
      if (osPlatform === 'win32') {
        this.godotPath = normalize('C:\\Program Files\\Godot\\Godot.exe');
      } else if (osPlatform === 'darwin') {
        this.godotPath = normalize('/Applications/Godot.app/Contents/MacOS/Godot');
      } else {
        this.godotPath = normalize('/usr/bin/godot');
      }

      this.logDebug(`Using default path: ${this.godotPath}, but this may not work.`);
      console.error(`[SERVER] Using default path: ${this.godotPath}, but this may not work.`);
      console.error(`[SERVER] This fallback behavior will be removed in a future version. Set strictPathValidation: true to opt-in to the new behavior.`);
    }
  }

  /**
   * Set a custom Godot path
   * @param customPath Path to the Godot executable
   * @returns True if the path is valid and was set, false otherwise
   */
  public async setGodotPath(customPath: string): Promise<boolean> {
    if (!customPath) {
      return false;
    }

    // Normalize the path to ensure consistent format across platforms
    // (e.g., backslashes to forward slashes on Windows, resolving relative paths)
    const normalizedPath = normalize(customPath);
    if (await this.isValidGodotPath(normalizedPath)) {
      this.godotPath = normalizedPath;
      this.logDebug(`Godot path set to: ${normalizedPath}`);
      return true;
    }

    this.logDebug(`Failed to set invalid Godot path: ${normalizedPath}`);
    return false;
  }

  /**
   * Inject the interaction server script into the Godot project
   */
  private injectInteractionServer(projectPath: string): void {
    const projectFile = join(projectPath, 'project.godot');
    const destScript = join(projectPath, 'mcp_interaction_server.gd');

    // Copy the interaction script into the project
    copyFileSync(this.interactionScriptPath, destScript);
    this.logDebug(`Copied interaction server script to ${destScript}`);

    // Add autoload entry to project.godot
    let content = readFileSync(projectFile, 'utf8');

    // Check if already injected
    if (content.includes(this.AUTOLOAD_NAME)) {
      this.logDebug('Interaction server autoload already present');
      return;
    }

    const autoloadLine = `${this.AUTOLOAD_NAME}="*res://mcp_interaction_server.gd"`;

    if (content.includes('[autoload]')) {
      // Add after existing [autoload] section header
      content = content.replace('[autoload]', `[autoload]\n\n${autoloadLine}`);
    } else {
      // Add new [autoload] section at end
      content += `\n[autoload]\n\n${autoloadLine}\n`;
    }

    writeFileSync(projectFile, content, 'utf8');
    this.logDebug(`Injected ${this.AUTOLOAD_NAME} autoload into project.godot`);
  }

  /**
   * Remove the interaction server script and autoload from the project
   */
  private removeInteractionServer(projectPath: string): void {
    const projectFile = join(projectPath, 'project.godot');
    const destScript = join(projectPath, 'mcp_interaction_server.gd');

    // Remove autoload line from project.godot
    if (existsSync(projectFile)) {
      let content = readFileSync(projectFile, 'utf8');
      // Remove the autoload line (and any surrounding blank line)
      const autoloadLine = `${this.AUTOLOAD_NAME}="*res://mcp_interaction_server.gd"`;
      content = content.replace(new RegExp(`\\n?${autoloadLine.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\n?`), '\n');
      writeFileSync(projectFile, content, 'utf8');
      this.logDebug('Removed interaction server autoload from project.godot');
    }

    // Delete the script file
    if (existsSync(destScript)) {
      unlinkSync(destScript);
      this.logDebug('Deleted interaction server script from project');
    }

    // Also clean up the .uid file if Godot created one
    const uidFile = destScript + '.uid';
    if (existsSync(uidFile)) {
      unlinkSync(uidFile);
      this.logDebug('Deleted interaction server .uid file');
    }
  }

  /**
   * Connect to the game's TCP interaction server with retries
   */
  private async connectToGame(projectPath: string): Promise<void> {
    this.gameConnection.projectPath = projectPath;

    // Initial delay to let the game start up
    await new Promise(resolve => setTimeout(resolve, 2000));

    const maxAttempts = 10;
    const retryDelay = 500;

    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      if (!this.activeProcess) {
        this.logDebug('Game process no longer running, aborting connection');
        return;
      }

      try {
        await new Promise<void>((resolve, reject) => {
          const socket = createConnection({ host: '127.0.0.1', port: this.INTERACTION_PORT }, () => {
            this.gameConnection.socket = socket;
            this.gameConnection.connected = true;
            this.gameConnection.responseBuffer = '';
            this.logDebug(`Connected to game interaction server (attempt ${attempt})`);
            console.error(`[SERVER] Connected to game interaction server on port ${this.INTERACTION_PORT}`);

            socket.on('data', (data: Buffer) => {
              this.gameConnection.responseBuffer += data.toString();
              // Process complete lines
              while (this.gameConnection.responseBuffer.includes('\n')) {
                const newlinePos = this.gameConnection.responseBuffer.indexOf('\n');
                const line = this.gameConnection.responseBuffer.substring(0, newlinePos).trim();
                this.gameConnection.responseBuffer = this.gameConnection.responseBuffer.substring(newlinePos + 1);
                if (line.length > 0 && this.gameConnection.pendingResolve) {
                  try {
                    const parsed = JSON.parse(line);
                    const resolver = this.gameConnection.pendingResolve;
                    this.gameConnection.pendingResolve = null;
                    resolver(parsed);
                  } catch (e) {
                    this.logDebug(`Failed to parse game response: ${line}`);
                  }
                }
              }
            });

            socket.on('close', () => {
              this.logDebug('Game interaction connection closed');
              this.gameConnection.connected = false;
              this.gameConnection.socket = null;
              if (this.gameConnection.pendingResolve) {
                this.gameConnection.pendingResolve({ error: 'Connection closed' });
                this.gameConnection.pendingResolve = null;
              }
            });

            socket.on('error', (err: Error) => {
              this.logDebug(`Game interaction socket error: ${err.message}`);
            });

            resolve();
          });

          socket.on('error', (err: Error) => {
            reject(err);
          });
        });

        // Successfully connected
        return;
      } catch (err) {
        this.logDebug(`Connection attempt ${attempt}/${maxAttempts} failed, retrying in ${retryDelay}ms...`);
        await new Promise(resolve => setTimeout(resolve, retryDelay));
      }
    }

    console.error(`[SERVER] Failed to connect to game interaction server after ${maxAttempts} attempts`);
  }

  /**
   * Disconnect from the game interaction server
   */
  private disconnectFromGame(): void {
    if (this.gameConnection.socket) {
      this.gameConnection.socket.destroy();
      this.gameConnection.socket = null;
    }
    this.gameConnection.connected = false;
    this.gameConnection.responseBuffer = '';
    if (this.gameConnection.pendingResolve) {
      this.gameConnection.pendingResolve({ error: 'Disconnected' });
      this.gameConnection.pendingResolve = null;
    }
  }

  /**
   * Send a command to the running game and wait for a response
   */
  private async sendGameCommand(command: string, params: Record<string, any> = {}, timeoutMs: number = 10000): Promise<any> {
    if (!this.gameConnection.connected || !this.gameConnection.socket) {
      throw new Error('Not connected to game interaction server. Is the game running?');
    }

    const payload = JSON.stringify({ command, params }) + '\n';

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.gameConnection.pendingResolve = null;
        reject(new Error(`Game command '${command}' timed out after ${timeoutMs / 1000}s`));
      }, timeoutMs);

      this.gameConnection.pendingResolve = (response: any) => {
        clearTimeout(timeout);
        resolve(response);
      };

      this.gameConnection.socket!.write(payload);
    });
  }

  /**
   * Clean up resources when shutting down
   */
  private async cleanup() {
    this.logDebug('Cleaning up resources');
    this.disconnectFromGame();
    if (this.gameConnection.projectPath) {
      this.removeInteractionServer(this.gameConnection.projectPath);
      this.gameConnection.projectPath = null;
    }
    if (this.activeProcess) {
      this.logDebug('Killing active Godot process');
      this.activeProcess.process.kill();
      this.activeProcess = null;
    }
    await this.server.close();
  }

  private async gameCommand(
    name: string,
    args: any,
    argsFn: (a: any) => Record<string, any>,
    timeoutMs?: number
  ): Promise<any> {
    if (!this.activeProcess) return createErrorResponse('No active Godot process. Use run_project first.');
    if (!this.gameConnection.connected) return createErrorResponse('Not connected to game interaction server.');
    args = normalizeParameters(args || {});
    try {
      const response = await this.sendGameCommand(name, argsFn(args), timeoutMs);
      if (response.error) return createErrorResponse(`${name} failed: ${response.error}`);
      return { content: [{ type: 'text', text: JSON.stringify(response, null, 2) }] };
    } catch (error: any) {
      return createErrorResponse(`${name} failed: ${error?.message || 'Unknown error'}`);
    }
  }

  private async headlessOp(
    operation: string,
    args: any,
    argsFn: (a: any) => { projectPath: string; params: OperationParams }
  ): Promise<any> {
    args = normalizeParameters(args || {});
    const { projectPath, params } = argsFn(args);

    if (!projectPath) return createErrorResponse('projectPath is required.');
    if (!validatePath(projectPath)) return createErrorResponse('Invalid path.');

    const projectFile = join(projectPath, 'project.godot');
    if (!existsSync(projectFile)) return createErrorResponse(`Not a valid Godot project: ${projectPath}`);

    try {
      const { stdout, stderr } = await this.executeOperation(operation, params, projectPath);
      if (stderr && stderr.includes('Failed to')) return createErrorResponse(`${operation} failed: ${stderr}`);
      return { content: [{ type: 'text', text: `${operation} succeeded.\n\nOutput: ${stdout}` }] };
    } catch (error: any) {
      return createErrorResponse(`${operation} failed: ${error?.message || 'Unknown error'}`);
    }
  }

  /**
   * Execute a Godot operation using the operations script
   * @param operation The operation to execute
   * @param params The parameters for the operation
   * @param projectPath The path to the Godot project
   * @returns The stdout and stderr from the operation
   */
  private async executeOperation(
    operation: string,
    params: OperationParams,
    projectPath: string
  ): Promise<{ stdout: string; stderr: string }> {
    this.logDebug(`Executing operation: ${operation} in project: ${projectPath}`);
    this.logDebug(`Original operation params: ${JSON.stringify(params)}`);

    // Convert camelCase parameters to snake_case for Godot script
    const snakeCaseParams = convertCamelToSnakeCase(params);
    this.logDebug(`Converted snake_case params: ${JSON.stringify(snakeCaseParams)}`);


    // Ensure godotPath is set
    if (!this.godotPath) {
      await this.detectGodotPath();
      if (!this.godotPath) {
        throw new Error('Could not find a valid Godot executable path');
      }
    }

    try {
      // Serialize the snake_case parameters to a valid JSON string
      const paramsJson = JSON.stringify(snakeCaseParams);

      // Build argument array for execFile to prevent command injection
      // Using execFile with argument arrays avoids shell interpretation entirely
      const args = [
        '--headless',
        '--path',
        projectPath,  // Safe: passed as argument, not interpolated into shell command
        '--script',
        this.operationsScriptPath,
        operation,
        paramsJson,  // Safe: passed as argument, not interpreted by shell
      ];

      
      if (GODOT_DEBUG_MODE) {
        args.push('--debug-godot');
      }

      this.logDebug(`Executing: ${this.godotPath} ${args.join(' ')}`);

      const { stdout, stderr } = await execFileAsync(this.godotPath!, args);

      return { stdout: stdout ?? '', stderr: stderr ?? '' };
    } catch (error: unknown) {
      // If execFileAsync throws, it still contains stdout/stderr
      if (error instanceof Error && 'stdout' in error && 'stderr' in error) {
        const execError = error as Error & { stdout: string; stderr: string };
        return {
          stdout: execError.stdout ?? '',
          stderr: execError.stderr ?? '',
        };
      }

      throw error;
    }
  }

  /**
   * Get the structure of a Godot project
   * @param projectPath Path to the Godot project
   * @returns Object representing the project structure
   */
  private async getProjectStructure(projectPath: string): Promise<any> {
    try {
      // Get top-level directories in the project
      const entries = readdirSync(projectPath, { withFileTypes: true });

      const structure: any = {
        scenes: [],
        scripts: [],
        assets: [],
        other: [],
      };

      for (const entry of entries) {
        if (entry.isDirectory()) {
          const dirName = entry.name.toLowerCase();

          // Skip hidden directories
          if (dirName.startsWith('.')) {
            continue;
          }

          // Count files in common directories
          if (dirName === 'scenes' || dirName.includes('scene')) {
            structure.scenes.push(entry.name);
          } else if (dirName === 'scripts' || dirName.includes('script')) {
            structure.scripts.push(entry.name);
          } else if (
            dirName === 'assets' ||
            dirName === 'textures' ||
            dirName === 'models' ||
            dirName === 'sounds' ||
            dirName === 'music'
          ) {
            structure.assets.push(entry.name);
          } else {
            structure.other.push(entry.name);
          }
        }
      }

      return structure;
    } catch (error) {
      this.logDebug(`Error getting project structure: ${error}`);
      return { error: 'Failed to get project structure' };
    }
  }

  /**
   * Find Godot projects in a directory
   * @param directory Directory to search
   * @param recursive Whether to search recursively
   * @returns Array of Godot projects
   */
  private findGodotProjects(directory: string, recursive: boolean): Array<{ path: string; name: string }> {
    const projects: Array<{ path: string; name: string }> = [];

    try {
      // Check if the directory itself is a Godot project
      const projectFile = join(directory, 'project.godot');
      if (existsSync(projectFile)) {
        projects.push({
          path: directory,
          name: basename(directory),
        });
      }

      // If not recursive, only check immediate subdirectories
      if (!recursive) {
        const entries = readdirSync(directory, { withFileTypes: true });
        for (const entry of entries) {
          if (entry.isDirectory()) {
            const subdir = join(directory, entry.name);
            const projectFile = join(subdir, 'project.godot');
            if (existsSync(projectFile)) {
              projects.push({
                path: subdir,
                name: entry.name,
              });
            }
          }
        }
      } else {
        // Recursive search
        const entries = readdirSync(directory, { withFileTypes: true });
        for (const entry of entries) {
          if (entry.isDirectory()) {
            const subdir = join(directory, entry.name);
            // Skip hidden directories
            if (entry.name.startsWith('.')) {
              continue;
            }
            // Check if this directory is a Godot project
            const projectFile = join(subdir, 'project.godot');
            if (existsSync(projectFile)) {
              projects.push({
                path: subdir,
                name: entry.name,
              });
            } else {
              // Recursively search this directory
              const subProjects = this.findGodotProjects(subdir, true);
              projects.push(...subProjects);
            }
          }
        }
      }
    } catch (error) {
      this.logDebug(`Error searching directory ${directory}: ${error}`);
    }

    return projects;
  }

  /**
   * Set up the tool handlers for the MCP server
   */
  private setupToolHandlers() {
    // Define available tools
    this.server.setRequestHandler(ListToolsRequestSchema, async () => ({
      tools: [
        {
          name: 'launch_editor',
          description: 'Launch Godot editor for a specific project',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: {
                type: 'string',
                description: 'Godot project path',
              },
            },
            required: ['projectPath'],
          },
        },
        {
          name: 'run_project',
          description: 'Run the Godot project and capture output',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: {
                type: 'string',
                description: 'Godot project path',
              },
              scene: {
                type: 'string',
                description: 'Optional: Specific scene to run',
              },
            },
            required: ['projectPath'],
          },
        },
        {
          name: 'get_debug_output',
          description: 'Get the current debug output and errors',
          inputSchema: {
            type: 'object',
            properties: {},
            required: [],
          },
        },
        {
          name: 'stop_project',
          description: 'Stop the currently running Godot project',
          inputSchema: {
            type: 'object',
            properties: {},
            required: [],
          },
        },
        {
          name: 'get_godot_version',
          description: 'Get the installed Godot version',
          inputSchema: {
            type: 'object',
            properties: {},
            required: [],
          },
        },
        {
          name: 'list_projects',
          description: 'List Godot projects in a directory',
          inputSchema: {
            type: 'object',
            properties: {
              directory: {
                type: 'string',
                description: 'Directory to search for Godot projects',
              },
              recursive: {
                type: 'boolean',
                description: 'Whether to search recursively (default: false)',
              },
            },
            required: ['directory'],
          },
        },
        {
          name: 'get_project_info',
          description: 'Retrieve metadata about a Godot project',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: {
                type: 'string',
                description: 'Godot project path',
              },
            },
            required: ['projectPath'],
          },
        },
        {
          name: 'create_scene',
          description: 'Create a new Godot scene file',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: {
                type: 'string',
                description: 'Godot project path',
              },
              scenePath: {
                type: 'string',
                description: 'Path where the scene file will be saved (relative to project)',
              },
              rootNodeType: {
                type: 'string',
                description: 'Type of the root node (e.g., Node2D, Node3D)',
              },
            },
            required: ['projectPath', 'scenePath'],
          },
        },
        {
          name: 'add_node',
          description: 'Add a node to an existing scene',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: {
                type: 'string',
                description: 'Godot project path',
              },
              scenePath: {
                type: 'string',
                description: 'Scene file path (relative to project)',
              },
              parentNodePath: {
                type: 'string',
                description: 'Path to the parent node (e.g., "root" or "root/Player")',
              },
              nodeType: {
                type: 'string',
                description: 'Type of node to add (e.g., Sprite2D, CollisionShape2D)',
              },
              nodeName: {
                type: 'string',
                description: 'Name for the new node',
              },
              properties: {
                type: 'object',
                description: 'Optional properties to set on the node',
              },
            },
            required: ['projectPath', 'scenePath', 'nodeType', 'nodeName'],
          },
        },
        {
          name: 'load_sprite',
          description: 'Load a sprite into a Sprite2D node',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: {
                type: 'string',
                description: 'Godot project path',
              },
              scenePath: {
                type: 'string',
                description: 'Scene file path (relative to project)',
              },
              nodePath: {
                type: 'string',
                description: 'Path to the Sprite2D node (e.g., "root/Player/Sprite2D")',
              },
              texturePath: {
                type: 'string',
                description: 'Path to the texture file (relative to project)',
              },
            },
            required: ['projectPath', 'scenePath', 'nodePath', 'texturePath'],
          },
        },
        {
          name: 'export_mesh_library',
          description: 'Export a scene as a MeshLibrary resource',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: {
                type: 'string',
                description: 'Godot project path',
              },
              scenePath: {
                type: 'string',
                description: 'Path to the scene file (.tscn) to export',
              },
              outputPath: {
                type: 'string',
                description: 'Path where the mesh library (.res) will be saved',
              },
              meshItemNames: {
                type: 'array',
                items: {
                  type: 'string',
                },
                description: 'Optional: Names of specific mesh items to include (defaults to all)',
              },
            },
            required: ['projectPath', 'scenePath', 'outputPath'],
          },
        },
        {
          name: 'save_scene',
          description: 'Save changes to a scene file',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: {
                type: 'string',
                description: 'Godot project path',
              },
              scenePath: {
                type: 'string',
                description: 'Scene file path (relative to project)',
              },
              newPath: {
                type: 'string',
                description: 'Optional: New path to save the scene to (for creating variants)',
              },
            },
            required: ['projectPath', 'scenePath'],
          },
        },
        {
          name: 'get_uid',
          description: 'Get the UID for a specific file in a Godot project (for Godot 4.4+)',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: {
                type: 'string',
                description: 'Godot project path',
              },
              filePath: {
                type: 'string',
                description: 'Path to the file (relative to project) for which to get the UID',
              },
            },
            required: ['projectPath', 'filePath'],
          },
        },
        {
          name: 'update_project_uids',
          description: 'Update UID references by resaving resources (4.4+)',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: {
                type: 'string',
                description: 'Godot project path',
              },
            },
            required: ['projectPath'],
          },
        },
        {
          name: 'game_screenshot',
          description: 'Screenshot the running game (returns base64 PNG)',
          inputSchema: {
            type: 'object',
            properties: {},
            required: [],
          },
        },
        {
          name: 'game_click',
          description: 'Click at a position in the running Godot game window',
          inputSchema: {
            type: 'object',
            properties: {
              x: {
                type: 'number',
                description: 'X coordinate to click',
              },
              y: {
                type: 'number',
                description: 'Y coordinate to click',
              },
              button: {
                type: 'number',
                description: 'Mouse button (1=left, 2=right, 3=middle). Default: 1',
              },
            },
            required: ['x', 'y'],
          },
        },
        {
          name: 'game_key_press',
          description: 'Send a key press or input action to the running game',
          inputSchema: {
            type: 'object',
            properties: {
              key: {
                type: 'string',
                description: 'Key name (e.g. "W", "Space", "Escape", "Enter")',
              },
              action: {
                type: 'string',
                description: 'Godot input action name (e.g. "move_forward", "ui_accept")',
              },
              pressed: {
                type: 'boolean',
                description: 'Press (true) or release (false). Default: true (auto-release)',
              },
            },
            required: [],
          },
        },
        {
          name: 'game_mouse_move',
          description: 'Move the mouse in the running Godot game',
          inputSchema: {
            type: 'object',
            properties: {
              x: {
                type: 'number',
                description: 'Absolute X position',
              },
              y: {
                type: 'number',
                description: 'Absolute Y position',
              },
              relative_x: {
                type: 'number',
                description: 'Relative X movement',
              },
              relative_y: {
                type: 'number',
                description: 'Relative Y movement',
              },
            },
            required: ['x', 'y'],
          },
        },
        {
          name: 'game_get_ui',
          description: 'Get visible UI elements from the running game',
          inputSchema: {
            type: 'object',
            properties: {},
            required: [],
          },
        },
        {
          name: 'game_get_scene_tree',
          description: 'Get scene tree structure of the running game',
          inputSchema: {
            type: 'object',
            properties: {},
            required: [],
          },
        },
{
          name: 'game_eval',
          description: 'Execute GDScript in the running game. Use "return" for values.',
          inputSchema: {
            type: 'object',
            properties: {
              code: {
                type: 'string',
                description: 'GDScript code to execute. Use "return" to return values.',
              },
            },
            required: ['code'],
          },
        },
        {
          name: 'game_get_property',
          description: 'Get a property value from any node in the running game by its path',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: {
                type: 'string',
                description: 'Path to the node (e.g., "/root/Player", "/root/Main/Enemy")',
              },
              property: {
                type: 'string',
                description: 'Property name to get (e.g., "position", "health", "visible")',
              },
            },
            required: ['nodePath', 'property'],
          },
        },
        {
          name: 'game_set_property',
          description: 'Set a property on a node in the running game',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: {
                type: 'string',
                description: 'Path to the node',
              },
              property: {
                type: 'string',
                description: 'Property name to set',
              },
              value: {
                description: 'Value to set. Use objects for vectors/colors',
              },
              typeHint: {
                type: 'string',
                description: 'Optional type hint: "Vector2", "Vector3", "Color"',
              },
            },
            required: ['nodePath', 'property', 'value'],
          },
        },
        {
          name: 'game_call_method',
          description: 'Call a method on any node in the running game with optional arguments',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: {
                type: 'string',
                description: 'Path to the node',
              },
              method: {
                type: 'string',
                description: 'Method name to call',
              },
              args: {
                type: 'array',
                description: 'Optional array of arguments to pass to the method',
              },
            },
            required: ['nodePath', 'method'],
          },
        },
        {
          name: 'game_get_node_info',
          description: 'Get node info: class, properties, signals, methods, children',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: {
                type: 'string',
                description: 'Path to the node (e.g., "/root/Player")',
              },
            },
            required: ['nodePath'],
          },
        },
        {
          name: 'game_instantiate_scene',
          description: 'Load a PackedScene and add it as a child of a node in the running game',
          inputSchema: {
            type: 'object',
            properties: {
              scenePath: {
                type: 'string',
                description: 'Resource path to the scene (e.g., "res://scenes/enemy.tscn")',
              },
              parentPath: {
                type: 'string',
                description: 'Path to the parent node. Default: "/root"',
              },
            },
            required: ['scenePath'],
          },
        },
        {
          name: 'game_remove_node',
          description: 'Remove and free a node from the running game\'s scene tree',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: {
                type: 'string',
                description: 'Path to the node to remove',
              },
            },
            required: ['nodePath'],
          },
        },
        {
          name: 'game_change_scene',
          description: 'Switch to a different scene file in the running game',
          inputSchema: {
            type: 'object',
            properties: {
              scenePath: {
                type: 'string',
                description: 'Resource path to the scene (e.g., "res://scenes/levels/level2.tscn")',
              },
            },
            required: ['scenePath'],
          },
        },
        {
          name: 'game_pause',
          description: 'Pause or unpause the running game',
          inputSchema: {
            type: 'object',
            properties: {
              paused: {
                type: 'boolean',
                description: 'True to pause, false to unpause. Default: true',
              },
            },
            required: [],
          },
        },
        {
          name: 'game_performance',
          description: 'Get performance metrics (FPS, memory, draw calls)',
          inputSchema: {
            type: 'object',
            properties: {},
            required: [],
          },
        },
        {
          name: 'game_wait',
          description: 'Wait N frames in the running game',
          inputSchema: {
            type: 'object',
            properties: {
              frames: {
                type: 'number',
                description: 'Number of frames to wait. Default: 1',
              },
            },
            required: [],
          },
        },
{
          name: 'read_scene',
          description: 'Read scene file as JSON node tree (headless)',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: {
                type: 'string',
                description: 'Godot project path',
              },
              scenePath: {
                type: 'string',
                description: 'Scene file path (relative to project)',
              },
            },
            required: ['projectPath', 'scenePath'],
          },
        },
        {
          name: 'modify_scene_node',
          description: 'Modify node properties in a scene file (headless)',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: {
                type: 'string',
                description: 'Godot project path',
              },
              scenePath: {
                type: 'string',
                description: 'Scene file path (relative to project)',
              },
              nodePath: {
                type: 'string',
                description: 'Path to the node within the scene (e.g., "root/Player/Sprite2D")',
              },
              properties: {
                type: 'object',
                description: 'Properties to set on the node as key-value pairs',
              },
            },
            required: ['projectPath', 'scenePath', 'nodePath', 'properties'],
          },
        },
        {
          name: 'remove_scene_node',
          description: 'Remove a node from a scene file (headless)',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: {
                type: 'string',
                description: 'Godot project path',
              },
              scenePath: {
                type: 'string',
                description: 'Scene file path (relative to project)',
              },
              nodePath: {
                type: 'string',
                description: 'Path to the node to remove (e.g., "root/Player/OldNode")',
              },
            },
            required: ['projectPath', 'scenePath', 'nodePath'],
          },
        },
{
          name: 'read_project_settings',
          description: 'Read project.godot as structured JSON',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: {
                type: 'string',
                description: 'Godot project path',
              },
            },
            required: ['projectPath'],
          },
        },
        {
          name: 'modify_project_settings',
          description: 'Modify a project.godot setting',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: {
                type: 'string',
                description: 'Godot project path',
              },
              section: {
                type: 'string',
                description: 'Section in project.godot (e.g., "application", "display", "rendering")',
              },
              key: {
                type: 'string',
                description: 'Setting key (e.g., "run/main_scene", "window/size/viewport_width")',
              },
              value: {
                type: 'string',
                description: 'Value to set (as a string, will be written as-is)',
              },
            },
            required: ['projectPath', 'section', 'key', 'value'],
          },
        },
        {
          name: 'list_project_files',
          description: 'List project files, optionally filtered by extension',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: {
                type: 'string',
                description: 'Godot project path',
              },
              extensions: {
                type: 'array',
                items: { type: 'string' },
                description: 'Optional file extensions to filter by (e.g., [".gd", ".tscn"]). Include the dot.',
              },
              subdirectory: {
                type: 'string',
                description: 'Optional subdirectory to search in (e.g., "scripts/player")',
              },
            },
            required: ['projectPath'],
          },
        },
{
          name: 'game_connect_signal',
          description: 'Connect a signal from one node to a method on another node in the running game',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to the source node that emits the signal' },
              signalName: { type: 'string', description: 'Name of the signal to connect' },
              targetPath: { type: 'string', description: 'Path to the target node that receives the signal' },
              method: { type: 'string', description: 'Method name to call on the target node' },
            },
            required: ['nodePath', 'signalName', 'targetPath', 'method'],
          },
        },
        {
          name: 'game_disconnect_signal',
          description: 'Disconnect a signal connection in the running game',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to the source node' },
              signalName: { type: 'string', description: 'Name of the signal' },
              targetPath: { type: 'string', description: 'Path to the target node' },
              method: { type: 'string', description: 'Method name on the target' },
            },
            required: ['nodePath', 'signalName', 'targetPath', 'method'],
          },
        },
        {
          name: 'game_emit_signal',
          description: 'Emit a signal on a node in the running game, optionally with arguments',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to the node' },
              signalName: { type: 'string', description: 'Name of the signal to emit' },
              args: { type: 'array', description: 'Optional arguments to pass with the signal' },
            },
            required: ['nodePath', 'signalName'],
          },
        },
        {
          name: 'game_play_animation',
          description: 'Control an AnimationPlayer node: play, stop, pause, or list animations',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to the AnimationPlayer node' },
              action: { type: 'string', description: 'Action: "play", "stop", "pause", or "get_list"' },
              animation: { type: 'string', description: 'Animation name (required for "play" action)' },
            },
            required: ['nodePath'],
          },
        },
        {
          name: 'game_tween_property',
          description: 'Tween a node property in the running game',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to the node' },
              property: { type: 'string', description: 'Property to tween (e.g., "position", "modulate")' },
              finalValue: { description: 'Target value. Use {x,y} for Vector2, {x,y,z} for Vector3, {r,g,b,a} for Color' },
              duration: { type: 'number', description: 'Duration in seconds. Default: 1.0' },
              transType: { type: 'number', description: 'Tween.TransitionType enum value. Default: 0 (LINEAR)' },
              easeType: { type: 'number', description: 'Tween.EaseType enum value. Default: 2 (IN_OUT)' },
            },
            required: ['nodePath', 'property', 'finalValue'],
          },
        },
        {
          name: 'game_get_nodes_in_group',
          description: 'Get all nodes belonging to a specific group in the running game',
          inputSchema: {
            type: 'object',
            properties: {
              group: { type: 'string', description: 'Group name (e.g., "enemies", "player", "checkpoints")' },
            },
            required: ['group'],
          },
        },
        {
          name: 'game_find_nodes_by_class',
          description: 'Find all nodes of a specific class type in the running game',
          inputSchema: {
            type: 'object',
            properties: {
              className: { type: 'string', description: 'Class name to search for (e.g., "CharacterBody3D", "Light3D")' },
              rootPath: { type: 'string', description: 'Root node path to start searching from. Default: "/root"' },
            },
            required: ['className'],
          },
        },
        {
          name: 'game_reparent_node',
          description: 'Move a node to a new parent in the running game\'s scene tree',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to the node to move' },
              newParentPath: { type: 'string', description: 'Path to the new parent node' },
              keepGlobalTransform: { type: 'boolean', description: 'Whether to keep the global transform. Default: true' },
            },
            required: ['nodePath', 'newParentPath'],
          },
        },
{
          name: 'attach_script',
          description: 'Attach a GDScript to a scene node (headless)',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              scenePath: { type: 'string', description: 'Scene file path (relative to project)' },
              nodePath: { type: 'string', description: 'Path to the node within the scene (e.g., "root/Player")' },
              scriptPath: { type: 'string', description: 'Path to the .gd script file (relative to project)' },
            },
            required: ['projectPath', 'scenePath', 'nodePath', 'scriptPath'],
          },
        },
        {
          name: 'create_resource',
          description: 'Create a .tres resource file (headless)',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              resourceType: { type: 'string', description: 'Godot class name (e.g., "StandardMaterial3D", "Theme", "Environment")' },
              resourcePath: { type: 'string', description: 'Where to save the .tres file (relative to project)' },
              properties: { type: 'object', description: 'Optional properties to set on the resource' },
            },
            required: ['projectPath', 'resourceType', 'resourcePath'],
          },
        },
        // File I/O tools
        {
          name: 'read_file',
          description: 'Read a text file from a Godot project',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              filePath: { type: 'string', description: 'File path relative to project root' },
            },
            required: ['projectPath', 'filePath'],
          },
        },
        {
          name: 'write_file',
          description: 'Create or overwrite a text file in a Godot project',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              filePath: { type: 'string', description: 'File path relative to project root' },
              content: { type: 'string', description: 'File content to write' },
            },
            required: ['projectPath', 'filePath', 'content'],
          },
        },
        {
          name: 'delete_file',
          description: 'Delete a file from a Godot project',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              filePath: { type: 'string', description: 'File path relative to project root' },
            },
            required: ['projectPath', 'filePath'],
          },
        },
        {
          name: 'create_directory',
          description: 'Create a directory inside a Godot project',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              directoryPath: { type: 'string', description: 'Directory path relative to project root' },
            },
            required: ['projectPath', 'directoryPath'],
          },
        },
        // Error/Log capture tools
        {
          name: 'game_get_errors',
          description: 'Get new push_error/push_warning messages since last call',
          inputSchema: {
            type: 'object',
            properties: {},
            required: [],
          },
        },
        {
          name: 'game_get_logs',
          description: 'Get new print output from the running game since last call',
          inputSchema: {
            type: 'object',
            properties: {},
            required: [],
          },
        },
        // Enhanced input tools
        {
          name: 'game_key_hold',
          description: 'Hold a key down without auto-releasing',
          inputSchema: {
            type: 'object',
            properties: {
              key: { type: 'string', description: 'Key name (e.g. "W", "Space", "Shift")' },
              action: { type: 'string', description: 'Godot input action name (e.g. "move_forward")' },
            },
            required: [],
          },
        },
        {
          name: 'game_key_release',
          description: 'Release a previously held key',
          inputSchema: {
            type: 'object',
            properties: {
              key: { type: 'string', description: 'Key name to release' },
              action: { type: 'string', description: 'Godot input action name to release' },
            },
            required: [],
          },
        },
        {
          name: 'game_scroll',
          description: 'Send mouse scroll wheel event at position',
          inputSchema: {
            type: 'object',
            properties: {
              x: { type: 'number', description: 'X position for scroll event' },
              y: { type: 'number', description: 'Y position for scroll event' },
              direction: { type: 'string', description: '"up", "down", "left", or "right". Default: "up"' },
              amount: { type: 'number', description: 'Scroll amount (clicks). Default: 1' },
            },
            required: ['x', 'y'],
          },
        },
        {
          name: 'game_mouse_drag',
          description: 'Drag mouse between two points over N frames',
          inputSchema: {
            type: 'object',
            properties: {
              fromX: { type: 'number', description: 'Start X coordinate' },
              fromY: { type: 'number', description: 'Start Y coordinate' },
              toX: { type: 'number', description: 'End X coordinate' },
              toY: { type: 'number', description: 'End Y coordinate' },
              button: { type: 'number', description: 'Mouse button (1=left). Default: 1' },
              steps: { type: 'number', description: 'Number of frames for the drag. Default: 10' },
            },
            required: ['fromX', 'fromY', 'toX', 'toY'],
          },
        },
        {
          name: 'game_gamepad',
          description: 'Send gamepad button or axis input event',
          inputSchema: {
            type: 'object',
            properties: {
              type: { type: 'string', description: '"button" or "axis"' },
              index: { type: 'number', description: 'Button or axis index' },
              value: { type: 'number', description: 'Value: 0/1 for buttons, -1.0 to 1.0 for axes' },
              device: { type: 'number', description: 'Gamepad device index. Default: 0' },
            },
            required: ['type', 'index', 'value'],
          },
        },
        // Project management tools
        {
          name: 'create_project',
          description: 'Create a new Godot project from scratch',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Directory where the project will be created' },
              projectName: { type: 'string', description: 'Name of the project' },
            },
            required: ['projectPath', 'projectName'],
          },
        },
        {
          name: 'manage_autoloads',
          description: 'Add, remove, or list autoloads in a Godot project',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              action: { type: 'string', description: '"list", "add", or "remove"' },
              name: { type: 'string', description: 'Autoload name (required for add/remove)' },
              path: { type: 'string', description: 'Script/scene path (required for add, e.g. "res://globals.gd")' },
            },
            required: ['projectPath', 'action'],
          },
        },
        {
          name: 'manage_input_map',
          description: 'Add, remove, or list input actions and bindings',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              action: { type: 'string', description: '"list", "add", or "remove"' },
              actionName: { type: 'string', description: 'Input action name (required for add/remove)' },
              key: { type: 'string', description: 'Key to bind (for add, e.g. "W", "Space")' },
              deadzone: { type: 'number', description: 'Deadzone for the action. Default: 0.5' },
            },
            required: ['projectPath', 'action'],
          },
        },
        {
          name: 'manage_export_presets',
          description: 'Create or modify export preset configuration',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              action: { type: 'string', description: '"list", "add", or "remove"' },
              name: { type: 'string', description: 'Preset name (required for add/remove)' },
              platform: { type: 'string', description: 'Platform (for add, e.g. "Windows Desktop", "Linux", "Web")' },
              runnable: { type: 'boolean', description: 'Whether this preset is runnable. Default: false' },
            },
            required: ['projectPath', 'action'],
          },
        },
        // Advanced runtime tools
        {
          name: 'game_get_camera',
          description: 'Get active camera position, rotation, and size',
          inputSchema: {
            type: 'object',
            properties: {},
            required: [],
          },
        },
        {
          name: 'game_set_camera',
          description: 'Move or rotate the active camera',
          inputSchema: {
            type: 'object',
            properties: {
              position: { type: 'object', description: '{x,y} or {x,y,z} for camera position' },
              rotation: { type: 'object', description: '{x,y,z} rotation in degrees' },
              zoom: { type: 'object', description: '{x,y} zoom for Camera2D' },
              fov: { type: 'number', description: 'Field of view for Camera3D' },
            },
            required: [],
          },
        },
        {
          name: 'game_raycast',
          description: 'Cast a ray and return collision results',
          inputSchema: {
            type: 'object',
            properties: {
              from: { type: 'object', description: 'Start point {x,y} or {x,y,z}' },
              to: { type: 'object', description: 'End point {x,y} or {x,y,z}' },
              collisionMask: { type: 'number', description: 'Collision mask. Default: 0xFFFFFFFF' },
            },
            required: ['from', 'to'],
          },
        },
        {
          name: 'game_get_audio',
          description: 'Get audio bus layout and playing streams',
          inputSchema: {
            type: 'object',
            properties: {},
            required: [],
          },
        },
        {
          name: 'game_spawn_node',
          description: 'Create a new node of any type at runtime',
          inputSchema: {
            type: 'object',
            properties: {
              type: { type: 'string', description: 'Node class name (e.g. "Sprite2D", "CharacterBody3D")' },
              name: { type: 'string', description: 'Name for the new node. Default: auto-generated' },
              parentPath: { type: 'string', description: 'Parent node path. Default: "/root"' },
              properties: { type: 'object', description: 'Properties to set on the new node' },
            },
            required: ['type'],
          },
        },
        // Shader, audio, navigation, tilemap, collision, environment tools
        {
          name: 'game_set_shader_param',
          description: 'Set a shader parameter on a node\'s material',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to the node with a ShaderMaterial' },
              paramName: { type: 'string', description: 'Shader parameter name' },
              value: { description: 'Value to set (number, object, array, etc.)' },
              typeHint: { type: 'string', description: 'Optional type hint (e.g. "Color", "Vector2")' },
            },
            required: ['nodePath', 'paramName', 'value'],
          },
        },
        {
          name: 'game_audio_play',
          description: 'Play, stop, or pause an AudioStreamPlayer node',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to AudioStreamPlayer/2D/3D node' },
              action: { type: 'string', description: 'Action: play, stop, pause, resume' },
              stream: { type: 'string', description: 'Optional res:// path to load a new stream' },
              volume: { type: 'number', description: 'Volume (linear 0-1)' },
              pitch: { type: 'number', description: 'Pitch scale' },
              bus: { type: 'string', description: 'Audio bus name' },
              fromPosition: { type: 'number', description: 'Start position in seconds' },
            },
            required: ['nodePath'],
          },
        },
        {
          name: 'game_audio_bus',
          description: 'Set volume, mute, or solo on an audio bus',
          inputSchema: {
            type: 'object',
            properties: {
              busName: { type: 'string', description: 'Bus name. Default: "Master"' },
              volume: { type: 'number', description: 'Volume (linear 0-1)' },
              mute: { type: 'boolean', description: 'Mute the bus' },
              solo: { type: 'boolean', description: 'Solo the bus' },
            },
            required: [],
          },
        },
        {
          name: 'game_navigate_path',
          description: 'Query a navigation path between two points',
          inputSchema: {
            type: 'object',
            properties: {
              start: { type: 'object', description: 'Start point {x,y} or {x,y,z}' },
              end: { type: 'object', description: 'End point {x,y} or {x,y,z}' },
              optimize: { type: 'boolean', description: 'Use string-pulling optimization. Default: true' },
            },
            required: ['start', 'end'],
          },
        },
        {
          name: 'game_tilemap',
          description: 'Get or set cells in a TileMapLayer node',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to TileMapLayer node' },
              action: { type: 'string', description: 'Action: set_cells, get_cell, erase_cells, get_used_cells' },
              x: { type: 'number', description: 'Cell X coordinate (for get_cell)' },
              y: { type: 'number', description: 'Cell Y coordinate (for get_cell)' },
              cells: { type: 'array', description: 'Array of cell objects for set_cells/erase_cells' },
              sourceId: { type: 'number', description: 'Filter by source_id (for get_used_cells)' },
            },
            required: ['nodePath', 'action'],
          },
        },
        {
          name: 'game_add_collision',
          description: 'Add a collision shape to a physics body node',
          inputSchema: {
            type: 'object',
            properties: {
              parentPath: { type: 'string', description: 'Path to CollisionBody/Area node' },
              shapeType: { type: 'string', description: 'Shape: box, sphere/circle, capsule, cylinder, ray, segment' },
              shapeParams: { type: 'object', description: 'Shape dimensions (e.g. {radius, height})' },
              collisionLayer: { type: 'number', description: 'Collision layer bitmask' },
              collisionMask: { type: 'number', description: 'Collision mask bitmask' },
              disabled: { type: 'boolean', description: 'Start disabled' },
            },
            required: ['parentPath', 'shapeType'],
          },
        },
        {
          name: 'game_environment',
          description: 'Get or set environment and post-processing settings',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: get or set. Default: set' },
              backgroundMode: { type: 'number', description: '0=clear, 1=custom_color, 2=sky, 3=canvas' },
              backgroundColor: { type: 'object', description: 'Background color {r,g,b,a}' },
              ambientLightColor: { type: 'object', description: 'Ambient light color {r,g,b,a}' },
              ambientLightEnergy: { type: 'number', description: 'Ambient light energy' },
              fogEnabled: { type: 'boolean', description: 'Enable fog' },
              fogDensity: { type: 'number', description: 'Fog density' },
              fogLightColor: { type: 'object', description: 'Fog light color {r,g,b,a}' },
              glowEnabled: { type: 'boolean', description: 'Enable glow' },
              glowIntensity: { type: 'number', description: 'Glow intensity' },
              glowBloom: { type: 'number', description: 'Glow bloom' },
              tonemapMode: { type: 'number', description: '0=linear, 1=reinhardt, 2=filmic, 3=aces' },
              ssaoEnabled: { type: 'boolean', description: 'Enable SSAO' },
              ssaoRadius: { type: 'number', description: 'SSAO radius' },
              ssaoIntensity: { type: 'number', description: 'SSAO intensity' },
              ssrEnabled: { type: 'boolean', description: 'Enable SSR' },
              brightness: { type: 'number', description: 'Brightness adjustment' },
              contrast: { type: 'number', description: 'Contrast adjustment' },
              saturation: { type: 'number', description: 'Saturation adjustment' },
            },
            required: [],
          },
        },
        // Group, timer, particles, animation, export, state, physics, joint, bone, theme, viewport, debug tools
        {
          name: 'game_manage_group',
          description: 'Add or remove a node from a group, or list groups',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to the node' },
              action: { type: 'string', description: 'Action: add, remove, get_groups, clear_group' },
              group: { type: 'string', description: 'Group name' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_create_timer',
          description: 'Create a Timer node with configuration',
          inputSchema: {
            type: 'object',
            properties: {
              parentPath: { type: 'string', description: 'Parent node path. Default: "/root"' },
              waitTime: { type: 'number', description: 'Timer duration in seconds. Default: 1.0' },
              oneShot: { type: 'boolean', description: 'One-shot mode. Default: false' },
              autostart: { type: 'boolean', description: 'Auto-start the timer. Default: false' },
              name: { type: 'string', description: 'Optional timer node name' },
            },
            required: [],
          },
        },
        {
          name: 'game_set_particles',
          description: 'Configure GPUParticles2D/3D node properties',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to GPUParticles node' },
              emitting: { type: 'boolean', description: 'Enable/disable emission' },
              amount: { type: 'number', description: 'Number of particles' },
              lifetime: { type: 'number', description: 'Particle lifetime in seconds' },
              oneShot: { type: 'boolean', description: 'One-shot mode' },
              speedScale: { type: 'number', description: 'Speed scale' },
              explosiveness: { type: 'number', description: 'Explosiveness ratio (0-1)' },
              randomness: { type: 'number', description: 'Randomness ratio (0-1)' },
              processMaterial: { type: 'object', description: 'ParticleProcessMaterial settings' },
            },
            required: ['nodePath'],
          },
        },
        {
          name: 'game_create_animation',
          description: 'Create an animation with tracks and keyframes',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to AnimationPlayer node' },
              animationName: { type: 'string', description: 'Name for the new animation' },
              length: { type: 'number', description: 'Animation length in seconds. Default: 1.0' },
              loopMode: { type: 'number', description: '0=none, 1=linear, 2=pingpong' },
              tracks: { type: 'array', description: 'Array of track definitions' },
              library: { type: 'string', description: 'Animation library name. Default: ""' },
            },
            required: ['nodePath', 'animationName'],
          },
        },
        {
          name: 'export_project',
          description: 'Export a Godot project using a preset',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              presetName: { type: 'string', description: 'Export preset name' },
              outputPath: { type: 'string', description: 'Output file path for the exported build' },
              debug: { type: 'boolean', description: 'Use debug export. Default: false' },
            },
            required: ['projectPath', 'presetName', 'outputPath'],
          },
        },
        {
          name: 'game_serialize_state',
          description: 'Save or load node tree state as JSON',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Root node path. Default: "/root"' },
              action: { type: 'string', description: 'Action: save or load. Default: save' },
              data: { type: 'object', description: 'State data to restore (for load)' },
              maxDepth: { type: 'number', description: 'Max tree depth to serialize. Default: 5' },
            },
            required: [],
          },
        },
        {
          name: 'game_physics_body',
          description: 'Configure physics body properties (mass, velocity, etc.)',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to physics body node' },
              gravityScale: { type: 'number', description: 'Gravity scale' },
              mass: { type: 'number', description: 'Body mass' },
              linearVelocity: { type: 'object', description: 'Linear velocity {x,y} or {x,y,z}' },
              angularVelocity: { description: 'Angular velocity (float for 2D, {x,y,z} for 3D)' },
              linearDamp: { type: 'number', description: 'Linear damping' },
              angularDamp: { type: 'number', description: 'Angular damping' },
              friction: { type: 'number', description: 'Physics material friction' },
              bounce: { type: 'number', description: 'Physics material bounce' },
              freeze: { type: 'boolean', description: 'Freeze the body' },
              sleeping: { type: 'boolean', description: 'Put body to sleep' },
            },
            required: ['nodePath'],
          },
        },
        {
          name: 'game_create_joint',
          description: 'Create a physics joint between two bodies',
          inputSchema: {
            type: 'object',
            properties: {
              parentPath: { type: 'string', description: 'Parent node path for the joint' },
              jointType: { type: 'string', description: 'Joint type: pin_2d, spring_2d, groove_2d, pin_3d, hinge_3d, cone_3d, slider_3d' },
              nodeAPath: { type: 'string', description: 'Path to first body' },
              nodeBPath: { type: 'string', description: 'Path to second body' },
              stiffness: { type: 'number', description: 'Spring stiffness (spring_2d)' },
              damping: { type: 'number', description: 'Spring damping (spring_2d)' },
              length: { type: 'number', description: 'Length (spring_2d, groove_2d)' },
              softness: { type: 'number', description: 'Softness (pin_2d)' },
            },
            required: ['parentPath', 'jointType'],
          },
        },
        {
          name: 'game_bone_pose',
          description: 'Get or set bone poses on a Skeleton3D node',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to Skeleton3D node' },
              action: { type: 'string', description: 'Action: list, get, or set. Default: list' },
              boneIndex: { type: 'number', description: 'Bone index' },
              boneName: { type: 'string', description: 'Bone name (alternative to index)' },
              position: { type: 'object', description: 'Bone position {x,y,z}' },
              rotation: { type: 'object', description: 'Bone rotation quaternion {x,y,z,w}' },
              scale: { type: 'object', description: 'Bone scale {x,y,z}' },
            },
            required: ['nodePath'],
          },
        },
        {
          name: 'game_ui_theme',
          description: 'Apply theme overrides to a Control node',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to Control node' },
              overrides: { type: 'object', description: 'Theme overrides: {colors, constants, fontSizes}' },
            },
            required: ['nodePath', 'overrides'],
          },
        },
        {
          name: 'game_viewport',
          description: 'Create or configure a SubViewport node',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: create, configure, or get' },
              parentPath: { type: 'string', description: 'Parent path (for create)' },
              nodePath: { type: 'string', description: 'SubViewport path (for configure/get)' },
              width: { type: 'number', description: 'Viewport width' },
              height: { type: 'number', description: 'Viewport height' },
              msaa: { type: 'number', description: 'MSAA level (0=disabled, 1=2x, 2=4x, 3=8x)' },
              transparentBg: { type: 'boolean', description: 'Transparent background' },
              name: { type: 'string', description: 'Viewport name (for create)' },
            },
            required: [],
          },
        },
        {
          name: 'game_debug_draw',
          description: 'Draw debug lines, spheres, or boxes in 3D',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: line, sphere, box, or clear' },
              from: { type: 'object', description: 'Line start {x,y,z}' },
              to: { type: 'object', description: 'Line end {x,y,z}' },
              center: { type: 'object', description: 'Sphere/box center {x,y,z}' },
              radius: { type: 'number', description: 'Sphere radius. Default: 0.5' },
              size: { type: 'object', description: 'Box size {x,y,z}' },
              color: { type: 'object', description: 'Draw color {r,g,b,a}. Default: red' },
              duration: { type: 'number', description: 'Frames to persist (0=permanent)' },
            },
            required: ['action'],
          },
        },
        // Batch 1: Networking + Input + System + Signals + Script
        {
          name: 'game_http_request',
          description: 'HTTP GET/POST/PUT/DELETE with headers and body',
          inputSchema: {
            type: 'object',
            properties: {
              url: { type: 'string', description: 'Request URL' },
              method: { type: 'string', description: 'HTTP method: GET, POST, PUT, DELETE. Default: GET' },
              headers: { type: 'object', description: 'Request headers as key-value pairs' },
              body: { type: 'string', description: 'Request body string' },
              timeout: { type: 'number', description: 'Timeout in seconds. Default: 30' },
            },
            required: ['url'],
          },
        },
        {
          name: 'game_websocket',
          description: 'WebSocket client connect/disconnect/send messages',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: connect, disconnect, send, status' },
              url: { type: 'string', description: 'WebSocket URL (for connect)' },
              message: { type: 'string', description: 'Message to send (for send)' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_multiplayer',
          description: 'ENet multiplayer create server/client/disconnect',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: create_server, create_client, disconnect, status' },
              port: { type: 'number', description: 'Server port. Default: 7000' },
              address: { type: 'string', description: 'Server address for client. Default: 127.0.0.1' },
              maxClients: { type: 'number', description: 'Max clients for server. Default: 32' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_rpc',
          description: 'Call or configure RPC methods on nodes',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to the node' },
              action: { type: 'string', description: 'Action: call, configure' },
              method: { type: 'string', description: 'Method name' },
              args: { type: 'array', description: 'Arguments for the RPC call' },
              mode: { type: 'string', description: 'RPC mode: any_peer, authority' },
              sync: { type: 'string', description: 'Sync mode: call_local, call_remote' },
              channel: { type: 'number', description: 'Transfer channel' },
            },
            required: ['nodePath', 'action', 'method'],
          },
        },
        {
          name: 'game_touch',
          description: 'Simulate touch press/release/drag and gestures',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: press, release, drag' },
              x: { type: 'number', description: 'Touch X position' },
              y: { type: 'number', description: 'Touch Y position' },
              index: { type: 'number', description: 'Touch index. Default: 0' },
              toX: { type: 'number', description: 'Drag end X (for drag)' },
              toY: { type: 'number', description: 'Drag end Y (for drag)' },
              steps: { type: 'number', description: 'Drag steps. Default: 10' },
            },
            required: ['action', 'x', 'y'],
          },
        },
        {
          name: 'game_input_state',
          description: 'Query pressed keys, mouse position, connected pads',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: query, warp_mouse, set_mouse_mode' },
              x: { type: 'number', description: 'Mouse X (for warp_mouse)' },
              y: { type: 'number', description: 'Mouse Y (for warp_mouse)' },
              mouseMode: { type: 'string', description: 'Mode: visible, hidden, captured, confined' },
            },
            required: [],
          },
        },
        {
          name: 'game_input_action',
          description: 'Manage runtime InputMap actions and strength',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: set_strength, add_action, remove_action, list' },
              actionName: { type: 'string', description: 'Input action name' },
              strength: { type: 'number', description: 'Action strength 0.0-1.0' },
              key: { type: 'string', description: 'Key name (for add_action)' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_list_signals',
          description: 'List all signals on a node with connections',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to the node' },
            },
            required: ['nodePath'],
          },
        },
        {
          name: 'game_await_signal',
          description: 'Await a signal with timeout and return args',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to the node' },
              signalName: { type: 'string', description: 'Signal name to await' },
              timeout: { type: 'number', description: 'Timeout in seconds. Default: 10' },
            },
            required: ['nodePath', 'signalName'],
          },
        },
        {
          name: 'game_script',
          description: 'Attach, detach, or get source of node scripts',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to the node' },
              action: { type: 'string', description: 'Action: attach, detach, get_source' },
              source: { type: 'string', description: 'GDScript source code (for attach)' },
              className: { type: 'string', description: 'Class the script extends' },
            },
            required: ['nodePath', 'action'],
          },
        },
        {
          name: 'game_window',
          description: 'Get/set window size, fullscreen, title, position',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: get or set. Default: get' },
              width: { type: 'number', description: 'Window width' },
              height: { type: 'number', description: 'Window height' },
              fullscreen: { type: 'boolean', description: 'Fullscreen mode' },
              borderless: { type: 'boolean', description: 'Borderless mode' },
              title: { type: 'string', description: 'Window title' },
              position: { type: 'object', description: 'Window position {x, y}' },
              vsync: { type: 'boolean', description: 'Enable vsync' },
            },
            required: [],
          },
        },
        {
          name: 'game_os_info',
          description: 'Get platform, locale, screen, adapter, memory info',
          inputSchema: {
            type: 'object',
            properties: {},
            required: [],
          },
        },
        {
          name: 'game_time_scale',
          description: 'Get/set Engine.time_scale and timing info',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: get or set. Default: get' },
              timeScale: { type: 'number', description: 'Time scale value (for set)' },
            },
            required: [],
          },
        },
        {
          name: 'game_process_mode',
          description: 'Set node process mode (pausable/always/disabled)',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to the node' },
              mode: { type: 'string', description: 'Mode: inherit, pausable, when_paused, always, disabled' },
            },
            required: ['nodePath', 'mode'],
          },
        },
        {
          name: 'game_world_settings',
          description: 'Get/set gravity, physics FPS, and world settings',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: get or set. Default: get' },
              gravity: { type: 'number', description: 'Gravity magnitude' },
              gravityDirection: { type: 'object', description: 'Gravity direction vector {x,y,z}' },
              physicsFps: { type: 'number', description: 'Physics ticks per second' },
            },
            required: [],
          },
        },
        // Batch 2: 3D Rendering + Lighting + Sky + Physics
        {
          name: 'game_csg',
          description: 'Create/configure CSG nodes with boolean operations',
          inputSchema: {
            type: 'object',
            properties: {
              parentPath: { type: 'string', description: 'Parent node path' },
              action: { type: 'string', description: 'Action: create or configure' },
              csgType: { type: 'string', description: 'CSG type: box, sphere, cylinder, mesh, combiner' },
              nodePath: { type: 'string', description: 'Node path (for configure)' },
              operation: { type: 'string', description: 'Boolean op: union, intersection, subtraction' },
              size: { type: 'object', description: 'Size {x,y,z} (box)' },
              radius: { type: 'number', description: 'Radius (sphere/cylinder)' },
              height: { type: 'number', description: 'Height (cylinder)' },
              material: { type: 'string', description: 'Material resource path' },
              name: { type: 'string', description: 'Node name' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_multimesh',
          description: 'Create/configure MultiMeshInstance3D for instancing',
          inputSchema: {
            type: 'object',
            properties: {
              parentPath: { type: 'string', description: 'Parent node path' },
              action: { type: 'string', description: 'Action: create, set_instance, get_info' },
              nodePath: { type: 'string', description: 'Node path (for set_instance/get_info)' },
              meshType: { type: 'string', description: 'Mesh: box, sphere, cylinder, quad' },
              count: { type: 'number', description: 'Instance count' },
              index: { type: 'number', description: 'Instance index (for set_instance)' },
              transform: { type: 'object', description: 'Transform {origin:{x,y,z}, rotation:{x,y,z}}' },
              name: { type: 'string', description: 'Node name' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_procedural_mesh',
          description: 'Generate meshes via ArrayMesh from vertex data',
          inputSchema: {
            type: 'object',
            properties: {
              parentPath: { type: 'string', description: 'Parent node path' },
              vertices: { type: 'array', description: 'Vertex positions [[x,y,z],...]' },
              normals: { type: 'array', description: 'Vertex normals [[x,y,z],...]' },
              uvs: { type: 'array', description: 'UV coordinates [[u,v],...]' },
              indices: { type: 'array', description: 'Triangle indices [i0,i1,i2,...]' },
              name: { type: 'string', description: 'Node name' },
            },
            required: ['parentPath', 'vertices'],
          },
        },
        {
          name: 'game_light_3d',
          description: 'Create/configure 3D lights (directional/omni/spot)',
          inputSchema: {
            type: 'object',
            properties: {
              parentPath: { type: 'string', description: 'Parent node path' },
              action: { type: 'string', description: 'Action: create or configure' },
              lightType: { type: 'string', description: 'Type: directional, omni, spot' },
              nodePath: { type: 'string', description: 'Node path (for configure)' },
              color: { type: 'object', description: 'Light color {r,g,b}' },
              energy: { type: 'number', description: 'Light energy/intensity' },
              range: { type: 'number', description: 'Light range (omni/spot)' },
              shadows: { type: 'boolean', description: 'Enable shadow casting' },
              spotAngle: { type: 'number', description: 'Spot cone angle in degrees' },
              name: { type: 'string', description: 'Node name' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_mesh_instance',
          description: 'Create MeshInstance3D with primitive meshes',
          inputSchema: {
            type: 'object',
            properties: {
              parentPath: { type: 'string', description: 'Parent node path' },
              meshType: { type: 'string', description: 'Mesh: box, sphere, cylinder, capsule, plane, quad' },
              size: { type: 'object', description: 'Mesh size {x,y,z}' },
              radius: { type: 'number', description: 'Mesh radius' },
              height: { type: 'number', description: 'Mesh height' },
              material: { type: 'string', description: 'Material resource path or color hex' },
              name: { type: 'string', description: 'Node name' },
            },
            required: ['parentPath', 'meshType'],
          },
        },
        {
          name: 'game_gridmap',
          description: 'GridMap set/get/clear cells and query used cells',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to GridMap node' },
              action: { type: 'string', description: 'Action: set_cell, get_cell, clear, get_used' },
              x: { type: 'number', description: 'Cell X coordinate' },
              y: { type: 'number', description: 'Cell Y coordinate' },
              z: { type: 'number', description: 'Cell Z coordinate' },
              item: { type: 'number', description: 'MeshLibrary item index' },
              orientation: { type: 'number', description: 'Cell orientation index' },
            },
            required: ['nodePath', 'action'],
          },
        },
        {
          name: 'game_3d_effects',
          description: 'Create ReflectionProbe, Decal, or FogVolume',
          inputSchema: {
            type: 'object',
            properties: {
              parentPath: { type: 'string', description: 'Parent node path' },
              effectType: { type: 'string', description: 'Type: reflection_probe, decal, fog_volume' },
              size: { type: 'object', description: 'Effect size {x,y,z}' },
              intensity: { type: 'number', description: 'Effect intensity' },
              name: { type: 'string', description: 'Node name' },
            },
            required: ['parentPath', 'effectType'],
          },
        },
        {
          name: 'game_gi',
          description: 'Create/configure VoxelGI or LightmapGI',
          inputSchema: {
            type: 'object',
            properties: {
              parentPath: { type: 'string', description: 'Parent node path' },
              giType: { type: 'string', description: 'Type: voxel_gi or lightmap_gi' },
              size: { type: 'object', description: 'Extents size {x,y,z}' },
              name: { type: 'string', description: 'Node name' },
            },
            required: ['parentPath', 'giType'],
          },
        },
        {
          name: 'game_path_3d',
          description: 'Create Path3D/Curve3D and manage curve points',
          inputSchema: {
            type: 'object',
            properties: {
              parentPath: { type: 'string', description: 'Parent node path' },
              action: { type: 'string', description: 'Action: create, add_point, set_points, get_points' },
              nodePath: { type: 'string', description: 'Path3D node path (for add/set/get)' },
              points: { type: 'array', description: 'Array of points [{x,y,z},...]' },
              point: { type: 'object', description: 'Single point {x,y,z}' },
              name: { type: 'string', description: 'Node name' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_sky',
          description: 'Create/configure Sky with procedural/physical sky',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: create or configure' },
              skyType: { type: 'string', description: 'Type: procedural or physical' },
              topColor: { type: 'object', description: 'Sky top color {r,g,b}' },
              bottomColor: { type: 'object', description: 'Horizon bottom color {r,g,b}' },
              sunEnergy: { type: 'number', description: 'Sun energy/brightness' },
              groundColor: { type: 'object', description: 'Ground color {r,g,b}' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_camera_attributes',
          description: 'Configure DOF, exposure, auto-exposure on camera',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: get or set' },
              dofBlurFar: { type: 'number', description: 'DOF far blur distance' },
              dofBlurNear: { type: 'number', description: 'DOF near blur distance' },
              dofBlurAmount: { type: 'number', description: 'DOF blur amount' },
              exposureMultiplier: { type: 'number', description: 'Exposure multiplier' },
              autoExposure: { type: 'boolean', description: 'Enable auto exposure' },
              autoExposureScale: { type: 'number', description: 'Auto exposure scale' },
            },
            required: [],
          },
        },
        {
          name: 'game_navigation_3d',
          description: 'Create/configure NavigationRegion3D and bake',
          inputSchema: {
            type: 'object',
            properties: {
              parentPath: { type: 'string', description: 'Parent node path' },
              action: { type: 'string', description: 'Action: create, bake, configure' },
              nodePath: { type: 'string', description: 'Node path (for bake/configure)' },
              cellSize: { type: 'number', description: 'Navigation cell size' },
              agentRadius: { type: 'number', description: 'Agent radius' },
              agentHeight: { type: 'number', description: 'Agent height' },
              name: { type: 'string', description: 'Node name' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_physics_3d',
          description: 'Area3D queries and point/shape intersection tests',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: overlap, point_query, shape_query, ray' },
              nodePath: { type: 'string', description: 'Area3D/node path (for overlap)' },
              from: { type: 'object', description: 'Ray/point origin {x,y,z}' },
              to: { type: 'object', description: 'Ray end {x,y,z}' },
              collisionMask: { type: 'number', description: 'Collision mask bitmask' },
            },
            required: ['action'],
          },
        },
        // Batch 3: 2D Systems + Animation Advanced + Audio Effects
        {
          name: 'game_canvas',
          description: 'Create/configure CanvasLayer and CanvasModulate',
          inputSchema: {
            type: 'object',
            properties: {
              parentPath: { type: 'string', description: 'Parent node path' },
              action: { type: 'string', description: 'Action: create_layer, create_modulate, configure' },
              nodePath: { type: 'string', description: 'Node path (for configure)' },
              layer: { type: 'number', description: 'Canvas layer number' },
              color: { type: 'object', description: 'Modulate color {r,g,b,a}' },
              name: { type: 'string', description: 'Node name' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_canvas_draw',
          description: '2D drawing: line/rect/circle/polygon/text/clear',
          inputSchema: {
            type: 'object',
            properties: {
              parentPath: { type: 'string', description: 'Parent node path for draw node' },
              action: { type: 'string', description: 'Action: line, rect, circle, polygon, text, clear' },
              from: { type: 'object', description: 'Start point {x,y}' },
              to: { type: 'object', description: 'End point {x,y}' },
              center: { type: 'object', description: 'Center point {x,y}' },
              radius: { type: 'number', description: 'Circle radius' },
              rect: { type: 'object', description: 'Rectangle {x,y,w,h}' },
              points: { type: 'array', description: 'Polygon points [{x,y},...]' },
              text: { type: 'string', description: 'Text to draw' },
              color: { type: 'object', description: 'Draw color {r,g,b,a}' },
              width: { type: 'number', description: 'Line width. Default: 2' },
              filled: { type: 'boolean', description: 'Fill shape. Default: true' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_light_2d',
          description: 'Create/configure 2D lights and light occluders',
          inputSchema: {
            type: 'object',
            properties: {
              parentPath: { type: 'string', description: 'Parent node path' },
              action: { type: 'string', description: 'Action: create_point, create_directional, create_occluder' },
              nodePath: { type: 'string', description: 'Node path (for configure)' },
              color: { type: 'object', description: 'Light color {r,g,b,a}' },
              energy: { type: 'number', description: 'Light energy' },
              range: { type: 'number', description: 'Light texture range' },
              name: { type: 'string', description: 'Node name' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_parallax',
          description: 'Create/configure ParallaxBackground and layers',
          inputSchema: {
            type: 'object',
            properties: {
              parentPath: { type: 'string', description: 'Parent node path' },
              action: { type: 'string', description: 'Action: create_background, add_layer, configure' },
              nodePath: { type: 'string', description: 'Node path (for configure)' },
              motionScale: { type: 'object', description: 'Motion scale {x,y}' },
              motionOffset: { type: 'object', description: 'Motion offset {x,y}' },
              mirroring: { type: 'object', description: 'Mirroring {x,y}' },
              name: { type: 'string', description: 'Node name' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_shape_2d',
          description: 'Line2D/Polygon2D point manipulation',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to Line2D/Polygon2D node' },
              action: { type: 'string', description: 'Action: add_point, set_points, clear, get_points' },
              points: { type: 'array', description: 'Array of points [{x,y},...]' },
              point: { type: 'object', description: 'Single point {x,y}' },
              width: { type: 'number', description: 'Line width' },
              color: { type: 'object', description: 'Color {r,g,b,a}' },
            },
            required: ['nodePath', 'action'],
          },
        },
        {
          name: 'game_path_2d',
          description: 'Path2D/Curve2D management and AnimatedSprite2D',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: create, add_point, set_points, get_points' },
              parentPath: { type: 'string', description: 'Parent node path (for create)' },
              nodePath: { type: 'string', description: 'Path2D node path' },
              points: { type: 'array', description: 'Array of points [{x,y},...]' },
              point: { type: 'object', description: 'Single point {x,y}' },
              name: { type: 'string', description: 'Node name' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_physics_2d',
          description: 'Area2D queries and 2D point/shape intersections',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: overlap, point_query, shape_query, ray' },
              nodePath: { type: 'string', description: 'Area2D/node path (for overlap)' },
              from: { type: 'object', description: 'Origin point {x,y}' },
              to: { type: 'object', description: 'End point {x,y} (for ray)' },
              collisionMask: { type: 'number', description: 'Collision mask bitmask' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_animation_tree',
          description: 'AnimationTree state machine travel and params',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to AnimationTree node' },
              action: { type: 'string', description: 'Action: travel, set_param, get_state, get_params' },
              stateName: { type: 'string', description: 'State name (for travel)' },
              paramName: { type: 'string', description: 'Parameter name' },
              paramValue: { description: 'Parameter value' },
            },
            required: ['nodePath', 'action'],
          },
        },
        {
          name: 'game_animation_control',
          description: 'AnimationPlayer seek/queue/speed/info control',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to AnimationPlayer node' },
              action: { type: 'string', description: 'Action: seek, queue, set_speed, get_info, stop' },
              animationName: { type: 'string', description: 'Animation name' },
              position: { type: 'number', description: 'Seek position in seconds' },
              speed: { type: 'number', description: 'Playback speed scale' },
            },
            required: ['nodePath', 'action'],
          },
        },
        {
          name: 'game_skeleton_ik',
          description: 'SkeletonIK3D start/stop/set target position',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to SkeletonIK3D node' },
              action: { type: 'string', description: 'Action: start, stop, set_target' },
              target: { type: 'object', description: 'Target position {x,y,z}' },
            },
            required: ['nodePath', 'action'],
          },
        },
        {
          name: 'game_audio_effect',
          description: 'Add/remove/configure audio bus effects',
          inputSchema: {
            type: 'object',
            properties: {
              busName: { type: 'string', description: 'Audio bus name. Default: Master' },
              action: { type: 'string', description: 'Action: add, remove, configure, list' },
              effectType: { type: 'string', description: 'Effect: reverb, delay, chorus, eq, compressor, limiter' },
              index: { type: 'number', description: 'Effect index' },
              properties: { type: 'object', description: 'Effect properties to set' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_audio_bus_layout',
          description: 'Create/remove/reorder audio buses and routing',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: add, remove, move, set_send, list' },
              busName: { type: 'string', description: 'Bus name' },
              sendTo: { type: 'string', description: 'Send target bus name' },
              index: { type: 'number', description: 'Target index (for move)' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_audio_spatial',
          description: 'Configure AudioStreamPlayer3D spatial properties',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to AudioStreamPlayer3D' },
              action: { type: 'string', description: 'Action: configure, get_info' },
              maxDistance: { type: 'number', description: 'Maximum audible distance' },
              unitSize: { type: 'number', description: 'Unit size for distance attenuation' },
              maxDb: { type: 'number', description: 'Maximum volume in dB' },
              attenuationModel: { type: 'string', description: 'Model: inverse, inverse_square, logarithmic' },
            },
            required: ['nodePath', 'action'],
          },
        },
        // Batch 4: Editor/Headless + Localization + Resource
        {
          name: 'rename_file',
          description: 'Rename or move a file within the project',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              filePath: { type: 'string', description: 'Current file path (relative to project)' },
              newPath: { type: 'string', description: 'New file path (relative to project)' },
            },
            required: ['projectPath', 'filePath', 'newPath'],
          },
        },
        {
          name: 'manage_resource',
          description: 'Read or modify .tres/.res resource files',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              resourcePath: { type: 'string', description: 'Resource file path (relative to project)' },
              action: { type: 'string', description: 'Action: read or modify' },
              properties: { type: 'object', description: 'Properties to modify' },
            },
            required: ['projectPath', 'resourcePath', 'action'],
          },
        },
        {
          name: 'create_script',
          description: 'Create a GDScript file from a template',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              scriptPath: { type: 'string', description: 'Script file path (relative to project)' },
              extends: { type: 'string', description: 'Base class to extend. Default: Node' },
              className: { type: 'string', description: 'Optional class_name' },
              methods: { type: 'array', description: 'Method stubs to include' },
              source: { type: 'string', description: 'Full source code (overrides template)' },
            },
            required: ['projectPath', 'scriptPath'],
          },
        },
        {
          name: 'manage_scene_signals',
          description: 'List/add/remove signal connections in .tscn files',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              scenePath: { type: 'string', description: 'Scene file path (relative to project)' },
              action: { type: 'string', description: 'Action: list, add, remove' },
              signalName: { type: 'string', description: 'Signal name' },
              sourcePath: { type: 'string', description: 'Source node path' },
              targetPath: { type: 'string', description: 'Target node path' },
              method: { type: 'string', description: 'Target method name' },
            },
            required: ['projectPath', 'scenePath', 'action'],
          },
        },
        {
          name: 'manage_layers',
          description: 'List/set named layer definitions in project',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              action: { type: 'string', description: 'Action: list or set' },
              layerType: { type: 'string', description: 'Type: render, physics_2d, physics_3d, navigation' },
              layer: { type: 'number', description: 'Layer number (1-32)' },
              name: { type: 'string', description: 'Layer name' },
            },
            required: ['projectPath', 'action'],
          },
        },
        {
          name: 'manage_plugins',
          description: 'List/enable/disable editor plugins',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              action: { type: 'string', description: 'Action: list, enable, disable' },
              pluginName: { type: 'string', description: 'Plugin name' },
            },
            required: ['projectPath', 'action'],
          },
        },
        {
          name: 'manage_shader',
          description: 'Create or read .gdshader files',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              shaderPath: { type: 'string', description: 'Shader file path (relative to project)' },
              action: { type: 'string', description: 'Action: create or read' },
              shaderType: { type: 'string', description: 'Type: spatial, canvas_item, particles, sky' },
              source: { type: 'string', description: 'Shader source code (for create)' },
            },
            required: ['projectPath', 'shaderPath', 'action'],
          },
        },
        {
          name: 'manage_theme_resource',
          description: 'Create/read/modify Theme .tres resources',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              resourcePath: { type: 'string', description: 'Theme file path (relative to project)' },
              action: { type: 'string', description: 'Action: create, read, modify' },
              properties: { type: 'object', description: 'Theme properties to set' },
            },
            required: ['projectPath', 'resourcePath', 'action'],
          },
        },
        {
          name: 'set_main_scene',
          description: 'Set the main scene in project.godot',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              scenePath: { type: 'string', description: 'Scene path (relative to project)' },
            },
            required: ['projectPath', 'scenePath'],
          },
        },
        {
          name: 'manage_scene_structure',
          description: 'Rename/duplicate/move nodes within .tscn scenes',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              scenePath: { type: 'string', description: 'Scene file path (relative to project)' },
              action: { type: 'string', description: 'Action: rename, duplicate, move' },
              nodePath: { type: 'string', description: 'Source node path in scene' },
              newName: { type: 'string', description: 'New name (for rename)' },
              newParentPath: { type: 'string', description: 'New parent path (for move)' },
            },
            required: ['projectPath', 'scenePath', 'action', 'nodePath'],
          },
        },
        {
          name: 'manage_translations',
          description: 'List/add/remove translation files in project',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Godot project path' },
              action: { type: 'string', description: 'Action: list, add, remove' },
              translationPath: { type: 'string', description: 'Translation file path' },
            },
            required: ['projectPath', 'action'],
          },
        },
        {
          name: 'game_locale',
          description: 'Set/get locale and translate strings at runtime',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: get, set, translate' },
              locale: { type: 'string', description: 'Locale code (e.g. en, es, fr)' },
              key: { type: 'string', description: 'Translation key (for translate)' },
            },
            required: ['action'],
          },
        },
        // Batch 5: UI Controls + Rendering + Resource Runtime
        {
          name: 'game_ui_control',
          description: 'Set focus, anchors, tooltip, mouse filter on Control',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to Control node' },
              action: { type: 'string', description: 'Action: configure, grab_focus, release_focus, get_info' },
              anchorPreset: { type: 'number', description: 'Anchor preset value' },
              tooltip: { type: 'string', description: 'Tooltip text' },
              mouseFilter: { type: 'string', description: 'Mouse filter: stop, pass, ignore' },
              minSize: { type: 'object', description: 'Minimum size {x,y}' },
            },
            required: ['nodePath', 'action'],
          },
        },
        {
          name: 'game_ui_text',
          description: 'LineEdit/TextEdit/RichTextLabel text operations',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to text control' },
              action: { type: 'string', description: 'Action: get, set, append, clear, select, bbcode' },
              text: { type: 'string', description: 'Text content' },
              caretPosition: { type: 'number', description: 'Caret column position' },
              selectionFrom: { type: 'number', description: 'Selection start' },
              selectionTo: { type: 'number', description: 'Selection end' },
            },
            required: ['nodePath', 'action'],
          },
        },
        {
          name: 'game_ui_popup',
          description: 'Show/hide/popup for Popup/Dialog/Window nodes',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to Popup/Dialog/Window' },
              action: { type: 'string', description: 'Action: popup_centered, popup, hide, get_info' },
              size: { type: 'object', description: 'Popup size {x,y}' },
              title: { type: 'string', description: 'Dialog title text' },
              text: { type: 'string', description: 'Dialog body text' },
            },
            required: ['nodePath', 'action'],
          },
        },
        {
          name: 'game_ui_tree',
          description: 'Tree control: get/select/collapse/add/remove items',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to Tree control' },
              action: { type: 'string', description: 'Action: get_items, select, collapse, expand, add, remove' },
              itemPath: { type: 'string', description: 'Item path (slash-separated indices)' },
              text: { type: 'string', description: 'Item text (for add)' },
              column: { type: 'number', description: 'Column index. Default: 0' },
            },
            required: ['nodePath', 'action'],
          },
        },
        {
          name: 'game_ui_item_list',
          description: 'ItemList/OptionButton: get/select/add/remove items',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to ItemList/OptionButton' },
              action: { type: 'string', description: 'Action: get_items, select, add, remove, clear' },
              index: { type: 'number', description: 'Item index' },
              text: { type: 'string', description: 'Item text (for add)' },
            },
            required: ['nodePath', 'action'],
          },
        },
        {
          name: 'game_ui_tabs',
          description: 'TabContainer/TabBar: get/set current tab',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to TabContainer/TabBar' },
              action: { type: 'string', description: 'Action: get_tabs, set_current, set_title' },
              index: { type: 'number', description: 'Tab index' },
              title: { type: 'string', description: 'Tab title' },
            },
            required: ['nodePath', 'action'],
          },
        },
        {
          name: 'game_ui_menu',
          description: 'PopupMenu/MenuBar: add/remove/get menu items',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to PopupMenu/MenuBar' },
              action: { type: 'string', description: 'Action: get_items, add, remove, set_checked, clear' },
              index: { type: 'number', description: 'Item index' },
              text: { type: 'string', description: 'Item text (for add)' },
              checked: { type: 'boolean', description: 'Checked state' },
              id: { type: 'number', description: 'Item ID' },
            },
            required: ['nodePath', 'action'],
          },
        },
        {
          name: 'game_ui_range',
          description: 'ProgressBar/Slider/SpinBox/ColorPicker get/set',
          inputSchema: {
            type: 'object',
            properties: {
              nodePath: { type: 'string', description: 'Path to Range/ColorPicker node' },
              action: { type: 'string', description: 'Action: get or set' },
              value: { type: 'number', description: 'Value (for Range nodes)' },
              minValue: { type: 'number', description: 'Minimum value' },
              maxValue: { type: 'number', description: 'Maximum value' },
              step: { type: 'number', description: 'Step value' },
              color: { type: 'object', description: 'Color {r,g,b,a} (for ColorPicker)' },
            },
            required: ['nodePath', 'action'],
          },
        },
        {
          name: 'game_render_settings',
          description: 'Get/set MSAA, FXAA, TAA, scaling mode/scale',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: get or set' },
              msaa2d: { type: 'number', description: 'MSAA 2D mode (0-3)' },
              msaa3d: { type: 'number', description: 'MSAA 3D mode (0-3)' },
              fxaa: { type: 'boolean', description: 'Enable FXAA' },
              taa: { type: 'boolean', description: 'Enable TAA' },
              scalingMode: { type: 'number', description: 'Scaling mode (0=bilinear, 1=FSR1, 2=FSR2)' },
              scalingScale: { type: 'number', description: 'Render scale (0.0-1.0)' },
            },
            required: [],
          },
        },
        {
          name: 'game_resource',
          description: 'Runtime resource load, save, or preload',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: load, save, exists' },
              path: { type: 'string', description: 'Resource path (res://)' },
              nodePath: { type: 'string', description: 'Node path (for save - saves node resource)' },
              property: { type: 'string', description: 'Property name holding the resource' },
            },
            required: ['action', 'path'],
          },
        },
        // Batch 6: Visual Shader + Terrain + Video + CI/CD
        {
          name: 'game_visual_shader',
          description: 'Create and edit VisualShader graphs: add/connect/disconnect nodes',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: create, add_node, connect, disconnect, get_nodes, apply' },
              nodePath: { type: 'string', description: 'Target node path (for apply)' },
              shaderType: { type: 'string', description: 'Shader type: spatial, canvas_item, particles, sky, fog' },
              nodeClass: { type: 'string', description: 'VisualShaderNode class name (for add_node)' },
              position: { type: 'object', description: 'Node position {x, y} (for add_node)' },
              fromNode: { type: 'number', description: 'Source node ID (for connect/disconnect)' },
              fromPort: { type: 'number', description: 'Source port index' },
              toNode: { type: 'number', description: 'Destination node ID (for connect/disconnect)' },
              toPort: { type: 'number', description: 'Destination port index' },
              shaderId: { type: 'number', description: 'Shader resource ID (for multi-shader scenes)' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_terrain',
          description: 'Create/modify terrain meshes from heightmap data',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: create, modify, get_height, paint' },
              parentPath: { type: 'string', description: 'Parent node path' },
              nodePath: { type: 'string', description: 'Terrain node path' },
              heightData: { type: 'array', description: 'Array of float height values (for create)', items: { type: 'number' } },
              width: { type: 'number', description: 'Terrain width in vertices' },
              depth: { type: 'number', description: 'Terrain depth in vertices' },
              maxHeight: { type: 'number', description: 'Maximum terrain height' },
              x: { type: 'number', description: 'X position (for modify/get_height/paint)' },
              z: { type: 'number', description: 'Z position (for modify/get_height/paint)' },
              radius: { type: 'number', description: 'Brush radius (for modify/paint)' },
              heightDelta: { type: 'number', description: 'Height change amount (for modify)' },
              color: { type: 'object', description: 'Vertex color {r,g,b,a} (for paint)' },
              name: { type: 'string', description: 'Node name' },
            },
            required: ['action'],
          },
        },
        {
          name: 'game_video',
          description: 'Video playback control: play, pause, stop, seek on VideoStreamPlayer',
          inputSchema: {
            type: 'object',
            properties: {
              action: { type: 'string', description: 'Action: create, play, pause, stop, seek, get_status' },
              nodePath: { type: 'string', description: 'Path to VideoStreamPlayer node' },
              parentPath: { type: 'string', description: 'Parent node path (for create)' },
              videoPath: { type: 'string', description: 'res:// path to video file' },
              position: { type: 'number', description: 'Seek position in seconds' },
              volume: { type: 'number', description: 'Volume (linear 0-1)' },
              loop: { type: 'boolean', description: 'Enable looping' },
              autoplay: { type: 'boolean', description: 'Auto-play on ready' },
              name: { type: 'string', description: 'Node name (for create)' },
            },
            required: ['action'],
          },
        },
        {
          name: 'manage_ci_pipeline',
          description: 'Create/read GitHub Actions workflow for automated Godot exports',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Absolute path to Godot project' },
              action: { type: 'string', description: 'Action: create or read' },
              platforms: { type: 'array', description: 'Target platforms: windows, linux, macos, web', items: { type: 'string' } },
              godotVersion: { type: 'string', description: 'Godot version (e.g. 4.3-stable)' },
            },
            required: ['projectPath', 'action'],
          },
        },
        {
          name: 'manage_docker_export',
          description: 'Create Dockerfile for headless Godot export',
          inputSchema: {
            type: 'object',
            properties: {
              projectPath: { type: 'string', description: 'Absolute path to Godot project' },
              action: { type: 'string', description: 'Action: create or read' },
              godotVersion: { type: 'string', description: 'Godot version (e.g. 4.3-stable)' },
              exportPreset: { type: 'string', description: 'Export preset name' },
              baseImage: { type: 'string', description: 'Base Docker image (default: ubuntu:22.04)' },
            },
            required: ['projectPath', 'action'],
          },
        },
      // ── Batch & Refactoring ──────────────────────────────────────────────
      {
        name: 'find_nodes_by_type',
        description: 'Find all nodes of a given type/class across all .tscn files in the project.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            nodeType: { type: 'string', description: 'Node type or substring to match (e.g. "Sprite2D")' },
          },
          required: ['projectPath', 'nodeType'],
        },
      },
      {
        name: 'find_signal_connections',
        description: 'Scan all .tscn files for [connection signal=...] lines and return them.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
          },
          required: ['projectPath'],
        },
      },
      {
        name: 'batch_set_property',
        description: 'Set a property on all nodes of a given type in a scene file.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'Relative path to the .tscn file within the project' },
            nodeType: { type: 'string', description: 'Node type to target (e.g. "Label")' },
            propertyKey: { type: 'string', description: 'Property name to set' },
            propertyValue: { type: 'string', description: 'Value to assign to the property' },
          },
          required: ['projectPath', 'scenePath', 'nodeType', 'propertyKey', 'propertyValue'],
        },
      },
      {
        name: 'find_node_references',
        description: 'Find all files referencing a given node name or path string.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            nodeName: { type: 'string', description: 'Node name or path string to search for' },
          },
          required: ['projectPath', 'nodeName'],
        },
      },
      {
        name: 'get_scene_dependencies',
        description: 'Parse a .tscn file\'s [ext_resource lines and return all resource dependencies.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'Relative path to the .tscn file within the project' },
          },
          required: ['projectPath', 'scenePath'],
        },
      },
      {
        name: 'cross_scene_set_property',
        description: 'Like batch_set_property but across ALL .tscn files in project.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            nodeType: { type: 'string', description: 'Node type to target' },
            propertyKey: { type: 'string', description: 'Property name to set' },
            propertyValue: { type: 'string', description: 'Value to assign to the property' },
          },
          required: ['projectPath', 'nodeType', 'propertyKey', 'propertyValue'],
        },
      },
      {
        name: 'find_script_references',
        description: 'Grep all .gd files for a given class name, method name, or string.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            searchTerm: { type: 'string', description: 'Class name, method name, or string to search for' },
          },
          required: ['projectPath', 'searchTerm'],
        },
      },
      {
        name: 'detect_circular_dependencies',
        description: 'Build a dependency graph from .tscn ext_resource entries and detect cycles.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
          },
          required: ['projectPath'],
        },
      },
      // ── Analysis ─────────────────────────────────────────────────────────
      {
        name: 'analyze_scene_complexity',
        description: 'Return complexity metrics for a scene: node count, depth, scripts, signals.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'Relative path to the .tscn file within the project' },
          },
          required: ['projectPath', 'scenePath'],
        },
      },
      {
        name: 'analyze_signal_flow',
        description: 'Parse a scene and return all signal connections as a graph.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'Relative path to the .tscn file within the project' },
          },
          required: ['projectPath', 'scenePath'],
        },
      },
      {
        name: 'find_unused_resources',
        description: 'Find resource files not referenced by any scene or script.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
          },
          required: ['projectPath'],
        },
      },
      {
        name: 'get_project_statistics',
        description: 'Return project-wide stats: scenes, scripts, nodes, lines, plugins.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
          },
          required: ['projectPath'],
        },
      },
      // ── Import Settings ───────────────────────────────────────────────────
      {
        name: 'import_get_config',
        description: 'Read the .import file next to a resource and return it as parsed JSON.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            resourcePath: { type: 'string', description: 'Relative (or absolute) path to the resource file' },
          },
          required: ['projectPath', 'resourcePath'],
        },
      },
      {
        name: 'import_set_config',
        description: 'Write/merge settings into the .import file for a resource.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            resourcePath: { type: 'string', description: 'Relative (or absolute) path to the resource file' },
            settings: { type: 'object', description: 'Key-value pairs to merge into the .import file', additionalProperties: true },
          },
          required: ['projectPath', 'resourcePath', 'settings'],
        },
      },
      {
        name: 'import_list_presets',
        description: 'Scan project for all .import files, group by importer= type, return summary.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
          },
          required: ['projectPath'],
        },
      },
      {
        name: 'import_reimport',
        description: 'Run godot --headless --import to reimport all resources in the project.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
          },
          required: ['projectPath'],
        },
      },
      // ── Script Management ─────────────────────────────────────────────────
      {
        name: 'list_scripts',
        description: 'Recursively list all .gd files in a project.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            includeExternal: { type: 'boolean', description: 'Include scripts outside res:// (default false)' },
          },
          required: ['projectPath'],
        },
      },
      {
        name: 'search_in_files',
        description: 'Grep for a pattern across project files.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            pattern: { type: 'string', description: 'Search pattern (substring)' },
            fileExtensions: { type: 'array', items: { type: 'string' }, description: 'File extensions to search (default: [".gd",".tscn",".tres"])' },
            caseSensitive: { type: 'boolean', description: 'Whether the search is case-sensitive (default true)' },
          },
          required: ['projectPath', 'pattern'],
        },
      },
      {
        name: 'validate_script',
        description: 'Run godot --headless --check-only on a GDScript file to parse-check it.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scriptPath: { type: 'string', description: 'Relative path to the .gd script within the project' },
          },
          required: ['projectPath', 'scriptPath'],
        },
      },
      // ── Scene Extras ──────────────────────────────────────────────────────
      {
        name: 'delete_scene',
        description: 'Delete a .tscn scene file. Refuses if it is the project main scene.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'Relative path to the .tscn file within the project' },
            deleteUidSidecar: { type: 'boolean', description: 'Also delete the .uid sidecar file if it exists (default true)' },
          },
          required: ['projectPath', 'scenePath'],
        },
      },
      {
        name: 'get_scene_file_content',
        description: 'Return the raw text content of a .tscn file.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'Relative path to the .tscn file within the project' },
          },
          required: ['projectPath', 'scenePath'],
        },
      },
      {
        name: 'scene_set_unique_name',
        description: 'Toggle the unique_name_in_owner flag on a node in a .tscn file.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'Relative path to the .tscn file within the project' },
            nodePath: { type: 'string', description: 'Path of the node within the scene (e.g. "Player/Sprite2D")' },
            enabled: { type: 'boolean', description: 'Whether to enable (true) or disable (false) unique_name_in_owner' },
          },
          required: ['projectPath', 'scenePath', 'nodePath', 'enabled'],
        },
      },
      {
        name: 'duplicate_node',
        description: 'Find a node by path in a .tscn file and insert a copy with a new name.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'Relative path to the .tscn file within the project' },
            nodePath: { type: 'string', description: 'Path of the node to duplicate (e.g. "Player/Sprite2D")' },
            newName: { type: 'string', description: 'Name for the duplicated node (default: original name + "_copy")' },
          },
          required: ['projectPath', 'scenePath', 'nodePath'],
        },
      },
      // ── VCS Integration ───────────────────────────────────────────────────
      {
        name: 'vcs_status',
        description: 'Run git status --short in the projectPath and return parsed output.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project (must be a git repo)' },
          },
          required: ['projectPath'],
        },
      },
      {
        name: 'vcs_stage',
        description: 'Run git add on specified files (or "." for all) in the projectPath.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            files: { description: 'Files to stage. Use "." to stage all, or an array of relative paths.', oneOf: [{ type: 'string' }, { type: 'array', items: { type: 'string' } }] },
          },
          required: ['projectPath', 'files'],
        },
      },
      {
        name: 'vcs_commit',
        description: 'Run git commit -m <message> in the projectPath.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            message: { type: 'string', description: 'Commit message' },
          },
          required: ['projectPath', 'message'],
        },
      },
      {
        name: 'vcs_diff',
        description: 'Run git diff [file?] in the projectPath.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            filePath: { type: 'string', description: 'Optional file path to diff (relative to project)' },
          },
          required: ['projectPath'],
        },
      },
      {
        name: 'vcs_branch_list',
        description: 'Run git branch -a in the projectPath and return array of branch names.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
          },
          required: ['projectPath'],
        },
      },
      {
        name: 'vcs_checkout',
        description: 'Run git checkout <branch> in the projectPath.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            branch: { type: 'string', description: 'Branch name to checkout' },
          },
          required: ['projectPath', 'branch'],
        },
      },
      // ── Testing & QA ──────────────────────────────────────────────────────
      {
        name: 'assert_node_state',
        description: 'Get a property from a node at runtime and compare to expectedValue.',
        inputSchema: {
          type: 'object',
          properties: {
            nodePath: { type: 'string', description: 'Node path in the scene tree' },
            property: { type: 'string', description: 'Property name to read' },
            expectedValue: { description: 'Expected value to compare against' },
          },
          required: ['nodePath', 'property', 'expectedValue'],
        },
      },
      {
        name: 'assert_screen_text',
        description: 'Assert that expected text is visible in the running game UI.',
        inputSchema: {
          type: 'object',
          properties: {
            text: { type: 'string', description: 'Text to search for in visible UI nodes' },
          },
          required: ['text'],
        },
      },
      {
        name: 'compare_screenshots',
        description: 'Compare current screenshot to a reference file by hash.',
        inputSchema: {
          type: 'object',
          properties: {
            referencePath: { type: 'string', description: 'Absolute path to the reference screenshot file' },
          },
          required: ['referencePath'],
        },
      },
      {
        name: 'run_stress_test',
        description: 'Run the game for N frames and report FPS and node leaks.',
        inputSchema: {
          type: 'object',
          properties: {
            frames: { type: 'number', description: 'Number of frames to run (default 300)' },
            checkInterval: { type: 'number', description: 'Interval in frames to check for errors (default 60)' },
          },
          required: [],
        },
      },
      // ── AnimationPlayer ───────────────────────────────────────────────────
      {
        name: 'list_animations',
        description: 'Scan a .tscn for AnimationPlayer nodes and return their animation names.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'Relative path to the .tscn file within the project' },
          },
          required: ['projectPath', 'scenePath'],
        },
      },
      {
        name: 'remove_animation',
        description: 'Remove an animation from an AnimationPlayer node in a .tscn file.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'Relative path to the .tscn file within the project' },
            animationPlayerPath: { type: 'string', description: 'Node path of the AnimationPlayer within the scene' },
            animationName: { type: 'string', description: 'Name of the animation to remove' },
          },
          required: ['projectPath', 'scenePath', 'animationPlayerPath', 'animationName'],
        },
      },
      // ── TileSet ───────────────────────────────────────────────────────────
      {
        name: 'tileset_create',
        description: 'Create a new TileSet .tres resource file (uses headless Godot).',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            tilesetPath: { type: 'string', description: 'Relative path within the project for the new TileSet .tres file' },
          },
          required: ['projectPath', 'tilesetPath'],
        },
      },
      {
        name: 'tileset_add_source',
        description: 'Add a TileSetAtlasSource to an existing TileSet .tres (uses headless Godot).',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            tilesetPath: { type: 'string', description: 'Relative path to the existing TileSet .tres file' },
            texturePath: { type: 'string', description: 'res:// path to the atlas texture' },
            tileSize: {
              type: 'object',
              description: 'Tile size in pixels (default: {x:16, y:16})',
              properties: { x: { type: 'number' }, y: { type: 'number' } },
            },
          },
          required: ['projectPath', 'tilesetPath', 'texturePath'],
        },
      },
      // ── SpriteFrames ──────────────────────────────────────────────────────
      {
        name: 'spriteframes_create',
        description: 'Create a SpriteFrames .tres resource file (uses headless Godot).',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            spriteframesPath: { type: 'string', description: 'Relative path within the project for the new SpriteFrames .tres file' },
          },
          required: ['projectPath', 'spriteframesPath'],
        },
      },
      {
        name: 'spriteframes_add_animation',
        description: 'Add an animation to a SpriteFrames resource (uses headless Godot).',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            spriteframesPath: { type: 'string', description: 'Relative path to the SpriteFrames .tres file' },
            animationName: { type: 'string', description: 'Name of the animation to add' },
            fps: { type: 'number', description: 'Frames per second (default 5)' },
            loop: { type: 'boolean', description: 'Whether the animation loops (default true)' },
          },
          required: ['projectPath', 'spriteframesPath', 'animationName'],
        },
      },
      {
        name: 'spriteframes_add_frame',
        description: 'Add a frame (texture) to a SpriteFrames animation (uses headless Godot).',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            spriteframesPath: { type: 'string', description: 'Relative path to the SpriteFrames .tres file' },
            animationName: { type: 'string', description: 'Name of the animation to add the frame to' },
            texturePath: { type: 'string', description: 'res:// path to the frame texture' },
            duration: { type: 'number', description: 'Frame duration multiplier (default 1.0)' },
          },
          required: ['projectPath', 'spriteframesPath', 'animationName', 'texturePath'],
        },
      },
      // ── Runtime Game Tools ────────────────────────────────────────────────
      {
        name: 'find_nodes_by_script',
        description: 'Find all nodes in the running game using a given script.',
        inputSchema: {
          type: 'object',
          properties: {
            scriptPath: { type: 'string', description: 'res:// path to the script' },
            partial: { type: 'boolean', description: 'Allow partial path match (default true)' },
          },
          required: ['scriptPath'],
        },
      },
      {
        name: 'batch_get_properties',
        description: 'Get multiple properties from multiple nodes at once.',
        inputSchema: {
          type: 'object',
          properties: {
            queries: {
              type: 'array',
              description: 'Array of {nodePath, properties[]} objects',
              items: {
                type: 'object',
                properties: {
                  nodePath: { type: 'string' },
                  properties: { type: 'array', items: { type: 'string' } },
                },
                required: ['nodePath', 'properties'],
              },
            },
          },
          required: ['queries'],
        },
      },
      {
        name: 'click_button_by_text',
        description: 'Find and click a Button node by its text label.',
        inputSchema: {
          type: 'object',
          properties: {
            text: { type: 'string', description: 'Button label text to match' },
            exact: { type: 'boolean', description: 'Exact match (default false)' },
          },
          required: ['text'],
        },
      },
      {
        name: 'wait_for_node',
        description: 'Wait until a node path exists in the scene tree.',
        inputSchema: {
          type: 'object',
          properties: {
            nodePath: { type: 'string', description: 'Scene tree path to wait for' },
            timeoutMs: { type: 'number', description: 'Timeout in ms (default 5000)' },
          },
          required: ['nodePath'],
        },
      },
      {
        name: 'find_nearby_nodes',
        description: 'Find nodes within a radius of a 2D/3D world position.',
        inputSchema: {
          type: 'object',
          properties: {
            position: {
              type: 'object',
              description: 'World position {x, y, z?}',
              properties: {
                x: { type: 'number' },
                y: { type: 'number' },
                z: { type: 'number' },
              },
              required: ['x', 'y'],
            },
            radius: { type: 'number', description: 'Search radius in world units' },
            nodeType: { type: 'string', description: 'Optional node type filter' },
          },
          required: ['position', 'radius'],
        },
      },
      {
        name: 'capture_frames',
        description: 'Capture N screenshots over successive game frames.',
        inputSchema: {
          type: 'object',
          properties: {
            count: { type: 'number', description: 'Number of screenshots (default 5)' },
            intervalFrames: { type: 'number', description: 'Frames between shots (default 10)' },
          },
        },
      },
      {
        name: 'monitor_properties',
        description: 'Record node property values over N frames for analysis.',
        inputSchema: {
          type: 'object',
          properties: {
            queries: {
              type: 'array',
              description: 'Array of {nodePath, property} objects',
              items: {
                type: 'object',
                properties: {
                  nodePath: { type: 'string' },
                  property: { type: 'string' },
                },
                required: ['nodePath', 'property'],
              },
            },
            frames: { type: 'number', description: 'Number of frames to record (default 60)' },
            intervalFrames: { type: 'number', description: 'Frames between samples (default 1)' },
          },
          required: ['queries'],
        },
      },
      {
        name: 'start_recording',
        description: 'Start recording input events for later replay.',
        inputSchema: { type: 'object', properties: {} },
      },
      {
        name: 'stop_recording',
        description: 'Stop input recording and return the event sequence.',
        inputSchema: { type: 'object', properties: {} },
      },
      {
        name: 'replay_recording',
        description: 'Replay a recorded input sequence in the running game.',
        inputSchema: {
          type: 'object',
          properties: {
            events: { type: 'array', description: 'Array of recorded event objects', items: { type: 'object' } },
            speedScale: { type: 'number', description: 'Playback speed multiplier (default 1.0)' },
          },
          required: ['events'],
        },
      },
      // ── AnimationTree State Machine ────────────────────────────────────────
      {
        name: 'animtree_add_state',
        description: 'Add a state to an AnimationStateMachine at runtime.',
        inputSchema: {
          type: 'object',
          properties: {
            nodePath: { type: 'string', description: 'Path to AnimationTree node' },
            stateName: { type: 'string', description: 'Name for the new state' },
            animationName: { type: 'string', description: 'Animation to play in this state' },
          },
          required: ['nodePath', 'stateName', 'animationName'],
        },
      },
      {
        name: 'animtree_remove_state',
        description: 'Remove a state from an AnimationStateMachine at runtime.',
        inputSchema: {
          type: 'object',
          properties: {
            nodePath: { type: 'string', description: 'Path to AnimationTree node' },
            stateName: { type: 'string', description: 'State name to remove' },
          },
          required: ['nodePath', 'stateName'],
        },
      },
      {
        name: 'animtree_add_transition',
        description: 'Add a transition between two AnimationStateMachine states.',
        inputSchema: {
          type: 'object',
          properties: {
            nodePath: { type: 'string', description: 'Path to AnimationTree node' },
            fromState: { type: 'string', description: 'Source state name' },
            toState: { type: 'string', description: 'Target state name' },
            switchMode: {
              type: 'string',
              enum: ['immediate', 'sync', 'at_end'],
              description: 'Transition switch mode',
            },
          },
          required: ['nodePath', 'fromState', 'toState'],
        },
      },
      {
        name: 'animtree_remove_transition',
        description: 'Remove a transition between two AnimationStateMachine states.',
        inputSchema: {
          type: 'object',
          properties: {
            nodePath: { type: 'string', description: 'Path to AnimationTree node' },
            fromState: { type: 'string', description: 'Source state name' },
            toState: { type: 'string', description: 'Target state name' },
          },
          required: ['nodePath', 'fromState', 'toState'],
        },
      },
      {
        name: 'animtree_get_structure',
        description: 'Get the full AnimationStateMachine state graph structure.',
        inputSchema: {
          type: 'object',
          properties: {
            nodePath: { type: 'string', description: 'Path to AnimationTree node' },
          },
          required: ['nodePath'],
        },
      },
      // ── Soft Debugger ─────────────────────────────────────────────────────
      {
        name: 'debugger_set_breakpoint',
        description: 'Inject or remove a GDScript breakpoint at a file line.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scriptPath: { type: 'string', description: 'res:// or relative path to .gd file' },
            line: { type: 'number', description: '1-based line number' },
            enabled: { type: 'boolean', description: 'True to inject, false to remove (default true)' },
          },
          required: ['projectPath', 'scriptPath', 'line'],
        },
      },
      {
        name: 'debugger_list_breakpoints',
        description: 'List all MCP-injected breakpoints in the project.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
          },
          required: ['projectPath'],
        },
      },
      {
        name: 'debugger_get_stack',
        description: 'Get the current call stack from the running game.',
        inputSchema: { type: 'object', properties: {} },
      },
      {
        name: 'debugger_evaluate',
        description: 'Evaluate a GDScript expression in the running game context.',
        inputSchema: {
          type: 'object',
          properties: {
            expression: { type: 'string', description: 'GDScript expression to evaluate' },
          },
          required: ['expression'],
        },
      },
      // ── Headless Scene Extras ─────────────────────────────────────────────
      {
        name: 'add_scene_instance',
        description: 'Add a PackedScene instance to a scene file.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            parentScenePath: { type: 'string', description: 'res:// path to parent .tscn file' },
            packedScenePath: { type: 'string', description: 'res:// path to the PackedScene' },
            instanceName: { type: 'string', description: 'Optional name for the new instance' },
            parentNodePath: { type: 'string', description: 'Node path in scene (default root)' },
          },
          required: ['projectPath', 'parentScenePath', 'packedScenePath'],
        },
      },
      {
        name: 'move_node',
        description: 'Change a node sibling index in a .tscn file.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'res:// path to .tscn file' },
            nodePath: { type: 'string', description: 'Full scene-tree path of node to move' },
            newIndex: { type: 'number', description: 'New 0-based sibling index' },
          },
          required: ['projectPath', 'scenePath', 'nodePath', 'newIndex'],
        },
      },
      {
        name: 'get_node_groups',
        description: 'Get the groups assigned to a node in a scene file.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'res:// path to .tscn file' },
            nodePath: { type: 'string', description: 'Full scene-tree path of the node' },
          },
          required: ['projectPath', 'scenePath', 'nodePath'],
        },
      },
      {
        name: 'set_node_groups',
        description: 'Set the groups for a node in a scene file.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'res:// path to .tscn file' },
            nodePath: { type: 'string', description: 'Full scene-tree path of the node' },
            groups: { type: 'array', items: { type: 'string' }, description: 'Group names to assign' },
          },
          required: ['projectPath', 'scenePath', 'nodePath', 'groups'],
        },
      },
      {
        name: 'find_nodes_in_group',
        description: 'Find all nodes in a scene file belonging to a group.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'res:// path to .tscn file' },
            group: { type: 'string', description: 'Group name to search for' },
          },
          required: ['projectPath', 'scenePath', 'group'],
        },
      },
      {
        name: 'scene_create_inherited',
        description: 'Create an inherited .tscn scene that extends a base scene.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            baseScenePath: { type: 'string', description: 'res:// path to base scene' },
            newScenePath: { type: 'string', description: 'res:// path for the new inherited scene' },
          },
          required: ['projectPath', 'baseScenePath', 'newScenePath'],
        },
      },
      {
        name: 'add_autoload',
        description: 'Add an autoload singleton to the project.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            name: { type: 'string', description: 'Autoload singleton name' },
            path: { type: 'string', description: 'res:// path to script or scene' },
          },
          required: ['projectPath', 'name', 'path'],
        },
      },
      {
        name: 'remove_autoload',
        description: 'Remove an autoload singleton from the project.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            name: { type: 'string', description: 'Autoload singleton name to remove' },
          },
          required: ['projectPath', 'name'],
        },
      },
      // ── Resource Creation ─────────────────────────────────────────────────
      {
        name: 'curve_create',
        description: 'Create a Curve .tres resource with specified control points.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            curvePath: { type: 'string', description: 'res:// path for the new Curve .tres' },
            points: {
              type: 'array',
              description: 'Control points [{x, y, leftTangent?, rightTangent?}]',
              items: {
                type: 'object',
                properties: {
                  x: { type: 'number' },
                  y: { type: 'number' },
                  leftTangent: { type: 'number' },
                  rightTangent: { type: 'number' },
                },
                required: ['x', 'y'],
              },
            },
          },
          required: ['projectPath', 'curvePath', 'points'],
        },
      },
      {
        name: 'gradient_create',
        description: 'Create a Gradient .tres resource with colors and offsets.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            gradientPath: { type: 'string', description: 'res:// path for the new Gradient .tres' },
            colors: {
              type: 'array',
              description: 'Array of {r, g, b, a} color stops',
              items: {
                type: 'object',
                properties: {
                  r: { type: 'number' },
                  g: { type: 'number' },
                  b: { type: 'number' },
                  a: { type: 'number' },
                },
                required: ['r', 'g', 'b'],
              },
            },
            offsets: { type: 'array', items: { type: 'number' }, description: 'Per-color offset values [0..1]' },
          },
          required: ['projectPath', 'gradientPath', 'colors', 'offsets'],
        },
      },
      // ── Editor Tools ──────────────────────────────────────────────────────
      {
        name: 'open_scene',
        description: 'Launch the Godot editor with a specific scene open.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'res:// path to scene to open in editor' },
          },
          required: ['projectPath', 'scenePath'],
        },
      },
      {
        name: 'gdextension_list',
        description: 'List all GDExtension library files in the project.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
          },
          required: ['projectPath'],
        },
      },
      // ── Node Transform / Order ─────────────────────────────────────────────
      {
        name: 'reorder_node',
        description: 'Move a node up or down among its siblings in a scene.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'Scene path (res:// or absolute)' },
            nodeName: { type: 'string', description: 'Name of the node to reorder' },
            direction: { type: 'string', enum: ['up', 'down'], description: "'up' or 'down'" },
          },
          required: ['projectPath', 'scenePath', 'nodeName', 'direction'],
        },
      },
      {
        name: 'get_node_transform',
        description: 'Get position, rotation, and scale of a node in a scene.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'Scene path (res:// or absolute)' },
            nodeName: { type: 'string', description: 'Name of the node' },
          },
          required: ['projectPath', 'scenePath', 'nodeName'],
        },
      },
      {
        name: 'set_node_transform',
        description: 'Set position, rotation, or scale of a node in a scene.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'Scene path (res:// or absolute)' },
            nodeName: { type: 'string', description: 'Name of the node' },
            position: { type: 'object', description: '{x, y} or {x, y, z}' },
            rotation: { type: 'number', description: 'Rotation in radians' },
            scale: { type: 'object', description: '{x, y} or {x, y, z}' },
          },
          required: ['projectPath', 'scenePath', 'nodeName'],
        },
      },
      // ── Groups ─────────────────────────────────────────────────────────────
      {
        name: 'list_all_groups',
        description: 'List all node groups used across all scenes in the project.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
          },
          required: ['projectPath'],
        },
      },
      {
        name: 'add_node_to_group',
        description: 'Add a node to a group in a scene file.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'Scene path (res:// or absolute)' },
            nodeName: { type: 'string', description: 'Name of the node' },
            groupName: { type: 'string', description: 'Group name to add' },
          },
          required: ['projectPath', 'scenePath', 'nodeName', 'groupName'],
        },
      },
      {
        name: 'remove_node_from_group',
        description: 'Remove a node from a group in a scene file.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'Scene path (res:// or absolute)' },
            nodeName: { type: 'string', description: 'Name of the node' },
            groupName: { type: 'string', description: 'Group name to remove' },
          },
          required: ['projectPath', 'scenePath', 'nodeName', 'groupName'],
        },
      },
      // ── Plugins ────────────────────────────────────────────────────────────
      {
        name: 'plugin_list',
        description: 'List all plugins in the project and their enabled state.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
          },
          required: ['projectPath'],
        },
      },
      {
        name: 'plugin_enable',
        description: 'Enable a plugin in project.godot by its addons/ path.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            pluginPath: { type: 'string', description: 'e.g. res://addons/my_plugin/plugin.cfg' },
          },
          required: ['projectPath', 'pluginPath'],
        },
      },
      {
        name: 'plugin_disable',
        description: 'Disable a plugin in project.godot by its addons/ path.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            pluginPath: { type: 'string', description: 'e.g. res://addons/my_plugin/plugin.cfg' },
          },
          required: ['projectPath', 'pluginPath'],
        },
      },
      // ── Assets ─────────────────────────────────────────────────────────────
      {
        name: 'shader_create',
        description: 'Create a new .gdshader file with a template for a shader type.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            shaderPath: { type: 'string', description: 'Output path (res:// or absolute)' },
            shaderType: { type: 'string', enum: ['canvas_item', 'spatial', 'particles'], description: 'Shader type (default: canvas_item)' },
            overwrite: { type: 'boolean', description: 'Overwrite if file exists' },
          },
          required: ['projectPath', 'shaderPath'],
        },
      },
      {
        name: 'material_create',
        description: 'Create a new StandardMaterial3D or CanvasItemMaterial .tres file.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            materialPath: { type: 'string', description: 'Output path (res:// or absolute)' },
            materialType: { type: 'string', enum: ['StandardMaterial3D', 'CanvasItemMaterial', 'ShaderMaterial'], description: 'Material type (default: StandardMaterial3D)' },
            overwrite: { type: 'boolean', description: 'Overwrite if file exists' },
          },
          required: ['projectPath', 'materialPath'],
        },
      },
      {
        name: 'script_template',
        description: 'Generate a GDScript template file for a Godot base class.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scriptPath: { type: 'string', description: 'Output path (res:// or absolute)' },
            baseClass: { type: 'string', description: 'Godot base class e.g. CharacterBody2D' },
            className: { type: 'string', description: 'Optional class_name declaration' },
            overwrite: { type: 'boolean', description: 'Overwrite if file exists' },
          },
          required: ['projectPath', 'scriptPath', 'baseClass'],
        },
      },
      // ── Export ─────────────────────────────────────────────────────────────
      {
        name: 'export_list_presets',
        description: 'List all export presets defined in export_presets.cfg.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
          },
          required: ['projectPath'],
        },
      },
      {
        name: 'export_project',
        description: 'Export the project using a named export preset.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            presetName: { type: 'string', description: 'Name of the export preset to use' },
            outputPath: { type: 'string', description: 'Absolute path for the exported file' },
            debug: { type: 'boolean', description: 'Use debug export (default: false)' },
          },
          required: ['projectPath', 'presetName', 'outputPath'],
        },
      },
      // ── TileMap (runtime) ──────────────────────────────────────────────────
      {
        name: 'tilemap_set_cell',
        description: 'Set a cell in a TileMap node in the running game.',
        inputSchema: {
          type: 'object',
          properties: {
            nodePath: { type: 'string', description: 'Scene-tree path to the TileMap node' },
            layer: { type: 'number', description: 'TileMap layer index (default 0)' },
            x: { type: 'number', description: 'Cell X coordinate' },
            y: { type: 'number', description: 'Cell Y coordinate' },
            sourceId: { type: 'number', description: 'Tile source ID' },
            atlasCoordsX: { type: 'number', description: 'Atlas X coord (default 0)' },
            atlasCoordsY: { type: 'number', description: 'Atlas Y coord (default 0)' },
            alternativeTile: { type: 'number', description: 'Alternative tile index (default 0)' },
          },
          required: ['nodePath', 'x', 'y', 'sourceId'],
        },
      },
      {
        name: 'tilemap_get_used_cells',
        description: 'Get all used cell coords in a TileMap layer in the running game.',
        inputSchema: {
          type: 'object',
          properties: {
            nodePath: { type: 'string', description: 'Scene-tree path to the TileMap node' },
            layer: { type: 'number', description: 'TileMap layer index (default 0)' },
          },
          required: ['nodePath'],
        },
      },
      {
        name: 'tilemap_clear',
        description: 'Clear all cells in a TileMap layer in the running game.',
        inputSchema: {
          type: 'object',
          properties: {
            nodePath: { type: 'string', description: 'Scene-tree path to the TileMap node' },
            layer: { type: 'number', description: 'TileMap layer index (default 0)' },
          },
          required: ['nodePath'],
        },
      },
      // ── Audio Bus (runtime) ────────────────────────────────────────────────
      {
        name: 'audio_bus_list',
        description: 'List all audio buses with their volume and effects.',
        inputSchema: {
          type: 'object',
          properties: {},
          required: [],
        },
      },
      {
        name: 'audio_bus_create',
        description: 'Create a new audio bus in the AudioServer.',
        inputSchema: {
          type: 'object',
          properties: {
            busName: { type: 'string', description: 'Name for the new audio bus' },
          },
          required: ['busName'],
        },
      },
      {
        name: 'audio_bus_set_volume',
        description: 'Set the volume of an audio bus in dB.',
        inputSchema: {
          type: 'object',
          properties: {
            busName: { type: 'string', description: 'Name of the audio bus' },
            volumeDb: { type: 'number', description: 'Volume in decibels' },
          },
          required: ['busName', 'volumeDb'],
        },
      },
      {
        name: 'audio_bus_add_effect',
        description: 'Add an audio effect to a bus by effect type name.',
        inputSchema: {
          type: 'object',
          properties: {
            busName: { type: 'string', description: 'Name of the audio bus' },
            effectType: { type: 'string', description: 'e.g. AudioEffectReverb' },
            effectParams: { type: 'object', description: 'Optional effect parameters' },
          },
          required: ['busName', 'effectType'],
        },
      },
      // ── Performance / Batch (runtime) ──────────────────────────────────────
      {
        name: 'get_performance_counters',
        description: 'Get all performance monitor counter values from the game.',
        inputSchema: {
          type: 'object',
          properties: {
            counterNames: { type: 'array', items: { type: 'string' }, description: 'Optional list of specific counter names' },
          },
          required: [],
        },
      },
      {
        name: 'batch_set_properties',
        description: 'Set multiple properties on multiple nodes in one call.',
        inputSchema: {
          type: 'object',
          properties: {
            operations: {
              type: 'array',
              description: 'Array of {nodePath, property, value} operations',
              items: {
                type: 'object',
                properties: {
                  nodePath: { type: 'string' },
                  property: { type: 'string' },
                  value: {},
                },
                required: ['nodePath', 'property', 'value'],
              },
            },
          },
          required: ['operations'],
        },
      },
      // ── Class API / Scene Info ─────────────────────────────────────────────
      {
        name: 'get_class_api',
        description: 'Get methods, properties, and signals of a Godot class.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            className: { type: 'string', description: 'Godot class name e.g. Node2D' },
          },
          required: ['projectPath', 'className'],
        },
      },
      {
        name: 'scene_node_count',
        description: 'Count the number of nodes in a scene file.',
        inputSchema: {
          type: 'object',
          properties: {
            projectPath: { type: 'string', description: 'Absolute path to Godot project' },
            scenePath: { type: 'string', description: 'Scene path (res:// or absolute)' },
          },
          required: ['projectPath', 'scenePath'],
        },
      },
      ],
    }));

    // Handle tool calls
    this.server.setRequestHandler(CallToolRequestSchema, async (request) => {
      this.logDebug(`Handling tool request: ${request.params.name}`);
      switch (request.params.name) {
        case 'launch_editor':
          return await this.handleLaunchEditor(request.params.arguments);
        case 'run_project':
          return await this.handleRunProject(request.params.arguments);
        case 'get_debug_output':
          return await this.handleGetDebugOutput();
        case 'stop_project':
          return await this.handleStopProject();
        case 'get_godot_version':
          return await this.handleGetGodotVersion();
        case 'list_projects':
          return await this.handleListProjects(request.params.arguments);
        case 'get_project_info':
          return await this.handleGetProjectInfo(request.params.arguments);
        case 'create_scene':
          return await this.handleCreateScene(request.params.arguments);
        case 'add_node':
          return await this.handleAddNode(request.params.arguments);
        case 'load_sprite':
          return await this.handleLoadSprite(request.params.arguments);
        case 'export_mesh_library':
          return await this.handleExportMeshLibrary(request.params.arguments);
        case 'save_scene':
          return await this.handleSaveScene(request.params.arguments);
        case 'get_uid':
          return await this.handleGetUid(request.params.arguments);
        case 'update_project_uids':
          return await this.handleUpdateProjectUids(request.params.arguments);
        case 'game_screenshot':
          return await this.handleGameScreenshot();
        case 'game_click':
          return await this.handleGameClick(request.params.arguments);
        case 'game_key_press':
          return await this.handleGameKeyPress(request.params.arguments);
        case 'game_mouse_move':
          return await this.handleGameMouseMove(request.params.arguments);
        case 'game_get_ui':
          return await this.handleGameGetUi();
        case 'game_get_scene_tree':
          return await this.handleGameGetSceneTree();
        // New runtime interaction tools
        case 'game_eval':
          return await this.handleGameEval(request.params.arguments);
        case 'game_get_property':
          return await this.handleGameGetProperty(request.params.arguments);
        case 'game_set_property':
          return await this.handleGameSetProperty(request.params.arguments);
        case 'game_call_method':
          return await this.handleGameCallMethod(request.params.arguments);
        case 'game_get_node_info':
          return await this.handleGameGetNodeInfo(request.params.arguments);
        case 'game_instantiate_scene':
          return await this.handleGameInstantiateScene(request.params.arguments);
        case 'game_remove_node':
          return await this.handleGameRemoveNode(request.params.arguments);
        case 'game_change_scene':
          return await this.handleGameChangeScene(request.params.arguments);
        case 'game_pause':
          return await this.handleGamePause(request.params.arguments);
        case 'game_performance':
          return await this.handleGamePerformance();
        case 'game_wait':
          return await this.handleGameWait(request.params.arguments);
        // Headless scene tools
        case 'read_scene':
          return await this.handleReadScene(request.params.arguments);
        case 'modify_scene_node':
          return await this.handleModifySceneNode(request.params.arguments);
        case 'remove_scene_node':
          return await this.handleRemoveSceneNode(request.params.arguments);
        // Project management tools
        case 'read_project_settings':
          return await this.handleReadProjectSettings(request.params.arguments);
        case 'modify_project_settings':
          return await this.handleModifyProjectSettings(request.params.arguments);
        case 'list_project_files':
          return await this.handleListProjectFiles(request.params.arguments);
        // New runtime signal/animation/group tools
        case 'game_connect_signal':
          return await this.handleGameConnectSignal(request.params.arguments);
        case 'game_disconnect_signal':
          return await this.handleGameDisconnectSignal(request.params.arguments);
        case 'game_emit_signal':
          return await this.handleGameEmitSignal(request.params.arguments);
        case 'game_play_animation':
          return await this.handleGamePlayAnimation(request.params.arguments);
        case 'game_tween_property':
          return await this.handleGameTweenProperty(request.params.arguments);
        case 'game_get_nodes_in_group':
          return await this.handleGameGetNodesInGroup(request.params.arguments);
        case 'game_find_nodes_by_class':
          return await this.handleGameFindNodesByClass(request.params.arguments);
        case 'game_reparent_node':
          return await this.handleGameReparentNode(request.params.arguments);
        // Headless resource tools
        case 'attach_script':
          return await this.handleAttachScript(request.params.arguments);
        case 'create_resource':
          return await this.handleCreateResource(request.params.arguments);
        // File I/O tools
        case 'read_file':
          return await this.handleReadFile(request.params.arguments);
        case 'write_file':
          return await this.handleWriteFile(request.params.arguments);
        case 'delete_file':
          return await this.handleDeleteFile(request.params.arguments);
        case 'create_directory':
          return await this.handleCreateDirectory(request.params.arguments);
        // Error/Log capture tools
        case 'game_get_errors':
          return await this.handleGameGetErrors();
        case 'game_get_logs':
          return await this.handleGameGetLogs();
        // Enhanced input tools
        case 'game_key_hold':
          return await this.handleGameKeyHold(request.params.arguments);
        case 'game_key_release':
          return await this.handleGameKeyRelease(request.params.arguments);
        case 'game_scroll':
          return await this.handleGameScroll(request.params.arguments);
        case 'game_mouse_drag':
          return await this.handleGameMouseDrag(request.params.arguments);
        case 'game_gamepad':
          return await this.handleGameGamepad(request.params.arguments);
        // Project management tools
        case 'create_project':
          return await this.handleCreateProject(request.params.arguments);
        case 'manage_autoloads':
          return await this.handleManageAutoloads(request.params.arguments);
        case 'manage_input_map':
          return await this.handleManageInputMap(request.params.arguments);
        case 'manage_export_presets':
          return await this.handleManageExportPresets(request.params.arguments);
        // Advanced runtime tools
        case 'game_get_camera':
          return await this.handleGameGetCamera();
        case 'game_set_camera':
          return await this.handleGameSetCamera(request.params.arguments);
        case 'game_raycast':
          return await this.handleGameRaycast(request.params.arguments);
        case 'game_get_audio':
          return await this.handleGameGetAudio();
        case 'game_spawn_node':
          return await this.handleGameSpawnNode(request.params.arguments);
        // Shader, audio, navigation, tilemap, collision, environment tools
        case 'game_set_shader_param':
          return await this.handleGameSetShaderParam(request.params.arguments);
        case 'game_audio_play':
          return await this.handleGameAudioPlay(request.params.arguments);
        case 'game_audio_bus':
          return await this.handleGameAudioBus(request.params.arguments);
        case 'game_navigate_path':
          return await this.handleGameNavigatePath(request.params.arguments);
        case 'game_tilemap':
          return await this.handleGameTilemap(request.params.arguments);
        case 'game_add_collision':
          return await this.handleGameAddCollision(request.params.arguments);
        case 'game_environment':
          return await this.handleGameEnvironment(request.params.arguments);
        // Group, timer, particles, animation, export, state, physics, joint, bone, theme, viewport, debug
        case 'game_manage_group':
          return await this.handleGameManageGroup(request.params.arguments);
        case 'game_create_timer':
          return await this.handleGameCreateTimer(request.params.arguments);
        case 'game_set_particles':
          return await this.handleGameSetParticles(request.params.arguments);
        case 'game_create_animation':
          return await this.handleGameCreateAnimation(request.params.arguments);
        case 'export_project':
          return await this.handleExportProject(request.params.arguments);
        case 'game_serialize_state':
          return await this.handleGameSerializeState(request.params.arguments);
        case 'game_physics_body':
          return await this.handleGamePhysicsBody(request.params.arguments);
        case 'game_create_joint':
          return await this.handleGameCreateJoint(request.params.arguments);
        case 'game_bone_pose':
          return await this.handleGameBonePose(request.params.arguments);
        case 'game_ui_theme':
          return await this.handleGameUiTheme(request.params.arguments);
        case 'game_viewport':
          return await this.handleGameViewport(request.params.arguments);
        case 'game_debug_draw':
          return await this.handleGameDebugDraw(request.params.arguments);
        // Batch 1: Networking + Input + System + Signals + Script
        case 'game_http_request':
          return await this.handleGameHttpRequest(request.params.arguments);
        case 'game_websocket':
          return await this.handleGameWebsocket(request.params.arguments);
        case 'game_multiplayer':
          return await this.handleGameMultiplayer(request.params.arguments);
        case 'game_rpc':
          return await this.handleGameRpc(request.params.arguments);
        case 'game_touch':
          return await this.handleGameTouch(request.params.arguments);
        case 'game_input_state':
          return await this.handleGameInputState(request.params.arguments);
        case 'game_input_action':
          return await this.handleGameInputAction(request.params.arguments);
        case 'game_list_signals':
          return await this.handleGameListSignals(request.params.arguments);
        case 'game_await_signal':
          return await this.handleGameAwaitSignal(request.params.arguments);
        case 'game_script':
          return await this.handleGameScript(request.params.arguments);
        case 'game_window':
          return await this.handleGameWindow(request.params.arguments);
        case 'game_os_info':
          return await this.handleGameOsInfo(request.params.arguments);
        case 'game_time_scale':
          return await this.handleGameTimeScale(request.params.arguments);
        case 'game_process_mode':
          return await this.handleGameProcessMode(request.params.arguments);
        case 'game_world_settings':
          return await this.handleGameWorldSettings(request.params.arguments);
        // Batch 2: 3D Rendering + Lighting + Sky + Physics
        case 'game_csg':
          return await this.handleGameCsg(request.params.arguments);
        case 'game_multimesh':
          return await this.handleGameMultimesh(request.params.arguments);
        case 'game_procedural_mesh':
          return await this.handleGameProceduralMesh(request.params.arguments);
        case 'game_light_3d':
          return await this.handleGameLight3d(request.params.arguments);
        case 'game_mesh_instance':
          return await this.handleGameMeshInstance(request.params.arguments);
        case 'game_gridmap':
          return await this.handleGameGridmap(request.params.arguments);
        case 'game_3d_effects':
          return await this.handleGame3dEffects(request.params.arguments);
        case 'game_gi':
          return await this.handleGameGi(request.params.arguments);
        case 'game_path_3d':
          return await this.handleGamePath3d(request.params.arguments);
        case 'game_sky':
          return await this.handleGameSky(request.params.arguments);
        case 'game_camera_attributes':
          return await this.handleGameCameraAttributes(request.params.arguments);
        case 'game_navigation_3d':
          return await this.handleGameNavigation3d(request.params.arguments);
        case 'game_physics_3d':
          return await this.handleGamePhysics3d(request.params.arguments);
        // Batch 3: 2D Systems + Animation Advanced + Audio Effects
        case 'game_canvas':
          return await this.handleGameCanvas(request.params.arguments);
        case 'game_canvas_draw':
          return await this.handleGameCanvasDraw(request.params.arguments);
        case 'game_light_2d':
          return await this.handleGameLight2d(request.params.arguments);
        case 'game_parallax':
          return await this.handleGameParallax(request.params.arguments);
        case 'game_shape_2d':
          return await this.handleGameShape2d(request.params.arguments);
        case 'game_path_2d':
          return await this.handleGamePath2d(request.params.arguments);
        case 'game_physics_2d':
          return await this.handleGamePhysics2d(request.params.arguments);
        case 'game_animation_tree':
          return await this.handleGameAnimationTree(request.params.arguments);
        case 'game_animation_control':
          return await this.handleGameAnimationControl(request.params.arguments);
        case 'game_skeleton_ik':
          return await this.handleGameSkeletonIk(request.params.arguments);
        case 'game_audio_effect':
          return await this.handleGameAudioEffect(request.params.arguments);
        case 'game_audio_bus_layout':
          return await this.handleGameAudioBusLayout(request.params.arguments);
        case 'game_audio_spatial':
          return await this.handleGameAudioSpatial(request.params.arguments);
        // Batch 4: Editor/Headless + Localization + Resource
        case 'rename_file':
          return await this.handleRenameFile(request.params.arguments);
        case 'manage_resource':
          return await this.handleManageResource(request.params.arguments);
        case 'create_script':
          return await this.handleCreateScript(request.params.arguments);
        case 'manage_scene_signals':
          return await this.handleManageSceneSignals(request.params.arguments);
        case 'manage_layers':
          return await this.handleManageLayers(request.params.arguments);
        case 'manage_plugins':
          return await this.handleManagePlugins(request.params.arguments);
        case 'manage_shader':
          return await this.handleManageShader(request.params.arguments);
        case 'manage_theme_resource':
          return await this.handleManageThemeResource(request.params.arguments);
        case 'set_main_scene':
          return await this.handleSetMainScene(request.params.arguments);
        case 'manage_scene_structure':
          return await this.handleManageSceneStructure(request.params.arguments);
        case 'manage_translations':
          return await this.handleManageTranslations(request.params.arguments);
        case 'game_locale':
          return await this.handleGameLocale(request.params.arguments);
        // Batch 5: UI Controls + Rendering + Resource Runtime
        case 'game_ui_control':
          return await this.handleGameUiControl(request.params.arguments);
        case 'game_ui_text':
          return await this.handleGameUiText(request.params.arguments);
        case 'game_ui_popup':
          return await this.handleGameUiPopup(request.params.arguments);
        case 'game_ui_tree':
          return await this.handleGameUiTree(request.params.arguments);
        case 'game_ui_item_list':
          return await this.handleGameUiItemList(request.params.arguments);
        case 'game_ui_tabs':
          return await this.handleGameUiTabs(request.params.arguments);
        case 'game_ui_menu':
          return await this.handleGameUiMenu(request.params.arguments);
        case 'game_ui_range':
          return await this.handleGameUiRange(request.params.arguments);
        case 'game_render_settings':
          return await this.handleGameRenderSettings(request.params.arguments);
        case 'game_resource':
          return await this.handleGameResource(request.params.arguments);
        // Batch 6: Visual Shader + Terrain + Video + CI/CD
        case 'game_visual_shader':
          return await this.handleGameVisualShader(request.params.arguments);
        case 'game_terrain':
          return await this.handleGameTerrain(request.params.arguments);
        case 'game_video':
          return await this.handleGameVideo(request.params.arguments);
        case 'manage_ci_pipeline':
          return await this.handleManageCiPipeline(request.params.arguments);
        case 'manage_docker_export':
          return await this.handleManageDockerExport(request.params.arguments);
        // ── Batch & Refactoring ──────────────────────────────────────────
        case 'find_nodes_by_type':
          return await this.handleFindNodesByType(request.params.arguments);
        case 'find_signal_connections':
          return await this.handleFindSignalConnections(request.params.arguments);
        case 'batch_set_property':
          return await this.handleBatchSetProperty(request.params.arguments);
        case 'find_node_references':
          return await this.handleFindNodeReferences(request.params.arguments);
        case 'get_scene_dependencies':
          return await this.handleGetSceneDependencies(request.params.arguments);
        case 'cross_scene_set_property':
          return await this.handleCrossSceneSetProperty(request.params.arguments);
        case 'find_script_references':
          return await this.handleFindScriptReferences(request.params.arguments);
        case 'detect_circular_dependencies':
          return await this.handleDetectCircularDependencies(request.params.arguments);
        // ── Analysis ─────────────────────────────────────────────────────
        case 'analyze_scene_complexity':
          return await this.handleAnalyzeSceneComplexity(request.params.arguments);
        case 'analyze_signal_flow':
          return await this.handleAnalyzeSignalFlow(request.params.arguments);
        case 'find_unused_resources':
          return await this.handleFindUnusedResources(request.params.arguments);
        case 'get_project_statistics':
          return await this.handleGetProjectStatistics(request.params.arguments);
        // ── Import Settings ───────────────────────────────────────────────
        case 'import_get_config':
          return await this.handleImportGetConfig(request.params.arguments);
        case 'import_set_config':
          return await this.handleImportSetConfig(request.params.arguments);
        case 'import_list_presets':
          return await this.handleImportListPresets(request.params.arguments);
        case 'import_reimport':
          return await this.handleImportReiimport(request.params.arguments);
        // ── Script Management ─────────────────────────────────────────────
        case 'list_scripts':
          return await this.handleListScripts(request.params.arguments);
        case 'search_in_files':
          return await this.handleSearchInFiles(request.params.arguments);
        case 'validate_script':
          return await this.handleValidateScript(request.params.arguments);
        // ── Scene Extras ──────────────────────────────────────────────────
        case 'delete_scene':
          return await this.handleDeleteScene(request.params.arguments);
        case 'get_scene_file_content':
          return await this.handleGetSceneFileContent(request.params.arguments);
        case 'scene_set_unique_name':
          return await this.handleSceneSetUniqueName(request.params.arguments);
        case 'duplicate_node':
          return await this.handleDuplicateNode(request.params.arguments);
        // ── VCS Integration ───────────────────────────────────────────────
        case 'vcs_status':
          return await this.handleVcsStatus(request.params.arguments);
        case 'vcs_stage':
          return await this.handleVcsStage(request.params.arguments);
        case 'vcs_commit':
          return await this.handleVcsCommit(request.params.arguments);
        case 'vcs_diff':
          return await this.handleVcsDiff(request.params.arguments);
        case 'vcs_branch_list':
          return await this.handleVcsBranchList(request.params.arguments);
        case 'vcs_checkout':
          return await this.handleVcsCheckout(request.params.arguments);
        // ── Testing & QA ──────────────────────────────────────────────────
        case 'assert_node_state':
          return await this.handleAssertNodeState(request.params.arguments);
        case 'assert_screen_text':
          return await this.handleAssertScreenText(request.params.arguments);
        case 'compare_screenshots':
          return await this.handleCompareScreenshots(request.params.arguments);
        case 'run_stress_test':
          return await this.handleRunStressTest(request.params.arguments);
        // ── AnimationPlayer ───────────────────────────────────────────────
        case 'list_animations':
          return await this.handleListAnimations(request.params.arguments);
        case 'remove_animation':
          return await this.handleRemoveAnimation(request.params.arguments);
        // ── TileSet ───────────────────────────────────────────────────────
        case 'tileset_create':
          return await this.handleTilesetCreate(request.params.arguments);
        case 'tileset_add_source':
          return await this.handleTilesetAddSource(request.params.arguments);
        // ── SpriteFrames ──────────────────────────────────────────────────
        case 'spriteframes_create':
          return await this.handleSpriteframesCreate(request.params.arguments);
        case 'spriteframes_add_animation':
          return await this.handleSpriteframesAddAnimation(request.params.arguments);
        case 'spriteframes_add_frame':
          return await this.handleSpriteframesAddFrame(request.params.arguments);
        // ── Runtime Game Tools ────────────────────────────────────────────
        case 'find_nodes_by_script':
          return await this.handleFindNodesByScript(request.params.arguments);
        case 'batch_get_properties':
          return await this.handleBatchGetProperties(request.params.arguments);
        case 'click_button_by_text':
          return await this.handleClickButtonByText(request.params.arguments);
        case 'wait_for_node':
          return await this.handleWaitForNode(request.params.arguments);
        case 'find_nearby_nodes':
          return await this.handleFindNearbyNodes(request.params.arguments);
        case 'capture_frames':
          return await this.handleCaptureFrames(request.params.arguments);
        case 'monitor_properties':
          return await this.handleMonitorProperties(request.params.arguments);
        case 'start_recording':
          return await this.handleStartRecording(request.params.arguments);
        case 'stop_recording':
          return await this.handleStopRecording(request.params.arguments);
        case 'replay_recording':
          return await this.handleReplayRecording(request.params.arguments);
        // ── AnimationTree State Machine ───────────────────────────────────
        case 'animtree_add_state':
          return await this.handleAnimtreeAddState(request.params.arguments);
        case 'animtree_remove_state':
          return await this.handleAnimtreeRemoveState(request.params.arguments);
        case 'animtree_add_transition':
          return await this.handleAnimtreeAddTransition(request.params.arguments);
        case 'animtree_remove_transition':
          return await this.handleAnimtreeRemoveTransition(request.params.arguments);
        case 'animtree_get_structure':
          return await this.handleAnimtreeGetStructure(request.params.arguments);
        // ── Soft Debugger ─────────────────────────────────────────────────
        case 'debugger_set_breakpoint':
          return await this.handleDebuggerSetBreakpoint(request.params.arguments);
        case 'debugger_list_breakpoints':
          return await this.handleDebuggerListBreakpoints(request.params.arguments);
        case 'debugger_get_stack':
          return await this.handleDebuggerGetStack(request.params.arguments);
        case 'debugger_evaluate':
          return await this.handleDebuggerEvaluate(request.params.arguments);
        // ── Headless Scene Extras ─────────────────────────────────────────
        case 'add_scene_instance':
          return await this.handleAddSceneInstance(request.params.arguments);
        case 'move_node':
          return await this.handleMoveNode(request.params.arguments);
        case 'get_node_groups':
          return await this.handleGetNodeGroups(request.params.arguments);
        case 'set_node_groups':
          return await this.handleSetNodeGroups(request.params.arguments);
        case 'find_nodes_in_group':
          return await this.handleFindNodesInGroup(request.params.arguments);
        case 'scene_create_inherited':
          return await this.handleSceneCreateInherited(request.params.arguments);
        case 'add_autoload':
          return await this.handleAddAutoload(request.params.arguments);
        case 'remove_autoload':
          return await this.handleRemoveAutoload(request.params.arguments);
        // ── Resource Creation ─────────────────────────────────────────────
        case 'curve_create':
          return await this.handleCurveCreate(request.params.arguments);
        case 'gradient_create':
          return await this.handleGradientCreate(request.params.arguments);
        // ── Editor Tools ──────────────────────────────────────────────────
        case 'open_scene':
          return await this.handleOpenScene(request.params.arguments);
        case 'gdextension_list':
          return await this.handleGdextensionList(request.params.arguments);
        // ── Node Transform / Order ───────────────────────────────────────────
        case 'reorder_node':
          return await this.handleReorderNode(request.params.arguments);
        case 'get_node_transform':
          return await this.handleGetNodeTransform(request.params.arguments);
        case 'set_node_transform':
          return await this.handleSetNodeTransform(request.params.arguments);
        // ── Groups ───────────────────────────────────────────────────────────
        case 'list_all_groups':
          return await this.handleListAllGroups(request.params.arguments);
        case 'add_node_to_group':
          return await this.handleAddNodeToGroup(request.params.arguments);
        case 'remove_node_from_group':
          return await this.handleRemoveNodeFromGroup(request.params.arguments);
        // ── Plugins ──────────────────────────────────────────────────────────
        case 'plugin_list':
          return await this.handlePluginList(request.params.arguments);
        case 'plugin_enable':
          return await this.handlePluginEnable(request.params.arguments);
        case 'plugin_disable':
          return await this.handlePluginDisable(request.params.arguments);
        // ── Assets ───────────────────────────────────────────────────────────
        case 'shader_create':
          return await this.handleShaderCreate(request.params.arguments);
        case 'material_create':
          return await this.handleMaterialCreate(request.params.arguments);
        case 'script_template':
          return await this.handleScriptTemplate(request.params.arguments);
        // ── Export ───────────────────────────────────────────────────────────
        case 'export_list_presets':
          return await this.handleExportListPresets(request.params.arguments);
        case 'export_project':
          return await this.handleExportProject(request.params.arguments);
        // ── TileMap (runtime) ────────────────────────────────────────────────
        case 'tilemap_set_cell':
          return await this.handleTilemapSetCell(request.params.arguments);
        case 'tilemap_get_used_cells':
          return await this.handleTilemapGetUsedCells(request.params.arguments);
        case 'tilemap_clear':
          return await this.handleTilemapClear(request.params.arguments);
        // ── Audio Bus (runtime) ──────────────────────────────────────────────
        case 'audio_bus_list':
          return await this.handleAudioBusList(request.params.arguments);
        case 'audio_bus_create':
          return await this.handleAudioBusCreate(request.params.arguments);
        case 'audio_bus_set_volume':
          return await this.handleAudioBusSetVolume(request.params.arguments);
        case 'audio_bus_add_effect':
          return await this.handleAudioBusAddEffect(request.params.arguments);
        // ── Performance / Batch (runtime) ────────────────────────────────────
        case 'get_performance_counters':
          return await this.handleGetPerformanceCounters(request.params.arguments);
        case 'batch_set_properties':
          return await this.handleBatchSetProperties(request.params.arguments);
        // ── Class API / Scene Info ───────────────────────────────────────────
        case 'get_class_api':
          return await this.handleGetClassApi(request.params.arguments);
        case 'scene_node_count':
          return await this.handleSceneNodeCount(request.params.arguments);
        default:
          throw new McpError(
            ErrorCode.MethodNotFound,
            `Unknown tool: ${request.params.name}`
          );
      }
    });
  }

  /**
   * Handle the launch_editor tool
   * @param args Tool arguments
   */
  private async handleLaunchEditor(args: any) {
    // Normalize parameters to camelCase
    args = normalizeParameters(args);
    
    if (!args.projectPath) {
      return createErrorResponse(
        'Project path is required'
      );
    }

    if (!validatePath(args.projectPath)) {
      return createErrorResponse(
        'Invalid project path'
      );
    }

    try {
      // Ensure godotPath is set
      if (!this.godotPath) {
        await this.detectGodotPath();
        if (!this.godotPath) {
          return createErrorResponse(
            'Could not find a valid Godot executable path'
          );
        }
      }

      // Check if the project directory exists and contains a project.godot file
      const projectFile = join(args.projectPath, 'project.godot');
      if (!existsSync(projectFile)) {
        return createErrorResponse(
          `Not a valid Godot project: ${args.projectPath}`
        );
      }

      this.logDebug(`Launching Godot editor for project: ${args.projectPath}`);
      const process = spawn(this.godotPath, ['-e', '--path', args.projectPath], {
        stdio: 'pipe',
      });

      process.on('error', (err: Error) => {
        console.error('Failed to start Godot editor:', err);
      });

      return {
        content: [
          {
            type: 'text',
            text: `Godot editor launched successfully for project at ${args.projectPath}.`,
          },
        ],
      };
    } catch (error: unknown) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      return createErrorResponse(
        `Failed to launch Godot editor: ${errorMessage}`
      );
    }
  }

  /**
   * Handle the run_project tool
   * @param args Tool arguments
   */
  private async handleRunProject(args: any) {
    // Normalize parameters to camelCase
    args = normalizeParameters(args);
    
    if (!args.projectPath) {
      return createErrorResponse(
        'Project path is required'
      );
    }

    if (!validatePath(args.projectPath)) {
      return createErrorResponse(
        'Invalid project path'
      );
    }

    try {
      // Check if the project directory exists and contains a project.godot file
      const projectFile = join(args.projectPath, 'project.godot');
      if (!existsSync(projectFile)) {
        return createErrorResponse(
          `Not a valid Godot project: ${args.projectPath}`
        );
      }

      // Kill any existing process
      if (this.activeProcess) {
        this.logDebug('Killing existing Godot process before starting a new one');
        this.disconnectFromGame();
        if (this.gameConnection.projectPath) {
          this.removeInteractionServer(this.gameConnection.projectPath);
        }
        this.activeProcess.process.kill();
      }

      // Inject interaction server before launching
      this.injectInteractionServer(args.projectPath);

      const cmdArgs = ['-d', '--path', args.projectPath];
      if (args.scene && validatePath(args.scene)) {
        this.logDebug(`Adding scene parameter: ${args.scene}`);
        cmdArgs.push(args.scene);
      }

      this.logDebug(`Running Godot project: ${args.projectPath}`);
      const process = spawn(this.godotPath!, cmdArgs, { stdio: 'pipe' });
      const output: string[] = [];
      const errors: string[] = [];

      process.stdout?.on('data', (data: Buffer) => {
        const lines = data.toString().split('\n');
        output.push(...lines);
        lines.forEach((line: string) => {
          if (line.trim()) this.logDebug(`[Godot stdout] ${line}`);
        });
      });

      process.stderr?.on('data', (data: Buffer) => {
        const lines = data.toString().split('\n');
        errors.push(...lines);
        lines.forEach((line: string) => {
          if (line.trim()) this.logDebug(`[Godot stderr] ${line}`);
        });
      });

      process.on('exit', (code: number | null) => {
        this.logDebug(`Godot process exited with code ${code}`);
        this.disconnectFromGame();
        if (this.gameConnection.projectPath) {
          this.removeInteractionServer(this.gameConnection.projectPath);
          this.gameConnection.projectPath = null;
        }
        if (this.activeProcess && this.activeProcess.process === process) {
          this.activeProcess = null;
        }
      });

      process.on('error', (err: Error) => {
        console.error('Failed to start Godot process:', err);
        if (this.activeProcess && this.activeProcess.process === process) {
          this.activeProcess = null;
        }
      });

      this.activeProcess = { process, output, errors };

      // Start async TCP connection to the interaction server (fire-and-forget)
      this.connectToGame(args.projectPath).catch(err => {
        this.logDebug(`Failed to connect to game interaction server: ${err}`);
      });

      return {
        content: [
          {
            type: 'text',
            text: `Godot project started in debug mode. Use get_debug_output to see output. Game interaction server connecting on port ${this.INTERACTION_PORT}...`,
          },
        ],
      };
    } catch (error: unknown) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      return createErrorResponse(
        `Failed to run Godot project: ${errorMessage}`
      );
    }
  }

  /**
   * Handle the get_debug_output tool
   */
  private async handleGetDebugOutput() {
    if (!this.activeProcess) {
      return createErrorResponse(
        'No active Godot process.'
      );
    }

    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(
            {
              output: this.activeProcess.output,
              errors: this.activeProcess.errors,
            },
            null,
            2
          ),
        },
      ],
    };
  }

  /**
   * Handle the stop_project tool
   */
  private async handleStopProject() {
    if (!this.activeProcess) {
      return createErrorResponse(
        'No active Godot process to stop.'
      );
    }

    this.logDebug('Stopping active Godot process');
    this.disconnectFromGame();
    this.activeProcess.process.kill();
    const output = this.activeProcess.output;
    const errors = this.activeProcess.errors;
    this.activeProcess = null;
    this.lastErrorIndex = 0;
    this.lastLogIndex = 0;

    // Remove injected interaction server
    if (this.gameConnection.projectPath) {
      this.removeInteractionServer(this.gameConnection.projectPath);
      this.gameConnection.projectPath = null;
    }

    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(
            {
              message: 'Godot project stopped',
              finalOutput: output,
              finalErrors: errors,
            },
            null,
            2
          ),
        },
      ],
    };
  }

  /**
   * Handle the get_godot_version tool
   */
  private async handleGetGodotVersion() {
    try {
      // Ensure godotPath is set
      if (!this.godotPath) {
        await this.detectGodotPath();
        if (!this.godotPath) {
          return createErrorResponse(
            'Could not find a valid Godot executable path'
          );
        }
      }

      this.logDebug('Getting Godot version');
      const { stdout } = await execFileAsync(this.godotPath!, ['--version']);
      return {
        content: [
          {
            type: 'text',
            text: stdout.trim(),
          },
        ],
      };
    } catch (error: unknown) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      return createErrorResponse(
        `Failed to get Godot version: ${errorMessage}`
      );
    }
  }

  /**
   * Handle the list_projects tool
   */
  private async handleListProjects(args: any) {
    // Normalize parameters to camelCase
    args = normalizeParameters(args);
    
    if (!args.directory) {
      return createErrorResponse(
        'Directory is required'
      );
    }

    if (!validatePath(args.directory)) {
      return createErrorResponse(
        'Invalid directory path'
      );
    }

    try {
      this.logDebug(`Listing Godot projects in directory: ${args.directory}`);
      if (!existsSync(args.directory)) {
        return createErrorResponse(
          `Directory does not exist: ${args.directory}`
        );
      }

      const recursive = args.recursive === true;
      const projects = this.findGodotProjects(args.directory, recursive);

      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify(projects, null, 2),
          },
        ],
      };
    } catch (error: any) {
      return createErrorResponse(
        `Failed to list projects: ${error?.message || 'Unknown error'}`
      );
    }
  }

  /**
   * Get the structure of a Godot project asynchronously by counting files recursively
   * @param projectPath Path to the Godot project
   * @returns Promise resolving to an object with counts of scenes, scripts, assets, and other files
   */
  private getProjectStructureAsync(projectPath: string): Promise<any> {
    return new Promise((resolve) => {
      try {
        const structure = {
          scenes: 0,
          scripts: 0,
          assets: 0,
          other: 0,
        };

        const scanDirectory = (currentPath: string) => {
          const entries = readdirSync(currentPath, { withFileTypes: true });
          
          for (const entry of entries) {
            const entryPath = join(currentPath, entry.name);
            
            // Skip hidden files and directories
            if (entry.name.startsWith('.')) {
              continue;
            }
            
            if (entry.isDirectory()) {
              // Recursively scan subdirectories
              scanDirectory(entryPath);
            } else if (entry.isFile()) {
              // Count file by extension
              const ext = entry.name.split('.').pop()?.toLowerCase();
              
              if (ext === 'tscn') {
                structure.scenes++;
              } else if (ext === 'gd' || ext === 'gdscript' || ext === 'cs') {
                structure.scripts++;
              } else if (['png', 'jpg', 'jpeg', 'webp', 'svg', 'ttf', 'wav', 'mp3', 'ogg'].includes(ext || '')) {
                structure.assets++;
              } else {
                structure.other++;
              }
            }
          }
        };
        
        // Start scanning from the project root
        scanDirectory(projectPath);
        resolve(structure);
      } catch (error) {
        this.logDebug(`Error getting project structure asynchronously: ${error}`);
        resolve({ 
          error: 'Failed to get project structure',
          scenes: 0,
          scripts: 0,
          assets: 0,
          other: 0
        });
      }
    });
  }

  /**
   * Handle the get_project_info tool
   */
  private async handleGetProjectInfo(args: any) {
    // Normalize parameters to camelCase
    args = normalizeParameters(args);
    
    if (!args.projectPath) {
      return createErrorResponse(
        'Project path is required'
      );
    }
  
    if (!validatePath(args.projectPath)) {
      return createErrorResponse(
        'Invalid project path'
      );
    }
  
    try {
      // Ensure godotPath is set
      if (!this.godotPath) {
        await this.detectGodotPath();
        if (!this.godotPath) {
          return createErrorResponse(
            'Could not find a valid Godot executable path'
          );
        }
      }
  
      // Check if the project directory exists and contains a project.godot file
      const projectFile = join(args.projectPath, 'project.godot');
      if (!existsSync(projectFile)) {
        return createErrorResponse(
          `Not a valid Godot project: ${args.projectPath}`
        );
      }
  
      this.logDebug(`Getting project info for: ${args.projectPath}`);
  
      // Get Godot version
      const execOptions = { timeout: 10000 }; // 10 second timeout
      const { stdout } = await execFileAsync(this.godotPath!, ['--version'], execOptions);
  
      // Get project structure using the recursive method
      const projectStructure = await this.getProjectStructureAsync(args.projectPath);
  
      // Extract project name from project.godot file
      let projectName = basename(args.projectPath);
      try {
        const projectFileContent = readFileSync(projectFile, 'utf8');
        const configNameMatch = projectFileContent.match(/config\/name="([^"]+)"/);
        if (configNameMatch && configNameMatch[1]) {
          projectName = configNameMatch[1];
          this.logDebug(`Found project name in config: ${projectName}`);
        }
      } catch (error) {
        this.logDebug(`Error reading project file: ${error}`);
        // Continue with default project name if extraction fails
      }
  
      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify(
              {
                name: projectName,
                path: args.projectPath,
                godotVersion: stdout.trim(),
                structure: projectStructure,
              },
              null,
              2
            ),
          },
        ],
      };
    } catch (error: any) {
      return createErrorResponse(
        `Failed to get project info: ${error?.message || 'Unknown error'}`
      );
    }
  }

  /**
   * Handle the create_scene tool
   */
  private async handleCreateScene(args: any) {
    // Normalize parameters to camelCase
    args = normalizeParameters(args);
    
    if (!args.projectPath || !args.scenePath) {
      return createErrorResponse(
        'Project path and scene path are required'
      );
    }

    if (!validatePath(args.projectPath) || !validatePath(args.scenePath)) {
      return createErrorResponse(
        'Invalid path'
      );
    }

    try {
      // Check if the project directory exists and contains a project.godot file
      const projectFile = join(args.projectPath, 'project.godot');
      if (!existsSync(projectFile)) {
        return createErrorResponse(
          `Not a valid Godot project: ${args.projectPath}`
        );
      }

      // Prepare parameters for the operation (already in camelCase)
      const params = {
        scenePath: args.scenePath,
        rootNodeType: args.rootNodeType || 'Node2D',
      };

      // Execute the operation
      const { stdout, stderr } = await this.executeOperation('create_scene', params, args.projectPath);

      if (stderr && stderr.includes('Failed to')) {
        return createErrorResponse(
          `Failed to create scene: ${stderr}`
        );
      }

      return {
        content: [
          {
            type: 'text',
            text: `Scene created successfully at: ${args.scenePath}\n\nOutput: ${stdout}`,
          },
        ],
      };
    } catch (error: any) {
      return createErrorResponse(
        `Failed to create scene: ${error?.message || 'Unknown error'}`
      );
    }
  }

  /**
   * Handle the add_node tool
   */
  private async handleAddNode(args: any) {
    // Normalize parameters to camelCase
    args = normalizeParameters(args);
    
    if (!args.projectPath || !args.scenePath || !args.nodeType || !args.nodeName) {
      return createErrorResponse(
        'Missing required parameters'
      );
    }

    if (!validatePath(args.projectPath) || !validatePath(args.scenePath)) {
      return createErrorResponse(
        'Invalid path'
      );
    }

    try {
      // Check if the project directory exists and contains a project.godot file
      const projectFile = join(args.projectPath, 'project.godot');
      if (!existsSync(projectFile)) {
        return createErrorResponse(
          `Not a valid Godot project: ${args.projectPath}`
        );
      }

      // Check if the scene file exists
      const scenePath = this.resolveResPath(args.projectPath, args.scenePath);
      if (!existsSync(scenePath)) {
        return createErrorResponse(
          `Scene file does not exist: ${args.scenePath}`
        );
      }

      // Prepare parameters for the operation (already in camelCase)
      const params: any = {
        scenePath: args.scenePath,
        nodeType: args.nodeType,
        nodeName: args.nodeName,
      };

      // Add optional parameters
      if (args.parentNodePath) {
        params.parentNodePath = args.parentNodePath;
      }

      if (args.properties) {
        params.properties = args.properties;
      }

      // Execute the operation
      const { stdout, stderr } = await this.executeOperation('add_node', params, args.projectPath);

      if (stderr && stderr.includes('Failed to')) {
        return createErrorResponse(
          `Failed to add node: ${stderr}`
        );
      }

      return {
        content: [
          {
            type: 'text',
            text: `Node '${args.nodeName}' of type '${args.nodeType}' added successfully to '${args.scenePath}'.\n\nOutput: ${stdout}`,
          },
        ],
      };
    } catch (error: any) {
      return createErrorResponse(
        `Failed to add node: ${error?.message || 'Unknown error'}`
      );
    }
  }

  /**
   * Handle the load_sprite tool
   */
  private async handleLoadSprite(args: any) {
    // Normalize parameters to camelCase
    args = normalizeParameters(args);
    
    if (!args.projectPath || !args.scenePath || !args.nodePath || !args.texturePath) {
      return createErrorResponse(
        'Missing required parameters'
      );
    }

    if (
      !validatePath(args.projectPath) ||
      !validatePath(args.scenePath) ||
      !validatePath(args.nodePath) ||
      !validatePath(args.texturePath)
    ) {
      return createErrorResponse(
        'Invalid path'
      );
    }

    try {
      // Check if the project directory exists and contains a project.godot file
      const projectFile = join(args.projectPath, 'project.godot');
      if (!existsSync(projectFile)) {
        return createErrorResponse(
          `Not a valid Godot project: ${args.projectPath}`
        );
      }

      // Check if the scene file exists
      const scenePath = this.resolveResPath(args.projectPath, args.scenePath);
      if (!existsSync(scenePath)) {
        return createErrorResponse(
          `Scene file does not exist: ${args.scenePath}`
        );
      }

      // Check if the texture file exists
      const texturePath = join(args.projectPath, args.texturePath);
      if (!existsSync(texturePath)) {
        return createErrorResponse(
          `Texture file does not exist: ${args.texturePath}`
        );
      }

      // Prepare parameters for the operation (already in camelCase)
      const params = {
        scenePath: args.scenePath,
        nodePath: args.nodePath,
        texturePath: args.texturePath,
      };

      // Execute the operation
      const { stdout, stderr } = await this.executeOperation('load_sprite', params, args.projectPath);

      if (stderr && stderr.includes('Failed to')) {
        return createErrorResponse(
          `Failed to load sprite: ${stderr}`
        );
      }

      return {
        content: [
          {
            type: 'text',
            text: `Sprite loaded successfully with texture: ${args.texturePath}\n\nOutput: ${stdout}`,
          },
        ],
      };
    } catch (error: any) {
      return createErrorResponse(
        `Failed to load sprite: ${error?.message || 'Unknown error'}`
      );
    }
  }

  /**
   * Handle the export_mesh_library tool
   */
  private async handleExportMeshLibrary(args: any) {
    // Normalize parameters to camelCase
    args = normalizeParameters(args);
    
    if (!args.projectPath || !args.scenePath || !args.outputPath) {
      return createErrorResponse(
        'Missing required parameters'
      );
    }

    if (
      !validatePath(args.projectPath) ||
      !validatePath(args.scenePath) ||
      !validatePath(args.outputPath)
    ) {
      return createErrorResponse(
        'Invalid path'
      );
    }

    try {
      // Check if the project directory exists and contains a project.godot file
      const projectFile = join(args.projectPath, 'project.godot');
      if (!existsSync(projectFile)) {
        return createErrorResponse(
          `Not a valid Godot project: ${args.projectPath}`
        );
      }

      // Check if the scene file exists
      const scenePath = this.resolveResPath(args.projectPath, args.scenePath);
      if (!existsSync(scenePath)) {
        return createErrorResponse(
          `Scene file does not exist: ${args.scenePath}`
        );
      }

      // Prepare parameters for the operation (already in camelCase)
      const params: any = {
        scenePath: args.scenePath,
        outputPath: args.outputPath,
      };

      // Add optional parameters
      if (args.meshItemNames && Array.isArray(args.meshItemNames)) {
        params.meshItemNames = args.meshItemNames;
      }

      // Execute the operation
      const { stdout, stderr } = await this.executeOperation('export_mesh_library', params, args.projectPath);

      if (stderr && stderr.includes('Failed to')) {
        return createErrorResponse(
          `Failed to export mesh library: ${stderr}`
        );
      }

      return {
        content: [
          {
            type: 'text',
            text: `MeshLibrary exported successfully to: ${args.outputPath}\n\nOutput: ${stdout}`,
          },
        ],
      };
    } catch (error: any) {
      return createErrorResponse(
        `Failed to export mesh library: ${error?.message || 'Unknown error'}`
      );
    }
  }

  /**
   * Handle the save_scene tool
   */
  private async handleSaveScene(args: any) {
    // Normalize parameters to camelCase
    args = normalizeParameters(args);
    
    if (!args.projectPath || !args.scenePath) {
      return createErrorResponse(
        'Missing required parameters'
      );
    }

    if (!validatePath(args.projectPath) || !validatePath(args.scenePath)) {
      return createErrorResponse(
        'Invalid path'
      );
    }

    // If newPath is provided, validate it
    if (args.newPath && !validatePath(args.newPath)) {
      return createErrorResponse(
        'Invalid new path'
      );
    }

    try {
      // Check if the project directory exists and contains a project.godot file
      const projectFile = join(args.projectPath, 'project.godot');
      if (!existsSync(projectFile)) {
        return createErrorResponse(
          `Not a valid Godot project: ${args.projectPath}`
        );
      }

      // Check if the scene file exists
      const scenePath = this.resolveResPath(args.projectPath, args.scenePath);
      if (!existsSync(scenePath)) {
        return createErrorResponse(
          `Scene file does not exist: ${args.scenePath}`
        );
      }

      // Prepare parameters for the operation (already in camelCase)
      const params: any = {
        scenePath: args.scenePath,
      };

      // Add optional parameters
      if (args.newPath) {
        params.newPath = args.newPath;
      }

      // Execute the operation
      const { stdout, stderr } = await this.executeOperation('save_scene', params, args.projectPath);

      if (stderr && stderr.includes('Failed to')) {
        return createErrorResponse(
          `Failed to save scene: ${stderr}`
        );
      }

      const savePath = args.newPath || args.scenePath;
      return {
        content: [
          {
            type: 'text',
            text: `Scene saved successfully to: ${savePath}\n\nOutput: ${stdout}`,
          },
        ],
      };
    } catch (error: any) {
      return createErrorResponse(
        `Failed to save scene: ${error?.message || 'Unknown error'}`
      );
    }
  }

  /**
   * Handle the get_uid tool
   */
  private async handleGetUid(args: any) {
    // Normalize parameters to camelCase
    args = normalizeParameters(args);
    
    if (!args.projectPath || !args.filePath) {
      return createErrorResponse(
        'Missing required parameters'
      );
    }

    if (!validatePath(args.projectPath) || !validatePath(args.filePath)) {
      return createErrorResponse(
        'Invalid path'
      );
    }

    try {
      // Ensure godotPath is set
      if (!this.godotPath) {
        await this.detectGodotPath();
        if (!this.godotPath) {
          return createErrorResponse(
            'Could not find a valid Godot executable path'
          );
        }
      }

      // Check if the project directory exists and contains a project.godot file
      const projectFile = join(args.projectPath, 'project.godot');
      if (!existsSync(projectFile)) {
        return createErrorResponse(
          `Not a valid Godot project: ${args.projectPath}`
        );
      }

      // Check if the file exists
      const filePath = this.resolveResPath(args.projectPath, args.filePath);
      if (!existsSync(filePath)) {
        return createErrorResponse(
          `File does not exist: ${args.filePath}`
        );
      }

      // Get Godot version to check if UIDs are supported
      const { stdout: versionOutput } = await execFileAsync(this.godotPath!, ['--version']);
      const version = versionOutput.trim();

      if (!isGodot44OrLater(version)) {
        return createErrorResponse(
          `UIDs are only supported in Godot 4.4 or later. Current version: ${version}`
        );
      }

      // Prepare parameters for the operation (already in camelCase)
      const params = {
        filePath: args.filePath,
      };

      // Execute the operation
      const { stdout, stderr } = await this.executeOperation('get_uid', params, args.projectPath);

      if (stderr && stderr.includes('Failed to')) {
        return createErrorResponse(
          `Failed to get UID: ${stderr}`
        );
      }

      return {
        content: [
          {
            type: 'text',
            text: `UID for ${args.filePath}: ${stdout.trim()}`,
          },
        ],
      };
    } catch (error: any) {
      return createErrorResponse(
        `Failed to get UID: ${error?.message || 'Unknown error'}`
      );
    }
  }


  /**
   * Handle the game_screenshot tool
   */
  private async handleGameScreenshot() {
    if (!this.activeProcess) {
      return createErrorResponse('No active Godot process. Use run_project first.');
    }
    if (!this.gameConnection.connected) {
      return createErrorResponse('Not connected to game interaction server. Wait a moment and try again.');
    }

    try {
      const response = await this.sendGameCommand('screenshot');
      if (response.error) {
        return createErrorResponse(`Screenshot failed: ${response.error}`);
      }
      return {
        content: [
          {
            type: 'image',
            data: response.data,
            mimeType: 'image/png',
          },
          {
            type: 'text',
            text: `Screenshot captured: ${response.width}x${response.height}`,
          },
        ],
      };
    } catch (error: any) {
      return createErrorResponse(`Screenshot failed: ${error?.message || 'Unknown error'}`);
    }
  }

  private async handleGameClick(args: any) {
    return this.gameCommand('click', args, a => ({ x: a.x ?? 0, y: a.y ?? 0, button: a.button ?? 1 }));
  }

  private async handleGameKeyPress(args: any) {
    args = args || {};
    if (!args.key && !args.action) return createErrorResponse('Must provide either "key" or "action" parameter.');
    const params: Record<string, any> = {};
    if (args.key) params.key = args.key;
    if (args.action) params.action = args.action;
    if (args.pressed !== undefined) params.pressed = args.pressed;
    return this.gameCommand('key_press', args, () => params);
  }

  private async handleGameMouseMove(args: any) {
    return this.gameCommand('mouse_move', args, a => ({
      x: a.x ?? 0, y: a.y ?? 0, relative_x: a.relative_x ?? 0, relative_y: a.relative_y ?? 0,
    }));
  }

  private async handleGameGetUi() {
    return this.gameCommand('get_ui_elements', {}, () => ({}));
  }

  private async handleGameGetSceneTree() {
    return this.gameCommand('get_scene_tree', {}, () => ({}));
  }

  private async handleGameEval(args: any) {
    args = normalizeParameters(args || {});
    if (!args.code) return createErrorResponse('code parameter is required.');
    return this.gameCommand('eval', args, a => ({ code: a.code }), 30000);
  }

  private async handleGameGetProperty(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.property) return createErrorResponse('nodePath and property are required.');
    return this.gameCommand('get_property', args, a => ({ node_path: a.nodePath, property: a.property }));
  }

  private async handleGameSetProperty(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.property) return createErrorResponse('nodePath and property are required.');
    return this.gameCommand('set_property', args, a => ({
      node_path: a.nodePath, property: a.property, value: a.value, type_hint: a.typeHint || '',
    }));
  }

  private async handleGameCallMethod(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.method) return createErrorResponse('nodePath and method are required.');
    return this.gameCommand('call_method', args, a => ({
      node_path: a.nodePath, method: a.method, args: a.args || [],
    }));
  }

  private async handleGameGetNodeInfo(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath) return createErrorResponse('nodePath is required.');
    return this.gameCommand('get_node_info', args, a => ({ node_path: a.nodePath }));
  }

  private async handleGameInstantiateScene(args: any) {
    args = normalizeParameters(args || {});
    if (!args.scenePath) return createErrorResponse('scenePath is required.');
    return this.gameCommand('instantiate_scene', args, a => ({
      scene_path: a.scenePath, parent_path: a.parentPath || '/root',
    }));
  }

  private async handleGameRemoveNode(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath) return createErrorResponse('nodePath is required.');
    return this.gameCommand('remove_node', args, a => ({ node_path: a.nodePath }));
  }

  private async handleGameChangeScene(args: any) {
    args = normalizeParameters(args || {});
    if (!args.scenePath) return createErrorResponse('scenePath is required.');
    return this.gameCommand('change_scene', args, a => ({ scene_path: a.scenePath }));
  }

  private async handleGamePause(args: any) {
    return this.gameCommand('pause', args, a => ({ paused: a.paused !== undefined ? a.paused : true }));
  }

  private async handleGamePerformance() {
    return this.gameCommand('get_performance', {}, () => ({}));
  }

  private async handleGameWait(args: any) {
    return this.gameCommand('wait', args, a => ({ frames: a.frames || 1 }), 30000);
  }


  /**
   * Handle the read_scene tool - Read a scene file structure
   */
  private async handleReadScene(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath) {
      return createErrorResponse('projectPath and scenePath are required.');
    }

    if (!validatePath(args.projectPath) || !validatePath(args.scenePath)) {
      return createErrorResponse('Invalid path.');
    }

    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) {
      return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    }

    const scenePath = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(scenePath)) {
      return createErrorResponse(`Scene file does not exist: ${args.scenePath}`);
    }

    try {
      const { stdout, stderr } = await this.executeOperation('read_scene', {
        scenePath: args.scenePath,
      }, args.projectPath);

      // Extract JSON from the SCENE_JSON_START/END markers
      const startMarker = 'SCENE_JSON_START';
      const endMarker = 'SCENE_JSON_END';
      const startIdx = stdout.indexOf(startMarker);
      const endIdx = stdout.indexOf(endMarker);

      if (startIdx !== -1 && endIdx !== -1) {
        const jsonStr = stdout.substring(startIdx + startMarker.length, endIdx).trim();
        try {
          const parsed = JSON.parse(jsonStr);
          return {
            content: [{ type: 'text', text: JSON.stringify(parsed, null, 2) }],
          };
        } catch {
          return {
            content: [{ type: 'text', text: `Raw scene data:\n${jsonStr}` }],
          };
        }
      }

      return {
        content: [{ type: 'text', text: `Scene read output:\n${stdout}\n${stderr ? 'Errors:\n' + stderr : ''}` }],
      };
    } catch (error: any) {
      return createErrorResponse(`Failed to read scene: ${error?.message || 'Unknown error'}`);
    }
  }

  /**
   * Handle the modify_scene_node tool
   */
  private async handleModifySceneNode(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.nodePath || !args.properties)
      return createErrorResponse('projectPath, scenePath, nodePath, and properties are required.');
    return this.headlessOp('modify_node', args, a => ({
      projectPath: a.projectPath,
      params: { scenePath: a.scenePath, nodePath: a.nodePath, properties: a.properties },
    }));
  }

  private async handleRemoveSceneNode(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.nodePath)
      return createErrorResponse('projectPath, scenePath, and nodePath are required.');
    return this.headlessOp('remove_node', args, a => ({
      projectPath: a.projectPath,
      params: { scenePath: a.scenePath, nodePath: a.nodePath },
    }));
  }


  /**
   * Handle the read_project_settings tool - Parse project.godot as JSON
   */
  private async handleReadProjectSettings(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) {
      return createErrorResponse('projectPath is required.');
    }

    if (!validatePath(args.projectPath)) {
      return createErrorResponse('Invalid path.');
    }

    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) {
      return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    }

    try {
      const content = readFileSync(projectFile, 'utf8');
      const sections: Record<string, Record<string, string>> = {};
      let currentSection = '';

      for (const line of content.split('\n')) {
        const trimmed = line.trim();
        if (trimmed === '' || trimmed.startsWith(';')) continue;

        // Section header
        const sectionMatch = trimmed.match(/^\[(.+)\]$/);
        if (sectionMatch) {
          currentSection = sectionMatch[1];
          if (!sections[currentSection]) {
            sections[currentSection] = {};
          }
          continue;
        }

        // Key=value pair
        const kvMatch = trimmed.match(/^([^=]+)=(.*)$/);
        if (kvMatch && currentSection) {
          const key = kvMatch[1].trim();
          const value = kvMatch[2].trim();
          sections[currentSection][key] = value;
        }
      }

      return {
        content: [{ type: 'text', text: JSON.stringify(sections, null, 2) }],
      };
    } catch (error: any) {
      return createErrorResponse(`Failed to read project settings: ${error?.message || 'Unknown error'}`);
    }
  }

  /**
   * Handle the modify_project_settings tool - Change a project.godot setting
   */
  private async handleModifyProjectSettings(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.section || !args.key || args.value === undefined) {
      return createErrorResponse('projectPath, section, key, and value are required.');
    }

    if (!validatePath(args.projectPath)) {
      return createErrorResponse('Invalid path.');
    }

    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) {
      return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    }

    try {
      let content = readFileSync(projectFile, 'utf8');
      const sectionHeader = `[${args.section}]`;
      const keyLine = `${args.key}=${args.value}`;

      // Check if section exists
      const sectionIdx = content.indexOf(sectionHeader);
      if (sectionIdx !== -1) {
        // Section exists - look for existing key
        const sectionEnd = content.indexOf('\n[', sectionIdx + sectionHeader.length);
        const sectionContent = sectionEnd !== -1
          ? content.substring(sectionIdx, sectionEnd)
          : content.substring(sectionIdx);

        // Try to find and replace existing key
        const keyPattern = new RegExp(`^${args.key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*=.*$`, 'm');
        if (keyPattern.test(sectionContent)) {
          // Replace existing key
          const newSectionContent = sectionContent.replace(keyPattern, keyLine);
          content = content.substring(0, sectionIdx) + newSectionContent +
            (sectionEnd !== -1 ? content.substring(sectionEnd) : '');
        } else {
          // Add key to existing section
          const insertPos = sectionIdx + sectionHeader.length;
          content = content.substring(0, insertPos) + '\n' + keyLine + content.substring(insertPos);
        }
      } else {
        // Add new section at end
        content += `\n\n${sectionHeader}\n\n${keyLine}\n`;
      }

      writeFileSync(projectFile, content, 'utf8');
      return {
        content: [{ type: 'text', text: `Setting updated: [${args.section}] ${args.key}=${args.value}` }],
      };
    } catch (error: any) {
      return createErrorResponse(`Failed to modify project settings: ${error?.message || 'Unknown error'}`);
    }
  }

  /**
   * Handle the list_project_files tool - List files with extension filtering
   */
  private async handleListProjectFiles(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) {
      return createErrorResponse('projectPath is required.');
    }

    if (!validatePath(args.projectPath)) {
      return createErrorResponse('Invalid path.');
    }

    if (!existsSync(args.projectPath)) {
      return createErrorResponse(`Directory does not exist: ${args.projectPath}`);
    }

    try {
      const baseDir = args.subdirectory
        ? join(args.projectPath, args.subdirectory)
        : args.projectPath;

      if (!existsSync(baseDir)) {
        return createErrorResponse(`Subdirectory does not exist: ${args.subdirectory}`);
      }

      const files: string[] = [];
      const extensions: string[] | undefined = args.extensions;

      const scanDir = (dir: string, relativeTo: string) => {
        const entries = readdirSync(dir, { withFileTypes: true });
        for (const entry of entries) {
          if (entry.name.startsWith('.')) continue;
          const fullPath = join(dir, entry.name);
          const relativePath = fullPath.substring(relativeTo.length + 1).replace(/\\/g, '/');

          if (entry.isDirectory()) {
            scanDir(fullPath, relativeTo);
          } else if (entry.isFile()) {
            if (extensions && extensions.length > 0) {
              const ext = '.' + entry.name.split('.').pop();
              if (extensions.includes(ext)) {
                files.push(relativePath);
              }
            } else {
              files.push(relativePath);
            }
          }
        }
      };

      scanDir(baseDir, args.projectPath);

      return {
        content: [{ type: 'text', text: JSON.stringify({ count: files.length, files }, null, 2) }],
      };
    } catch (error: any) {
      return createErrorResponse(`Failed to list project files: ${error?.message || 'Unknown error'}`);
    }
  }

  private async handleGameConnectSignal(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.signalName || !args.targetPath || !args.method)
      return createErrorResponse('nodePath, signalName, targetPath, and method are required.');
    return this.gameCommand('connect_signal', args, a => ({
      node_path: a.nodePath, signal_name: a.signalName, target_path: a.targetPath, method: a.method,
    }));
  }

  private async handleGameDisconnectSignal(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.signalName || !args.targetPath || !args.method)
      return createErrorResponse('nodePath, signalName, targetPath, and method are required.');
    return this.gameCommand('disconnect_signal', args, a => ({
      node_path: a.nodePath, signal_name: a.signalName, target_path: a.targetPath, method: a.method,
    }));
  }

  private async handleGameEmitSignal(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.signalName) return createErrorResponse('nodePath and signalName are required.');
    return this.gameCommand('emit_signal', args, a => ({
      node_path: a.nodePath, signal_name: a.signalName, args: a.args || [],
    }));
  }

  private async handleGamePlayAnimation(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath) return createErrorResponse('nodePath is required.');
    return this.gameCommand('play_animation', args, a => ({
      node_path: a.nodePath, action: a.action || 'play', animation: a.animation || '',
    }));
  }

  private async handleGameTweenProperty(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.property || args.finalValue === undefined)
      return createErrorResponse('nodePath, property, and finalValue are required.');
    return this.gameCommand('tween_property', args, a => ({
      node_path: a.nodePath, property: a.property, final_value: a.finalValue,
      duration: a.duration || 1.0, trans_type: a.transType || 0, ease_type: a.easeType || 2,
    }));
  }

  private async handleGameGetNodesInGroup(args: any) {
    args = normalizeParameters(args || {});
    if (!args.group) return createErrorResponse('group is required.');
    return this.gameCommand('get_nodes_in_group', args, a => ({ group: a.group }));
  }

  private async handleGameFindNodesByClass(args: any) {
    args = normalizeParameters(args || {});
    if (!args.className) return createErrorResponse('className is required.');
    return this.gameCommand('find_nodes_by_class', args, a => ({
      class_name: a.className, root_path: a.rootPath || '/root',
    }));
  }

  private async handleGameReparentNode(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.newParentPath) return createErrorResponse('nodePath and newParentPath are required.');
    return this.gameCommand('reparent_node', args, a => ({
      node_path: a.nodePath, new_parent_path: a.newParentPath, keep_global_transform: a.keepGlobalTransform !== false,
    }));
  }

  private async handleAttachScript(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.nodePath || !args.scriptPath)
      return createErrorResponse('projectPath, scenePath, nodePath, and scriptPath are required.');
    return this.headlessOp('attach_script', args, a => ({
      projectPath: a.projectPath,
      params: { scenePath: a.scenePath, nodePath: a.nodePath, scriptPath: a.scriptPath },
    }));
  }

  private async handleCreateResource(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.resourceType || !args.resourcePath)
      return createErrorResponse('projectPath, resourceType, and resourcePath are required.');
    return this.headlessOp('create_resource', args, a => ({
      projectPath: a.projectPath,
      params: { resourceType: a.resourceType, resourcePath: a.resourcePath, ...(a.properties ? { properties: a.properties } : {}) },
    }));
  }

  // --- File I/O handlers ---

  private async handleReadFile(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.filePath)
      return createErrorResponse('projectPath and filePath are required.');
    if (!validatePath(args.projectPath) || !validatePath(args.filePath))
      return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile))
      return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    const fullPath = this.resolveResPath(args.projectPath, args.filePath);
    if (!existsSync(fullPath))
      return createErrorResponse(`File does not exist: ${args.filePath}`);
    try {
      const content = readFileSync(fullPath, 'utf8');
      return { content: [{ type: 'text', text: content }] };
    } catch (error: any) {
      return createErrorResponse(`Failed to read file: ${error?.message || 'Unknown error'}`);
    }
  }

  private async handleWriteFile(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.filePath || args.content === undefined)
      return createErrorResponse('projectPath, filePath, and content are required.');
    if (!validatePath(args.projectPath) || !validatePath(args.filePath))
      return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile))
      return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    try {
      const fullPath = this.resolveResPath(args.projectPath, args.filePath);
      const parentDir = dirname(fullPath);
      if (!existsSync(parentDir)) {
        mkdirSync(parentDir, { recursive: true });
      }
      writeFileSync(fullPath, args.content, 'utf8');
      return { content: [{ type: 'text', text: `File written: ${args.filePath}` }] };
    } catch (error: any) {
      return createErrorResponse(`Failed to write file: ${error?.message || 'Unknown error'}`);
    }
  }

  private async handleDeleteFile(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.filePath)
      return createErrorResponse('projectPath and filePath are required.');
    if (!validatePath(args.projectPath) || !validatePath(args.filePath))
      return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile))
      return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    const fullPath = this.resolveResPath(args.projectPath, args.filePath);
    if (!existsSync(fullPath))
      return createErrorResponse(`File does not exist: ${args.filePath}`);
    try {
      unlinkSync(fullPath);
      return { content: [{ type: 'text', text: `File deleted: ${args.filePath}` }] };
    } catch (error: any) {
      return createErrorResponse(`Failed to delete file: ${error?.message || 'Unknown error'}`);
    }
  }

  private async handleCreateDirectory(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.directoryPath)
      return createErrorResponse('projectPath and directoryPath are required.');
    if (!validatePath(args.projectPath) || !validatePath(args.directoryPath))
      return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile))
      return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    try {
      const fullPath = join(args.projectPath, args.directoryPath);
      mkdirSync(fullPath, { recursive: true });
      return { content: [{ type: 'text', text: `Directory created: ${args.directoryPath}` }] };
    } catch (error: any) {
      return createErrorResponse(`Failed to create directory: ${error?.message || 'Unknown error'}`);
    }
  }

  // --- Error/Log capture handlers ---

  private async handleGameGetErrors() {
    if (!this.activeProcess)
      return createErrorResponse('No active Godot process. Use run_project first.');
    const errors = this.activeProcess.errors.slice(this.lastErrorIndex);
    this.lastErrorIndex = this.activeProcess.errors.length;
    return { content: [{ type: 'text', text: JSON.stringify({ count: errors.length, errors }, null, 2) }] };
  }

  private async handleGameGetLogs() {
    if (!this.activeProcess)
      return createErrorResponse('No active Godot process. Use run_project first.');
    const logs = this.activeProcess.output.slice(this.lastLogIndex);
    this.lastLogIndex = this.activeProcess.output.length;
    return { content: [{ type: 'text', text: JSON.stringify({ count: logs.length, logs }, null, 2) }] };
  }

  // --- Enhanced input handlers ---

  private async handleGameKeyHold(args: any) {
    args = args || {};
    if (!args.key && !args.action) return createErrorResponse('Must provide either "key" or "action" parameter.');
    const params: Record<string, any> = {};
    if (args.key) params.key = args.key;
    if (args.action) params.action = args.action;
    return this.gameCommand('key_hold', args, () => params);
  }

  private async handleGameKeyRelease(args: any) {
    args = args || {};
    if (!args.key && !args.action) return createErrorResponse('Must provide either "key" or "action" parameter.');
    const params: Record<string, any> = {};
    if (args.key) params.key = args.key;
    if (args.action) params.action = args.action;
    return this.gameCommand('key_release', args, () => params);
  }

  private async handleGameScroll(args: any) {
    return this.gameCommand('scroll', args, a => ({
      x: a.x ?? 0, y: a.y ?? 0, direction: a.direction || 'up', amount: a.amount || 1,
    }));
  }

  private async handleGameMouseDrag(args: any) {
    args = normalizeParameters(args || {});
    if (args.fromX === undefined || args.fromY === undefined || args.toX === undefined || args.toY === undefined)
      return createErrorResponse('fromX, fromY, toX, and toY are required.');
    return this.gameCommand('mouse_drag', args, a => ({
      from_x: a.fromX, from_y: a.fromY, to_x: a.toX, to_y: a.toY,
      button: a.button || 1, steps: a.steps || 10,
    }), 30000);
  }

  private async handleGameGamepad(args: any) {
    args = normalizeParameters(args || {});
    if (!args.type || args.index === undefined || args.value === undefined)
      return createErrorResponse('type, index, and value are required.');
    return this.gameCommand('gamepad', args, a => ({
      type: a.type, index: a.index, value: a.value, device: a.device || 0,
    }));
  }

  // --- Project management handlers ---

  private async handleCreateProject(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.projectName)
      return createErrorResponse('projectPath and projectName are required.');
    if (!validatePath(args.projectPath))
      return createErrorResponse('Invalid path.');
    try {
      if (!existsSync(args.projectPath)) {
        mkdirSync(args.projectPath, { recursive: true });
      }
      const projectFile = join(args.projectPath, 'project.godot');
      if (existsSync(projectFile))
        return createErrorResponse('A project.godot already exists at this path.');
      const content = `; Engine configuration file.\n; Generated by Godot MCP.\n\nconfig_version=5\n\n[application]\n\nconfig/name="${args.projectName}"\nconfig/features=PackedStringArray("4.3")\n`;
      writeFileSync(projectFile, content, 'utf8');
      return { content: [{ type: 'text', text: `Project "${args.projectName}" created at ${args.projectPath}` }] };
    } catch (error: any) {
      return createErrorResponse(`Failed to create project: ${error?.message || 'Unknown error'}`);
    }
  }

  private async handleManageAutoloads(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.action)
      return createErrorResponse('projectPath and action are required.');
    if (!validatePath(args.projectPath))
      return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile))
      return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    try {
      let content = readFileSync(projectFile, 'utf8');
      if (args.action === 'list') {
        const autoloads: Record<string, string> = {};
        const autoloadMatch = content.match(/\[autoload\]([\s\S]*?)(?=\n\[|$)/);
        if (autoloadMatch) {
          for (const line of autoloadMatch[1].split('\n')) {
            const kv = line.trim().match(/^([^=]+)=(.*)$/);
            if (kv) autoloads[kv[1].trim()] = kv[2].trim();
          }
        }
        return { content: [{ type: 'text', text: JSON.stringify(autoloads, null, 2) }] };
      } else if (args.action === 'add') {
        if (!args.name || !args.path)
          return createErrorResponse('name and path are required for add action.');
        const autoloadLine = `${args.name}="*${args.path}"`;
        if (content.includes('[autoload]')) {
          content = content.replace('[autoload]', `[autoload]\n\n${autoloadLine}`);
        } else {
          content += `\n[autoload]\n\n${autoloadLine}\n`;
        }
        writeFileSync(projectFile, content, 'utf8');
        return { content: [{ type: 'text', text: `Autoload "${args.name}" added: ${args.path}` }] };
      } else if (args.action === 'remove') {
        if (!args.name)
          return createErrorResponse('name is required for remove action.');
        const pattern = new RegExp(`\\n?${args.name}\\s*=.*\\n?`, 'g');
        content = content.replace(pattern, '\n');
        writeFileSync(projectFile, content, 'utf8');
        return { content: [{ type: 'text', text: `Autoload "${args.name}" removed.` }] };
      }
      return createErrorResponse('Invalid action. Use "list", "add", or "remove".');
    } catch (error: any) {
      return createErrorResponse(`Failed to manage autoloads: ${error?.message || 'Unknown error'}`);
    }
  }

  private async handleManageInputMap(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.action)
      return createErrorResponse('projectPath and action are required.');
    if (!validatePath(args.projectPath))
      return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile))
      return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    try {
      let content = readFileSync(projectFile, 'utf8');
      if (args.action === 'list') {
        const actions: Record<string, string> = {};
        const inputMatch = content.match(/\[input\]([\s\S]*?)(?=\n\[|$)/);
        if (inputMatch) {
          for (const line of inputMatch[1].split('\n')) {
            const kv = line.trim().match(/^([^=]+)=(.*)$/);
            if (kv) actions[kv[1].trim()] = kv[2].trim();
          }
        }
        return { content: [{ type: 'text', text: JSON.stringify(actions, null, 2) }] };
      } else if (args.action === 'add') {
        if (!args.actionName)
          return createErrorResponse('actionName is required for add action.');
        const deadzone = args.deadzone !== undefined ? args.deadzone : 0.5;
        let events = '';
        if (args.key) {
          events = `, "events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":${this.keyNameToScancode(args.key)},"key_label":0,"unicode":0,"location":0,"echo":false,"script":null)]`;
        }
        const inputLine = `${args.actionName}={"deadzone": ${deadzone}${events}}`;
        if (content.includes('[input]')) {
          content = content.replace('[input]', `[input]\n\n${inputLine}`);
        } else {
          content += `\n[input]\n\n${inputLine}\n`;
        }
        writeFileSync(projectFile, content, 'utf8');
        return { content: [{ type: 'text', text: `Input action "${args.actionName}" added.` }] };
      } else if (args.action === 'remove') {
        if (!args.actionName)
          return createErrorResponse('actionName is required for remove action.');
        const pattern = new RegExp(`\\n?${args.actionName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*=.*\\n?`, 'g');
        content = content.replace(pattern, '\n');
        writeFileSync(projectFile, content, 'utf8');
        return { content: [{ type: 'text', text: `Input action "${args.actionName}" removed.` }] };
      }
      return createErrorResponse('Invalid action. Use "list", "add", or "remove".');
    } catch (error: any) {
      return createErrorResponse(`Failed to manage input map: ${error?.message || 'Unknown error'}`);
    }
  }

  private keyNameToScancode(key: string): number {
    const map: Record<string, number> = {
      'A': 65, 'B': 66, 'C': 67, 'D': 68, 'E': 69, 'F': 70, 'G': 71, 'H': 72,
      'I': 73, 'J': 74, 'K': 75, 'L': 76, 'M': 77, 'N': 78, 'O': 79, 'P': 80,
      'Q': 81, 'R': 82, 'S': 83, 'T': 84, 'U': 85, 'V': 86, 'W': 87, 'X': 88,
      'Y': 89, 'Z': 90, 'SPACE': 32, 'ENTER': 16777221, 'ESCAPE': 16777217,
      'TAB': 16777218, 'BACKSPACE': 16777220, 'UP': 16777232, 'DOWN': 16777234,
      'LEFT': 16777231, 'RIGHT': 16777233, 'SHIFT': 16777237, 'CTRL': 16777238,
      'ALT': 16777240, 'F1': 16777244, 'F2': 16777245, 'F3': 16777246,
      'F4': 16777247, 'F5': 16777248, 'F6': 16777249, 'F7': 16777250,
      'F8': 16777251, 'F9': 16777252, 'F10': 16777253, 'F11': 16777254,
      'F12': 16777255,
    };
    const upper = key.toUpperCase();
    return map[upper] || (key.length === 1 ? key.charCodeAt(0) : 0);
  }

  private async handleManageExportPresets(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.action)
      return createErrorResponse('projectPath and action are required.');
    if (!validatePath(args.projectPath))
      return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile))
      return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    const presetsFile = join(args.projectPath, 'export_presets.cfg');
    try {
      if (args.action === 'list') {
        if (!existsSync(presetsFile))
          return { content: [{ type: 'text', text: JSON.stringify({ presets: [] }, null, 2) }] };
        const content = readFileSync(presetsFile, 'utf8');
        const presets: Array<{ name: string; platform: string }> = [];
        const nameMatches = content.matchAll(/name="([^"]+)"/g);
        const platformMatches = content.matchAll(/platform="([^"]+)"/g);
        const names = [...nameMatches].map(m => m[1]);
        const platforms = [...platformMatches].map(m => m[1]);
        for (let i = 0; i < names.length; i++) {
          presets.push({ name: names[i], platform: platforms[i] || 'unknown' });
        }
        return { content: [{ type: 'text', text: JSON.stringify({ presets }, null, 2) }] };
      } else if (args.action === 'add') {
        if (!args.name || !args.platform)
          return createErrorResponse('name and platform are required for add action.');
        const runnable = args.runnable ? 'true' : 'false';
        const presetBlock = `\n[preset.${Date.now()}]\n\nname="${args.name}"\nplatform="${args.platform}"\nrunnable=${runnable}\n`;
        let content = existsSync(presetsFile) ? readFileSync(presetsFile, 'utf8') : '';
        content += presetBlock;
        writeFileSync(presetsFile, content, 'utf8');
        return { content: [{ type: 'text', text: `Export preset "${args.name}" added for platform "${args.platform}".` }] };
      } else if (args.action === 'remove') {
        if (!args.name)
          return createErrorResponse('name is required for remove action.');
        if (!existsSync(presetsFile))
          return createErrorResponse('No export_presets.cfg file found.');
        let content = readFileSync(presetsFile, 'utf8');
        // Remove the preset section containing the given name
        const pattern = new RegExp(`\\[preset\\.[^\\]]+\\]\\s*\\n[\\s\\S]*?name="${args.name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"[\\s\\S]*?(?=\\[preset\\.|$)`, 'g');
        content = content.replace(pattern, '');
        writeFileSync(presetsFile, content, 'utf8');
        return { content: [{ type: 'text', text: `Export preset "${args.name}" removed.` }] };
      }
      return createErrorResponse('Invalid action. Use "list", "add", or "remove".');
    } catch (error: any) {
      return createErrorResponse(`Failed to manage export presets: ${error?.message || 'Unknown error'}`);
    }
  }

  // --- Advanced runtime handlers ---

  private async handleGameGetCamera() {
    return this.gameCommand('get_camera', {}, () => ({}));
  }

  private async handleGameSetCamera(args: any) {
    return this.gameCommand('set_camera', args, a => ({
      ...(a.position ? { position: a.position } : {}),
      ...(a.rotation ? { rotation: a.rotation } : {}),
      ...(a.zoom ? { zoom: a.zoom } : {}),
      ...(a.fov !== undefined ? { fov: a.fov } : {}),
    }));
  }

  private async handleGameRaycast(args: any) {
    args = normalizeParameters(args || {});
    if (!args.from || !args.to)
      return createErrorResponse('from and to are required.');
    return this.gameCommand('raycast', args, a => ({
      from: a.from, to: a.to, collision_mask: a.collisionMask ?? 0xFFFFFFFF,
    }));
  }

  private async handleGameGetAudio() {
    return this.gameCommand('get_audio', {}, () => ({}));
  }

  private async handleGameSpawnNode(args: any) {
    args = normalizeParameters(args || {});
    if (!args.type)
      return createErrorResponse('type is required.');
    return this.gameCommand('spawn_node', args, a => ({
      type: a.type, name: a.name || '', parent_path: a.parentPath || '/root',
      ...(a.properties ? { properties: a.properties } : {}),
    }));
  }

  private async handleGameSetShaderParam(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.paramName)
      return createErrorResponse('nodePath and paramName are required.');
    return this.gameCommand('set_shader_param', args, a => ({
      node_path: a.nodePath, param_name: a.paramName, value: a.value,
      ...(a.typeHint ? { type_hint: a.typeHint } : {}),
    }));
  }

  private async handleGameAudioPlay(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath)
      return createErrorResponse('nodePath is required.');
    return this.gameCommand('audio_play', args, a => ({
      node_path: a.nodePath, action: a.action || 'play',
      ...(a.stream ? { stream: a.stream } : {}),
      ...(a.volume !== undefined ? { volume: a.volume } : {}),
      ...(a.pitch !== undefined ? { pitch: a.pitch } : {}),
      ...(a.bus ? { bus: a.bus } : {}),
      ...(a.fromPosition !== undefined ? { from_position: a.fromPosition } : {}),
    }));
  }

  private async handleGameAudioBus(args: any) {
    return this.gameCommand('audio_bus', args, a => ({
      bus_name: a.busName || 'Master',
      ...(a.volume !== undefined ? { volume: a.volume } : {}),
      ...(a.mute !== undefined ? { mute: a.mute } : {}),
      ...(a.solo !== undefined ? { solo: a.solo } : {}),
    }));
  }

  private async handleGameNavigatePath(args: any) {
    args = normalizeParameters(args || {});
    if (!args.start || !args.end)
      return createErrorResponse('start and end are required.');
    return this.gameCommand('navigate_path', args, a => ({
      start: a.start, end: a.end, optimize: a.optimize ?? true,
    }));
  }

  private async handleGameTilemap(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath)
      return createErrorResponse('nodePath is required.');
    if (!args.action)
      return createErrorResponse('action is required.');
    return this.gameCommand('tilemap', args, a => ({
      node_path: a.nodePath, action: a.action,
      ...(a.x !== undefined ? { x: a.x } : {}),
      ...(a.y !== undefined ? { y: a.y } : {}),
      ...(a.cells ? { cells: a.cells } : {}),
      ...(a.sourceId !== undefined ? { source_id: a.sourceId } : {}),
    }));
  }

  private async handleGameAddCollision(args: any) {
    args = normalizeParameters(args || {});
    if (!args.parentPath || !args.shapeType)
      return createErrorResponse('parentPath and shapeType are required.');
    return this.gameCommand('add_collision', args, a => ({
      parent_path: a.parentPath, shape_type: a.shapeType,
      ...(a.shapeParams ? { shape_params: a.shapeParams } : {}),
      ...(a.collisionLayer !== undefined ? { collision_layer: a.collisionLayer } : {}),
      ...(a.collisionMask !== undefined ? { collision_mask: a.collisionMask } : {}),
      ...(a.disabled !== undefined ? { disabled: a.disabled } : {}),
    }));
  }

  private async handleGameEnvironment(args: any) {
    args = normalizeParameters(args || {});
    const params: Record<string, any> = { action: args.action || 'set' };
    // Pass through all environment settings
    const envKeys = [
      'backgroundMode', 'backgroundColor', 'ambientLightColor', 'ambientLightEnergy',
      'fogEnabled', 'fogDensity', 'fogLightColor',
      'glowEnabled', 'glowIntensity', 'glowBloom',
      'tonemapMode', 'ssaoEnabled', 'ssaoRadius', 'ssaoIntensity', 'ssrEnabled',
      'brightness', 'contrast', 'saturation',
    ];
    const snakeMap: Record<string, string> = {
      backgroundMode: 'background_mode', backgroundColor: 'background_color',
      ambientLightColor: 'ambient_light_color', ambientLightEnergy: 'ambient_light_energy',
      fogEnabled: 'fog_enabled', fogDensity: 'fog_density', fogLightColor: 'fog_light_color',
      glowEnabled: 'glow_enabled', glowIntensity: 'glow_intensity', glowBloom: 'glow_bloom',
      tonemapMode: 'tonemap_mode', ssaoEnabled: 'ssao_enabled', ssaoRadius: 'ssao_radius',
      ssaoIntensity: 'ssao_intensity', ssrEnabled: 'ssr_enabled',
      brightness: 'brightness', contrast: 'contrast', saturation: 'saturation',
    };
    for (const key of envKeys) {
      if (args[key] !== undefined) {
        params[snakeMap[key]] = args[key];
      }
    }
    return this.gameCommand('environment', { ...args }, () => params);
  }

  private async handleGameManageGroup(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action)
      return createErrorResponse('action is required.');
    return this.gameCommand('manage_group', args, a => ({
      action: a.action,
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.group ? { group: a.group } : {}),
    }));
  }

  private async handleGameCreateTimer(args: any) {
    return this.gameCommand('create_timer', args, a => ({
      parent_path: a.parentPath || '/root',
      wait_time: a.waitTime ?? 1.0,
      one_shot: a.oneShot ?? false,
      autostart: a.autostart ?? false,
      ...(a.name ? { name: a.name } : {}),
    }));
  }

  private async handleGameSetParticles(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath)
      return createErrorResponse('nodePath is required.');
    return this.gameCommand('set_particles', args, a => ({
      node_path: a.nodePath,
      ...(a.emitting !== undefined ? { emitting: a.emitting } : {}),
      ...(a.amount !== undefined ? { amount: a.amount } : {}),
      ...(a.lifetime !== undefined ? { lifetime: a.lifetime } : {}),
      ...(a.oneShot !== undefined ? { one_shot: a.oneShot } : {}),
      ...(a.speedScale !== undefined ? { speed_scale: a.speedScale } : {}),
      ...(a.explosiveness !== undefined ? { explosiveness: a.explosiveness } : {}),
      ...(a.randomness !== undefined ? { randomness: a.randomness } : {}),
      ...(a.processMaterial ? { process_material: a.processMaterial } : {}),
    }));
  }

  private async handleGameCreateAnimation(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.animationName)
      return createErrorResponse('nodePath and animationName are required.');
    return this.gameCommand('create_animation', args, a => ({
      node_path: a.nodePath,
      animation_name: a.animationName,
      length: a.length ?? 1.0,
      loop_mode: a.loopMode ?? 0,
      tracks: a.tracks || [],
      ...(a.library !== undefined ? { library: a.library } : {}),
    }));
  }

  private async handleExportProject(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.presetName || !args.outputPath)
      return createErrorResponse('projectPath, presetName, and outputPath are required.');
    if (!validatePath(args.projectPath))
      return createErrorResponse('Invalid project path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile))
      return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    if (!this.godotPath) {
      await this.detectGodotPath();
      if (!this.godotPath) return createErrorResponse('Could not find Godot executable.');
    }
    try {
      const exportFlag = args.debug ? '--export-debug' : '--export-release';
      const exportArgs = ['--headless', '--path', args.projectPath, exportFlag, args.presetName, args.outputPath];
      const { stdout, stderr } = await execFileAsync(this.godotPath!, exportArgs, { timeout: 120000 });
      if (stderr && stderr.includes('ERROR'))
        return createErrorResponse(`Export failed: ${stderr}`);
      return { content: [{ type: 'text', text: `Export succeeded.\n\nOutput: ${stdout || args.outputPath}` }] };
    } catch (error: any) {
      return createErrorResponse(`Export failed: ${error?.message || 'Unknown error'}`);
    }
  }

  private async handleGameSerializeState(args: any) {
    args = normalizeParameters(args || {});
    return this.gameCommand('serialize_state', args, a => ({
      node_path: a.nodePath || '/root',
      action: a.action || 'save',
      max_depth: a.maxDepth ?? 5,
      ...(a.data ? { data: a.data } : {}),
    }));
  }

  private async handleGamePhysicsBody(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath)
      return createErrorResponse('nodePath is required.');
    return this.gameCommand('physics_body', args, a => ({
      node_path: a.nodePath,
      ...(a.gravityScale !== undefined ? { gravity_scale: a.gravityScale } : {}),
      ...(a.mass !== undefined ? { mass: a.mass } : {}),
      ...(a.linearVelocity ? { linear_velocity: a.linearVelocity } : {}),
      ...(a.angularVelocity !== undefined ? { angular_velocity: a.angularVelocity } : {}),
      ...(a.linearDamp !== undefined ? { linear_damp: a.linearDamp } : {}),
      ...(a.angularDamp !== undefined ? { angular_damp: a.angularDamp } : {}),
      ...(a.friction !== undefined ? { friction: a.friction } : {}),
      ...(a.bounce !== undefined ? { bounce: a.bounce } : {}),
      ...(a.freeze !== undefined ? { freeze: a.freeze } : {}),
      ...(a.sleeping !== undefined ? { sleeping: a.sleeping } : {}),
    }));
  }

  private async handleGameCreateJoint(args: any) {
    args = normalizeParameters(args || {});
    if (!args.parentPath || !args.jointType)
      return createErrorResponse('parentPath and jointType are required.');
    return this.gameCommand('create_joint', args, a => ({
      parent_path: a.parentPath,
      joint_type: a.jointType,
      ...(a.nodeAPath ? { node_a_path: a.nodeAPath } : {}),
      ...(a.nodeBPath ? { node_b_path: a.nodeBPath } : {}),
      ...(a.stiffness !== undefined ? { stiffness: a.stiffness } : {}),
      ...(a.damping !== undefined ? { damping: a.damping } : {}),
      ...(a.length !== undefined ? { length: a.length } : {}),
      ...(a.restLength !== undefined ? { rest_length: a.restLength } : {}),
      ...(a.softness !== undefined ? { softness: a.softness } : {}),
      ...(a.initialOffset !== undefined ? { initial_offset: a.initialOffset } : {}),
    }));
  }

  private async handleGameBonePose(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath)
      return createErrorResponse('nodePath is required.');
    return this.gameCommand('bone_pose', args, a => ({
      node_path: a.nodePath,
      action: a.action || 'list',
      ...(a.boneIndex !== undefined ? { bone_index: a.boneIndex } : {}),
      ...(a.boneName ? { bone_name: a.boneName } : {}),
      ...(a.position ? { position: a.position } : {}),
      ...(a.rotation ? { rotation: a.rotation } : {}),
      ...(a.scale ? { scale: a.scale } : {}),
    }));
  }

  private async handleGameUiTheme(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.overrides)
      return createErrorResponse('nodePath and overrides are required.');
    return this.gameCommand('ui_theme', args, a => ({
      node_path: a.nodePath,
      overrides: a.overrides,
    }));
  }

  private async handleGameViewport(args: any) {
    args = normalizeParameters(args || {});
    return this.gameCommand('viewport', args, a => ({
      action: a.action || 'create',
      ...(a.parentPath ? { parent_path: a.parentPath } : {}),
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.width !== undefined ? { width: a.width } : {}),
      ...(a.height !== undefined ? { height: a.height } : {}),
      ...(a.msaa !== undefined ? { msaa: a.msaa } : {}),
      ...(a.transparentBg !== undefined ? { transparent_bg: a.transparentBg } : {}),
      ...(a.name ? { name: a.name } : {}),
    }));
  }

  private async handleGameDebugDraw(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action)
      return createErrorResponse('action is required.');
    return this.gameCommand('debug_draw', args, a => ({
      action: a.action,
      ...(a.from ? { from: a.from } : {}),
      ...(a.to ? { to: a.to } : {}),
      ...(a.center ? { center: a.center } : {}),
      ...(a.radius !== undefined ? { radius: a.radius } : {}),
      ...(a.size ? { size: a.size } : {}),
      ...(a.color ? { color: a.color } : {}),
      ...(a.duration !== undefined ? { duration: a.duration } : {}),
    }));
  }

  // --- Batch 1: Networking + Input + System + Signals + Script ---
  private async handleGameHttpRequest(args: any) {
    args = normalizeParameters(args || {});
    if (!args.url) return createErrorResponse('url is required.');
    return this.gameCommand('http_request', args, a => ({
      url: a.url, method: a.method || 'GET',
      ...(a.headers ? { headers: a.headers } : {}),
      ...(a.body ? { body: a.body } : {}),
      ...(a.timeout !== undefined ? { timeout: a.timeout } : {}),
    }), 35000);
  }

  private async handleGameWebsocket(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('websocket', args, a => ({
      action: a.action,
      ...(a.url ? { url: a.url } : {}),
      ...(a.message ? { message: a.message } : {}),
    }), 15000);
  }

  private async handleGameMultiplayer(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('multiplayer', args, a => ({
      action: a.action,
      ...(a.port !== undefined ? { port: a.port } : {}),
      ...(a.address ? { address: a.address } : {}),
      ...(a.maxClients !== undefined ? { max_clients: a.maxClients } : {}),
    }));
  }

  private async handleGameRpc(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.action || !args.method) return createErrorResponse('nodePath, action, and method are required.');
    return this.gameCommand('rpc', args, a => ({
      node_path: a.nodePath, action: a.action, method: a.method,
      ...(a.args ? { args: a.args } : {}),
      ...(a.mode ? { mode: a.mode } : {}),
      ...(a.sync ? { sync: a.sync } : {}),
      ...(a.channel !== undefined ? { channel: a.channel } : {}),
    }));
  }

  private async handleGameTouch(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('touch', args, a => ({
      action: a.action, x: a.x ?? 0, y: a.y ?? 0,
      ...(a.index !== undefined ? { index: a.index } : {}),
      ...(a.toX !== undefined ? { to_x: a.toX } : {}),
      ...(a.toY !== undefined ? { to_y: a.toY } : {}),
      ...(a.steps !== undefined ? { steps: a.steps } : {}),
    }), 15000);
  }

  private async handleGameInputState(args: any) {
    args = normalizeParameters(args || {});
    return this.gameCommand('input_state', args, a => ({
      action: a.action || 'query',
      ...(a.x !== undefined ? { x: a.x } : {}),
      ...(a.y !== undefined ? { y: a.y } : {}),
      ...(a.mouseMode ? { mouse_mode: a.mouseMode } : {}),
    }));
  }

  private async handleGameInputAction(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('input_action', args, a => ({
      action: a.action,
      ...(a.actionName ? { action_name: a.actionName } : {}),
      ...(a.strength !== undefined ? { strength: a.strength } : {}),
      ...(a.key ? { key: a.key } : {}),
    }));
  }

  private async handleGameListSignals(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath) return createErrorResponse('nodePath is required.');
    return this.gameCommand('list_signals', args, a => ({ node_path: a.nodePath }));
  }

  private async handleGameAwaitSignal(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.signalName) return createErrorResponse('nodePath and signalName are required.');
    const timeout = (args.timeout || 10) * 1000 + 2000;
    return this.gameCommand('await_signal', args, a => ({
      node_path: a.nodePath, signal_name: a.signalName, timeout: a.timeout || 10,
    }), timeout);
  }

  private async handleGameScript(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.action) return createErrorResponse('nodePath and action are required.');
    return this.gameCommand('script', args, a => ({
      node_path: a.nodePath, action: a.action,
      ...(a.source ? { source: a.source } : {}),
      ...(a.className ? { class_name: a.className } : {}),
    }));
  }

  private async handleGameWindow(args: any) {
    args = normalizeParameters(args || {});
    return this.gameCommand('window', args, a => ({
      action: a.action || 'get',
      ...(a.width !== undefined ? { width: a.width } : {}),
      ...(a.height !== undefined ? { height: a.height } : {}),
      ...(a.fullscreen !== undefined ? { fullscreen: a.fullscreen } : {}),
      ...(a.borderless !== undefined ? { borderless: a.borderless } : {}),
      ...(a.title ? { title: a.title } : {}),
      ...(a.position ? { position: a.position } : {}),
      ...(a.vsync !== undefined ? { vsync: a.vsync } : {}),
    }));
  }

  private async handleGameOsInfo(_args: any) {
    return this.gameCommand('os_info', {}, () => ({}));
  }

  private async handleGameTimeScale(args: any) {
    args = normalizeParameters(args || {});
    return this.gameCommand('time_scale', args, a => ({
      action: a.action || 'get',
      ...(a.timeScale !== undefined ? { time_scale: a.timeScale } : {}),
    }));
  }

  private async handleGameProcessMode(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.mode) return createErrorResponse('nodePath and mode are required.');
    return this.gameCommand('process_mode', args, a => ({
      node_path: a.nodePath, mode: a.mode,
    }));
  }

  private async handleGameWorldSettings(args: any) {
    args = normalizeParameters(args || {});
    return this.gameCommand('world_settings', args, a => ({
      action: a.action || 'get',
      ...(a.gravity !== undefined ? { gravity: a.gravity } : {}),
      ...(a.gravityDirection ? { gravity_direction: a.gravityDirection } : {}),
      ...(a.physicsFps !== undefined ? { physics_fps: a.physicsFps } : {}),
    }));
  }

  // --- Batch 2: 3D Rendering + Lighting + Sky + Physics ---
  private async handleGameCsg(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('csg', args, a => ({
      action: a.action,
      ...(a.parentPath ? { parent_path: a.parentPath } : {}),
      ...(a.csgType ? { csg_type: a.csgType } : {}),
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.operation ? { operation: a.operation } : {}),
      ...(a.size ? { size: a.size } : {}),
      ...(a.radius !== undefined ? { radius: a.radius } : {}),
      ...(a.height !== undefined ? { height: a.height } : {}),
      ...(a.material ? { material: a.material } : {}),
      ...(a.name ? { name: a.name } : {}),
    }));
  }

  private async handleGameMultimesh(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('multimesh', args, a => ({
      action: a.action,
      ...(a.parentPath ? { parent_path: a.parentPath } : {}),
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.meshType ? { mesh_type: a.meshType } : {}),
      ...(a.count !== undefined ? { count: a.count } : {}),
      ...(a.index !== undefined ? { index: a.index } : {}),
      ...(a.transform ? { transform: a.transform } : {}),
      ...(a.name ? { name: a.name } : {}),
    }));
  }

  private async handleGameProceduralMesh(args: any) {
    args = normalizeParameters(args || {});
    if (!args.parentPath || !args.vertices) return createErrorResponse('parentPath and vertices are required.');
    return this.gameCommand('procedural_mesh', args, a => ({
      parent_path: a.parentPath, vertices: a.vertices,
      ...(a.normals ? { normals: a.normals } : {}),
      ...(a.uvs ? { uvs: a.uvs } : {}),
      ...(a.indices ? { indices: a.indices } : {}),
      ...(a.name ? { name: a.name } : {}),
    }));
  }

  private async handleGameLight3d(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('light_3d', args, a => ({
      action: a.action,
      ...(a.parentPath ? { parent_path: a.parentPath } : {}),
      ...(a.lightType ? { light_type: a.lightType } : {}),
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.color ? { color: a.color } : {}),
      ...(a.energy !== undefined ? { energy: a.energy } : {}),
      ...(a.range !== undefined ? { range: a.range } : {}),
      ...(a.shadows !== undefined ? { shadows: a.shadows } : {}),
      ...(a.spotAngle !== undefined ? { spot_angle: a.spotAngle } : {}),
      ...(a.name ? { name: a.name } : {}),
    }));
  }

  private async handleGameMeshInstance(args: any) {
    args = normalizeParameters(args || {});
    if (!args.parentPath || !args.meshType) return createErrorResponse('parentPath and meshType are required.');
    return this.gameCommand('mesh_instance', args, a => ({
      parent_path: a.parentPath, mesh_type: a.meshType,
      ...(a.size ? { size: a.size } : {}),
      ...(a.radius !== undefined ? { radius: a.radius } : {}),
      ...(a.height !== undefined ? { height: a.height } : {}),
      ...(a.material ? { material: a.material } : {}),
      ...(a.name ? { name: a.name } : {}),
    }));
  }

  private async handleGameGridmap(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.action) return createErrorResponse('nodePath and action are required.');
    return this.gameCommand('gridmap', args, a => ({
      node_path: a.nodePath, action: a.action,
      ...(a.x !== undefined ? { x: a.x } : {}),
      ...(a.y !== undefined ? { y: a.y } : {}),
      ...(a.z !== undefined ? { z: a.z } : {}),
      ...(a.item !== undefined ? { item: a.item } : {}),
      ...(a.orientation !== undefined ? { orientation: a.orientation } : {}),
    }));
  }

  private async handleGame3dEffects(args: any) {
    args = normalizeParameters(args || {});
    if (!args.parentPath || !args.effectType) return createErrorResponse('parentPath and effectType are required.');
    return this.gameCommand('3d_effects', args, a => ({
      parent_path: a.parentPath, effect_type: a.effectType,
      ...(a.size ? { size: a.size } : {}),
      ...(a.intensity !== undefined ? { intensity: a.intensity } : {}),
      ...(a.name ? { name: a.name } : {}),
    }));
  }

  private async handleGameGi(args: any) {
    args = normalizeParameters(args || {});
    if (!args.parentPath || !args.giType) return createErrorResponse('parentPath and giType are required.');
    return this.gameCommand('gi', args, a => ({
      parent_path: a.parentPath, gi_type: a.giType,
      ...(a.size ? { size: a.size } : {}),
      ...(a.name ? { name: a.name } : {}),
    }));
  }

  private async handleGamePath3d(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('path_3d', args, a => ({
      action: a.action,
      ...(a.parentPath ? { parent_path: a.parentPath } : {}),
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.points ? { points: a.points } : {}),
      ...(a.point ? { point: a.point } : {}),
      ...(a.name ? { name: a.name } : {}),
    }));
  }

  private async handleGameSky(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('sky', args, a => ({
      action: a.action,
      ...(a.skyType ? { sky_type: a.skyType } : {}),
      ...(a.topColor ? { top_color: a.topColor } : {}),
      ...(a.bottomColor ? { bottom_color: a.bottomColor } : {}),
      ...(a.sunEnergy !== undefined ? { sun_energy: a.sunEnergy } : {}),
      ...(a.groundColor ? { ground_color: a.groundColor } : {}),
    }));
  }

  private async handleGameCameraAttributes(args: any) {
    args = normalizeParameters(args || {});
    return this.gameCommand('camera_attributes', args, a => ({
      action: a.action || 'get',
      ...(a.dofBlurFar !== undefined ? { dof_blur_far: a.dofBlurFar } : {}),
      ...(a.dofBlurNear !== undefined ? { dof_blur_near: a.dofBlurNear } : {}),
      ...(a.dofBlurAmount !== undefined ? { dof_blur_amount: a.dofBlurAmount } : {}),
      ...(a.exposureMultiplier !== undefined ? { exposure_multiplier: a.exposureMultiplier } : {}),
      ...(a.autoExposure !== undefined ? { auto_exposure: a.autoExposure } : {}),
      ...(a.autoExposureScale !== undefined ? { auto_exposure_scale: a.autoExposureScale } : {}),
    }));
  }

  private async handleGameNavigation3d(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('navigation_3d', args, a => ({
      action: a.action,
      ...(a.parentPath ? { parent_path: a.parentPath } : {}),
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.cellSize !== undefined ? { cell_size: a.cellSize } : {}),
      ...(a.agentRadius !== undefined ? { agent_radius: a.agentRadius } : {}),
      ...(a.agentHeight !== undefined ? { agent_height: a.agentHeight } : {}),
      ...(a.name ? { name: a.name } : {}),
    }), 30000);
  }

  private async handleGamePhysics3d(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('physics_3d', args, a => ({
      action: a.action,
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.from ? { from: a.from } : {}),
      ...(a.to ? { to: a.to } : {}),
      ...(a.collisionMask !== undefined ? { collision_mask: a.collisionMask } : {}),
    }), 15000);
  }

  // --- Batch 3: 2D Systems + Animation Advanced + Audio Effects ---
  private async handleGameCanvas(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('canvas', args, a => ({
      action: a.action,
      ...(a.parentPath ? { parent_path: a.parentPath } : {}),
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.layer !== undefined ? { layer: a.layer } : {}),
      ...(a.color ? { color: a.color } : {}),
      ...(a.name ? { name: a.name } : {}),
    }));
  }

  private async handleGameCanvasDraw(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('canvas_draw', args, a => ({
      action: a.action,
      ...(a.parentPath ? { parent_path: a.parentPath } : {}),
      ...(a.from ? { from: a.from } : {}),
      ...(a.to ? { to: a.to } : {}),
      ...(a.center ? { center: a.center } : {}),
      ...(a.radius !== undefined ? { radius: a.radius } : {}),
      ...(a.rect ? { rect: a.rect } : {}),
      ...(a.points ? { points: a.points } : {}),
      ...(a.text ? { text: a.text } : {}),
      ...(a.color ? { color: a.color } : {}),
      ...(a.width !== undefined ? { width: a.width } : {}),
      ...(a.filled !== undefined ? { filled: a.filled } : {}),
    }));
  }

  private async handleGameLight2d(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('light_2d', args, a => ({
      action: a.action,
      ...(a.parentPath ? { parent_path: a.parentPath } : {}),
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.color ? { color: a.color } : {}),
      ...(a.energy !== undefined ? { energy: a.energy } : {}),
      ...(a.range !== undefined ? { range: a.range } : {}),
      ...(a.name ? { name: a.name } : {}),
    }));
  }

  private async handleGameParallax(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('parallax', args, a => ({
      action: a.action,
      ...(a.parentPath ? { parent_path: a.parentPath } : {}),
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.motionScale ? { motion_scale: a.motionScale } : {}),
      ...(a.motionOffset ? { motion_offset: a.motionOffset } : {}),
      ...(a.mirroring ? { mirroring: a.mirroring } : {}),
      ...(a.name ? { name: a.name } : {}),
    }));
  }

  private async handleGameShape2d(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.action) return createErrorResponse('nodePath and action are required.');
    return this.gameCommand('shape_2d', args, a => ({
      node_path: a.nodePath, action: a.action,
      ...(a.points ? { points: a.points } : {}),
      ...(a.point ? { point: a.point } : {}),
      ...(a.width !== undefined ? { width: a.width } : {}),
      ...(a.color ? { color: a.color } : {}),
    }));
  }

  private async handleGamePath2d(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('path_2d', args, a => ({
      action: a.action,
      ...(a.parentPath ? { parent_path: a.parentPath } : {}),
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.points ? { points: a.points } : {}),
      ...(a.point ? { point: a.point } : {}),
      ...(a.name ? { name: a.name } : {}),
    }));
  }

  private async handleGamePhysics2d(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('physics_2d', args, a => ({
      action: a.action,
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.from ? { from: a.from } : {}),
      ...(a.to ? { to: a.to } : {}),
      ...(a.collisionMask !== undefined ? { collision_mask: a.collisionMask } : {}),
    }), 15000);
  }

  private async handleGameAnimationTree(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.action) return createErrorResponse('nodePath and action are required.');
    return this.gameCommand('animation_tree', args, a => ({
      node_path: a.nodePath, action: a.action,
      ...(a.stateName ? { state_name: a.stateName } : {}),
      ...(a.paramName ? { param_name: a.paramName } : {}),
      ...(a.paramValue !== undefined ? { param_value: a.paramValue } : {}),
    }));
  }

  private async handleGameAnimationControl(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.action) return createErrorResponse('nodePath and action are required.');
    return this.gameCommand('animation_control', args, a => ({
      node_path: a.nodePath, action: a.action,
      ...(a.animationName ? { animation_name: a.animationName } : {}),
      ...(a.position !== undefined ? { position: a.position } : {}),
      ...(a.speed !== undefined ? { speed: a.speed } : {}),
    }));
  }

  private async handleGameSkeletonIk(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.action) return createErrorResponse('nodePath and action are required.');
    return this.gameCommand('skeleton_ik', args, a => ({
      node_path: a.nodePath, action: a.action,
      ...(a.target ? { target: a.target } : {}),
    }));
  }

  private async handleGameAudioEffect(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('audio_effect', args, a => ({
      action: a.action, bus_name: a.busName || 'Master',
      ...(a.effectType ? { effect_type: a.effectType } : {}),
      ...(a.index !== undefined ? { index: a.index } : {}),
      ...(a.properties ? { properties: a.properties } : {}),
    }));
  }

  private async handleGameAudioBusLayout(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('audio_bus_layout', args, a => ({
      action: a.action,
      ...(a.busName ? { bus_name: a.busName } : {}),
      ...(a.sendTo ? { send_to: a.sendTo } : {}),
      ...(a.index !== undefined ? { index: a.index } : {}),
    }));
  }

  private async handleGameAudioSpatial(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.action) return createErrorResponse('nodePath and action are required.');
    return this.gameCommand('audio_spatial', args, a => ({
      node_path: a.nodePath, action: a.action,
      ...(a.maxDistance !== undefined ? { max_distance: a.maxDistance } : {}),
      ...(a.unitSize !== undefined ? { unit_size: a.unitSize } : {}),
      ...(a.maxDb !== undefined ? { max_db: a.maxDb } : {}),
      ...(a.attenuationModel ? { attenuation_model: a.attenuationModel } : {}),
    }));
  }

  // --- Batch 4: Editor/Headless + Localization + Resource ---
  private async handleRenameFile(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.filePath || !args.newPath) return createErrorResponse('projectPath, filePath, and newPath are required.');
    if (!validatePath(args.projectPath) || !validatePath(args.filePath) || !validatePath(args.newPath)) return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    const srcFull = this.resolveResPath(args.projectPath, args.filePath);
    const dstFull = join(args.projectPath, args.newPath);
    if (!existsSync(srcFull)) return createErrorResponse(`File not found: ${args.filePath}`);
    try {
      const dstDir = dirname(dstFull);
      if (!existsSync(dstDir)) mkdirSync(dstDir, { recursive: true });
      renameSync(srcFull, dstFull);
      return { content: [{ type: 'text', text: `Renamed ${args.filePath} → ${args.newPath}` }] };
    } catch (error: any) {
      return createErrorResponse(`rename_file failed: ${error?.message || 'Unknown error'}`);
    }
  }

  private async handleManageResource(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.resourcePath || !args.action) return createErrorResponse('projectPath, resourcePath, and action are required.');
    return this.headlessOp('manage_resource', args, a => ({
      projectPath: a.projectPath,
      params: { resourcePath: a.resourcePath, action: a.action, ...(a.properties ? { properties: a.properties } : {}) },
    }));
  }

  private async handleCreateScript(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scriptPath) return createErrorResponse('projectPath and scriptPath are required.');
    if (!validatePath(args.projectPath) || !validatePath(args.scriptPath)) return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    try {
      const fullPath = join(args.projectPath, args.scriptPath);
      const dir = dirname(fullPath);
      if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
      let source = args.source;
      if (!source) {
        const ext = args.extends || 'Node';
        const lines = [`extends ${ext}`, ''];
        if (args.className) lines.splice(1, 0, `class_name ${args.className}`);
        if (args.methods && Array.isArray(args.methods)) {
          for (const m of args.methods) {
            lines.push('', `func ${m}():`);
            lines.push('\tpass');
          }
        }
        source = lines.join('\n') + '\n';
      }
      writeFileSync(fullPath, source, 'utf8');
      return { content: [{ type: 'text', text: `Script created at ${args.scriptPath}` }] };
    } catch (error: any) {
      return createErrorResponse(`create_script failed: ${error?.message || 'Unknown error'}`);
    }
  }

  private async handleManageSceneSignals(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.action) return createErrorResponse('projectPath, scenePath, and action are required.');
    return this.headlessOp('manage_scene_signals', args, a => ({
      projectPath: a.projectPath,
      params: {
        scenePath: a.scenePath, action: a.action,
        ...(a.signalName ? { signalName: a.signalName } : {}),
        ...(a.sourcePath ? { sourcePath: a.sourcePath } : {}),
        ...(a.targetPath ? { targetPath: a.targetPath } : {}),
        ...(a.method ? { method: a.method } : {}),
      },
    }));
  }

  private async handleManageLayers(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.action) return createErrorResponse('projectPath and action are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    try {
      let content = readFileSync(projectFile, 'utf8');
      if (args.action === 'list') {
        const layerRegex = /layer_names\/([\w_]+)\/layer_(\d+)="([^"]+)"/g;
        const layers: any[] = [];
        let match;
        while ((match = layerRegex.exec(content)) !== null) {
          layers.push({ type: match[1], layer: parseInt(match[2]), name: match[3] });
        }
        return { content: [{ type: 'text', text: JSON.stringify({ layers }, null, 2) }] };
      } else if (args.action === 'set') {
        if (!args.layerType || !args.layer || !args.name) return createErrorResponse('layerType, layer, and name are required for set.');
        const key = `layer_names/${args.layerType}/layer_${args.layer}`;
        const settingLine = `${key}="${args.name}"`;
        const existingRegex = new RegExp(`${key.replace(/\//g, '\\/')}="[^"]*"`);
        if (existingRegex.test(content)) {
          content = content.replace(existingRegex, settingLine);
        } else {
          if (!content.includes('[layer_names]')) content += '\n[layer_names]\n';
          content = content.replace('[layer_names]', `[layer_names]\n${settingLine}`);
        }
        writeFileSync(projectFile, content, 'utf8');
        return { content: [{ type: 'text', text: `Layer set: ${settingLine}` }] };
      }
      return createErrorResponse(`Unknown action: ${args.action}`);
    } catch (error: any) {
      return createErrorResponse(`manage_layers failed: ${error?.message || 'Unknown error'}`);
    }
  }

  private async handleManagePlugins(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.action) return createErrorResponse('projectPath and action are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    try {
      let content = readFileSync(projectFile, 'utf8');
      if (args.action === 'list') {
        const pluginRegex = /(\w+)\/enabled=true/g;
        const plugins: string[] = [];
        let match;
        while ((match = pluginRegex.exec(content)) !== null) {
          plugins.push(match[1]);
        }
        const addonsDir = join(args.projectPath, 'addons');
        const available: string[] = [];
        if (existsSync(addonsDir)) {
          const entries = readdirSync(addonsDir, { withFileTypes: true });
          for (const e of entries) {
            if (e.isDirectory()) available.push(e.name);
          }
        }
        return { content: [{ type: 'text', text: JSON.stringify({ enabled: plugins, available }, null, 2) }] };
      } else if (args.action === 'enable' || args.action === 'disable') {
        if (!args.pluginName) return createErrorResponse('pluginName is required.');
        const key = `${args.pluginName}/enabled`;
        const val = args.action === 'enable' ? 'true' : 'false';
        const existingRegex = new RegExp(`${args.pluginName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\/enabled=\\w+`);
        if (existingRegex.test(content)) {
          content = content.replace(existingRegex, `${key}=${val}`);
        } else {
          if (!content.includes('[editor_plugins]')) content += '\n[editor_plugins]\n';
          content = content.replace('[editor_plugins]', `[editor_plugins]\n${key}=${val}`);
        }
        writeFileSync(projectFile, content, 'utf8');
        return { content: [{ type: 'text', text: `Plugin ${args.pluginName} ${args.action}d.` }] };
      }
      return createErrorResponse(`Unknown action: ${args.action}`);
    } catch (error: any) {
      return createErrorResponse(`manage_plugins failed: ${error?.message || 'Unknown error'}`);
    }
  }

  private async handleManageShader(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.shaderPath || !args.action) return createErrorResponse('projectPath, shaderPath, and action are required.');
    if (!validatePath(args.projectPath) || !validatePath(args.shaderPath)) return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    const fullPath = join(args.projectPath, args.shaderPath);
    try {
      if (args.action === 'read') {
        if (!existsSync(fullPath)) return createErrorResponse(`Shader not found: ${args.shaderPath}`);
        const source = readFileSync(fullPath, 'utf8');
        return { content: [{ type: 'text', text: source }] };
      } else if (args.action === 'create') {
        const dir = dirname(fullPath);
        if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
        let source = args.source;
        if (!source) {
          const type = args.shaderType || 'spatial';
          source = `shader_type ${type};\n\nvoid fragment() {\n\t// Called for every pixel the material is visible on.\n}\n`;
        }
        writeFileSync(fullPath, source, 'utf8');
        return { content: [{ type: 'text', text: `Shader created at ${args.shaderPath}` }] };
      }
      return createErrorResponse(`Unknown action: ${args.action}`);
    } catch (error: any) {
      return createErrorResponse(`manage_shader failed: ${error?.message || 'Unknown error'}`);
    }
  }

  private async handleManageThemeResource(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.resourcePath || !args.action) return createErrorResponse('projectPath, resourcePath, and action are required.');
    return this.headlessOp('manage_theme_resource', args, a => ({
      projectPath: a.projectPath,
      params: { resourcePath: a.resourcePath, action: a.action, ...(a.properties ? { properties: a.properties } : {}) },
    }));
  }

  private async handleSetMainScene(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath) return createErrorResponse('projectPath and scenePath are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    try {
      let content = readFileSync(projectFile, 'utf8');
      const resPath = args.scenePath.startsWith('res://') ? args.scenePath : `res://${args.scenePath}`;
      const settingLine = `run/main_scene="${resPath}"`;
      const existingRegex = /run\/main_scene="[^"]*"/;
      if (existingRegex.test(content)) {
        content = content.replace(existingRegex, settingLine);
      } else {
        if (content.includes('[application]')) {
          content = content.replace('[application]', `[application]\n\n${settingLine}`);
        } else {
          content += `\n[application]\n\n${settingLine}\n`;
        }
      }
      writeFileSync(projectFile, content, 'utf8');
      return { content: [{ type: 'text', text: `Main scene set to ${resPath}` }] };
    } catch (error: any) {
      return createErrorResponse(`set_main_scene failed: ${error?.message || 'Unknown error'}`);
    }
  }

  private async handleManageSceneStructure(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.action || !args.nodePath)
      return createErrorResponse('projectPath, scenePath, action, and nodePath are required.');
    return this.headlessOp('manage_scene_structure', args, a => ({
      projectPath: a.projectPath,
      params: {
        scenePath: a.scenePath, action: a.action, nodePath: a.nodePath,
        ...(a.newName ? { newName: a.newName } : {}),
        ...(a.newParentPath ? { newParentPath: a.newParentPath } : {}),
      },
    }));
  }

  private async handleManageTranslations(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.action) return createErrorResponse('projectPath and action are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    try {
      let content = readFileSync(projectFile, 'utf8');
      if (args.action === 'list') {
        const match = content.match(/translations=PackedStringArray\(([^)]*)\)/);
        const translations = match ? match[1].split(',').map(s => s.trim().replace(/"/g, '')).filter(Boolean) : [];
        return { content: [{ type: 'text', text: JSON.stringify({ translations }, null, 2) }] };
      } else if (args.action === 'add') {
        if (!args.translationPath) return createErrorResponse('translationPath is required.');
        const resPath = args.translationPath.startsWith('res://') ? args.translationPath : `res://${args.translationPath}`;
        const match = content.match(/translations=PackedStringArray\(([^)]*)\)/);
        if (match) {
          const existing = match[1];
          const newVal = existing ? `${existing}, "${resPath}"` : `"${resPath}"`;
          content = content.replace(/translations=PackedStringArray\([^)]*\)/, `translations=PackedStringArray(${newVal})`);
        } else {
          if (!content.includes('[internationalization]')) content += '\n[internationalization]\n';
          content = content.replace('[internationalization]', `[internationalization]\n\ntranslations=PackedStringArray("${resPath}")`);
        }
        writeFileSync(projectFile, content, 'utf8');
        return { content: [{ type: 'text', text: `Translation added: ${resPath}` }] };
      } else if (args.action === 'remove') {
        if (!args.translationPath) return createErrorResponse('translationPath is required.');
        const resPath = args.translationPath.startsWith('res://') ? args.translationPath : `res://${args.translationPath}`;
        content = content.replace(new RegExp(`,?\\s*"${resPath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`), '');
        writeFileSync(projectFile, content, 'utf8');
        return { content: [{ type: 'text', text: `Translation removed: ${resPath}` }] };
      }
      return createErrorResponse(`Unknown action: ${args.action}`);
    } catch (error: any) {
      return createErrorResponse(`manage_translations failed: ${error?.message || 'Unknown error'}`);
    }
  }

  private async handleGameLocale(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('locale', args, a => ({
      action: a.action,
      ...(a.locale ? { locale: a.locale } : {}),
      ...(a.key ? { key: a.key } : {}),
    }));
  }

  // --- Batch 5: UI Controls + Rendering + Resource Runtime ---
  private async handleGameUiControl(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.action) return createErrorResponse('nodePath and action are required.');
    return this.gameCommand('ui_control', args, a => ({
      node_path: a.nodePath, action: a.action,
      ...(a.anchorPreset !== undefined ? { anchor_preset: a.anchorPreset } : {}),
      ...(a.tooltip ? { tooltip: a.tooltip } : {}),
      ...(a.mouseFilter ? { mouse_filter: a.mouseFilter } : {}),
      ...(a.minSize ? { min_size: a.minSize } : {}),
    }));
  }

  private async handleGameUiText(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.action) return createErrorResponse('nodePath and action are required.');
    return this.gameCommand('ui_text', args, a => ({
      node_path: a.nodePath, action: a.action,
      ...(a.text !== undefined ? { text: a.text } : {}),
      ...(a.caretPosition !== undefined ? { caret_position: a.caretPosition } : {}),
      ...(a.selectionFrom !== undefined ? { selection_from: a.selectionFrom } : {}),
      ...(a.selectionTo !== undefined ? { selection_to: a.selectionTo } : {}),
    }));
  }

  private async handleGameUiPopup(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.action) return createErrorResponse('nodePath and action are required.');
    return this.gameCommand('ui_popup', args, a => ({
      node_path: a.nodePath, action: a.action,
      ...(a.size ? { size: a.size } : {}),
      ...(a.title ? { title: a.title } : {}),
      ...(a.text ? { text: a.text } : {}),
    }));
  }

  private async handleGameUiTree(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.action) return createErrorResponse('nodePath and action are required.');
    return this.gameCommand('ui_tree', args, a => ({
      node_path: a.nodePath, action: a.action,
      ...(a.itemPath ? { item_path: a.itemPath } : {}),
      ...(a.text ? { text: a.text } : {}),
      ...(a.column !== undefined ? { column: a.column } : {}),
    }));
  }

  private async handleGameUiItemList(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.action) return createErrorResponse('nodePath and action are required.');
    return this.gameCommand('ui_item_list', args, a => ({
      node_path: a.nodePath, action: a.action,
      ...(a.index !== undefined ? { index: a.index } : {}),
      ...(a.text ? { text: a.text } : {}),
    }));
  }

  private async handleGameUiTabs(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.action) return createErrorResponse('nodePath and action are required.');
    return this.gameCommand('ui_tabs', args, a => ({
      node_path: a.nodePath, action: a.action,
      ...(a.index !== undefined ? { index: a.index } : {}),
      ...(a.title ? { title: a.title } : {}),
    }));
  }

  private async handleGameUiMenu(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.action) return createErrorResponse('nodePath and action are required.');
    return this.gameCommand('ui_menu', args, a => ({
      node_path: a.nodePath, action: a.action,
      ...(a.index !== undefined ? { index: a.index } : {}),
      ...(a.text ? { text: a.text } : {}),
      ...(a.checked !== undefined ? { checked: a.checked } : {}),
      ...(a.id !== undefined ? { id: a.id } : {}),
    }));
  }

  private async handleGameUiRange(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.action) return createErrorResponse('nodePath and action are required.');
    return this.gameCommand('ui_range', args, a => ({
      node_path: a.nodePath, action: a.action,
      ...(a.value !== undefined ? { value: a.value } : {}),
      ...(a.minValue !== undefined ? { min_value: a.minValue } : {}),
      ...(a.maxValue !== undefined ? { max_value: a.maxValue } : {}),
      ...(a.step !== undefined ? { step: a.step } : {}),
      ...(a.color ? { color: a.color } : {}),
    }));
  }

  private async handleGameRenderSettings(args: any) {
    args = normalizeParameters(args || {});
    return this.gameCommand('render_settings', args, a => ({
      action: a.action || 'get',
      ...(a.msaa2d !== undefined ? { msaa_2d: a.msaa2d } : {}),
      ...(a.msaa3d !== undefined ? { msaa_3d: a.msaa3d } : {}),
      ...(a.fxaa !== undefined ? { fxaa: a.fxaa } : {}),
      ...(a.taa !== undefined ? { taa: a.taa } : {}),
      ...(a.scalingMode !== undefined ? { scaling_mode: a.scalingMode } : {}),
      ...(a.scalingScale !== undefined ? { scaling_scale: a.scalingScale } : {}),
    }));
  }

  private async handleGameResource(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action || !args.path) return createErrorResponse('action and path are required.');
    return this.gameCommand('resource', args, a => ({
      action: a.action, path: a.path,
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.property ? { property: a.property } : {}),
    }));
  }

  // --- Batch 6: Visual Shader + Terrain + Video + CI/CD ---
  private async handleGameVisualShader(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('visual_shader', args, a => ({
      action: a.action,
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.shaderType ? { shader_type: a.shaderType } : {}),
      ...(a.nodeClass ? { node_class: a.nodeClass } : {}),
      ...(a.position ? { position: a.position } : {}),
      ...(a.fromNode !== undefined ? { from_node: a.fromNode } : {}),
      ...(a.fromPort !== undefined ? { from_port: a.fromPort } : {}),
      ...(a.toNode !== undefined ? { to_node: a.toNode } : {}),
      ...(a.toPort !== undefined ? { to_port: a.toPort } : {}),
      ...(a.shaderId !== undefined ? { shader_id: a.shaderId } : {}),
    }));
  }

  private async handleGameTerrain(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('terrain', args, a => ({
      action: a.action,
      ...(a.parentPath ? { parent_path: a.parentPath } : {}),
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.heightData ? { height_data: a.heightData } : {}),
      ...(a.width !== undefined ? { width: a.width } : {}),
      ...(a.depth !== undefined ? { depth: a.depth } : {}),
      ...(a.maxHeight !== undefined ? { max_height: a.maxHeight } : {}),
      ...(a.x !== undefined ? { x: a.x } : {}),
      ...(a.z !== undefined ? { z: a.z } : {}),
      ...(a.radius !== undefined ? { radius: a.radius } : {}),
      ...(a.heightDelta !== undefined ? { height_delta: a.heightDelta } : {}),
      ...(a.color ? { color: a.color } : {}),
      ...(a.name ? { name: a.name } : {}),
    }));
  }

  private async handleGameVideo(args: any) {
    args = normalizeParameters(args || {});
    if (!args.action) return createErrorResponse('action is required.');
    return this.gameCommand('video', args, a => ({
      action: a.action,
      ...(a.nodePath ? { node_path: a.nodePath } : {}),
      ...(a.parentPath ? { parent_path: a.parentPath } : {}),
      ...(a.videoPath ? { video_path: a.videoPath } : {}),
      ...(a.position !== undefined ? { position: a.position } : {}),
      ...(a.volume !== undefined ? { volume: a.volume } : {}),
      ...(a.loop !== undefined ? { loop: a.loop } : {}),
      ...(a.autoplay !== undefined ? { autoplay: a.autoplay } : {}),
      ...(a.name ? { name: a.name } : {}),
    }));
  }

  private async handleManageCiPipeline(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.action) return createErrorResponse('projectPath and action are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    const workflowDir = join(args.projectPath, '.github', 'workflows');
    const workflowPath = join(workflowDir, 'godot-export.yml');
    try {
      if (args.action === 'read') {
        if (!existsSync(workflowPath)) return createErrorResponse('No workflow file found at .github/workflows/godot-export.yml');
        const content = readFileSync(workflowPath, 'utf8');
        return { content: [{ type: 'text', text: content }] };
      } else if (args.action === 'create') {
        if (!existsSync(workflowDir)) mkdirSync(workflowDir, { recursive: true });
        const godotVersion = args.godotVersion || '4.3-stable';
        const platforms = args.platforms || ['linux'];
        const exportSteps = platforms.map((p: string) => `      - name: Export ${p}\n        run: godot --headless --export-release "${p}" build/${p}/game`).join('\n');
        const workflow = `name: Godot Export\non:\n  push:\n    branches: [main]\n  pull_request:\n    branches: [main]\njobs:\n  export:\n    runs-on: ubuntu-latest\n    container:\n      image: barichello/godot-ci:${godotVersion}\n    steps:\n      - uses: actions/checkout@v4\n      - name: Setup export templates\n        run: |\n          mkdir -p ~/.local/share/godot/export_templates/${godotVersion}\n          mv /root/.local/share/godot/export_templates/${godotVersion}/* ~/.local/share/godot/export_templates/${godotVersion}/ || true\n${exportSteps}\n      - uses: actions/upload-artifact@v4\n        with:\n          name: game-builds\n          path: build/\n`;
        writeFileSync(workflowPath, workflow, 'utf8');
        return { content: [{ type: 'text', text: `CI pipeline created at .github/workflows/godot-export.yml for platforms: ${platforms.join(', ')}` }] };
      }
      return createErrorResponse(`Unknown action: ${args.action}`);
    } catch (error: any) {
      return createErrorResponse(`manage_ci_pipeline failed: ${error?.message || 'Unknown error'}`);
    }
  }

  private async handleManageDockerExport(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.action) return createErrorResponse('projectPath and action are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    const dockerfilePath = join(args.projectPath, 'Dockerfile');
    try {
      if (args.action === 'read') {
        if (!existsSync(dockerfilePath)) return createErrorResponse('No Dockerfile found in project root.');
        const content = readFileSync(dockerfilePath, 'utf8');
        return { content: [{ type: 'text', text: content }] };
      } else if (args.action === 'create') {
        const godotVersion = args.godotVersion || '4.3-stable';
        const baseImage = args.baseImage || 'ubuntu:22.04';
        const exportPreset = args.exportPreset || 'Linux/X11';
        const dockerfile = `FROM ${baseImage}\n\nARG GODOT_VERSION=${godotVersion}\n\nRUN apt-get update && apt-get install -y \\\n    wget unzip ca-certificates \\\n    && rm -rf /var/lib/apt/lists/*\n\nRUN wget -q https://github.com/godotengine/godot/releases/download/\${GODOT_VERSION}/Godot_v\${GODOT_VERSION}_linux.x86_64.zip \\\n    && unzip Godot_v\${GODOT_VERSION}_linux.x86_64.zip \\\n    && mv Godot_v\${GODOT_VERSION}_linux.x86_64 /usr/local/bin/godot \\\n    && rm Godot_v\${GODOT_VERSION}_linux.x86_64.zip\n\nRUN wget -q https://github.com/godotengine/godot/releases/download/\${GODOT_VERSION}/Godot_v\${GODOT_VERSION}_export_templates.tpz \\\n    && mkdir -p /root/.local/share/godot/export_templates/\${GODOT_VERSION} \\\n    && unzip Godot_v\${GODOT_VERSION}_export_templates.tpz \\\n    && mv templates/* /root/.local/share/godot/export_templates/\${GODOT_VERSION}/ \\\n    && rm -rf templates Godot_v\${GODOT_VERSION}_export_templates.tpz\n\nWORKDIR /game\nCOPY . .\n\nRUN mkdir -p build\nCMD ["godot", "--headless", "--export-release", "${exportPreset}", "build/game"]\n`;
        writeFileSync(dockerfilePath, dockerfile, 'utf8');
        return { content: [{ type: 'text', text: `Dockerfile created for headless Godot export (preset: ${exportPreset})` }] };
      }
      return createErrorResponse(`Unknown action: ${args.action}`);
    } catch (error: any) {
      return createErrorResponse(`manage_docker_export failed: ${error?.message || 'Unknown error'}`);
    }
  }

  /**
   * Handle the update_project_uids tool
   */
  private async handleUpdateProjectUids(args: any) {
    // Normalize parameters to camelCase
    args = normalizeParameters(args);
    
    if (!args.projectPath) {
      return createErrorResponse(
        'Project path is required'
      );
    }

    if (!validatePath(args.projectPath)) {
      return createErrorResponse(
        'Invalid project path'
      );
    }

    try {
      // Ensure godotPath is set
      if (!this.godotPath) {
        await this.detectGodotPath();
        if (!this.godotPath) {
          return createErrorResponse(
            'Could not find a valid Godot executable path'
          );
        }
      }

      // Check if the project directory exists and contains a project.godot file
      const projectFile = join(args.projectPath, 'project.godot');
      if (!existsSync(projectFile)) {
        return createErrorResponse(
          `Not a valid Godot project: ${args.projectPath}`
        );
      }

      // Get Godot version to check if UIDs are supported
      const { stdout: versionOutput } = await execFileAsync(this.godotPath!, ['--version']);
      const version = versionOutput.trim();

      if (!isGodot44OrLater(version)) {
        return createErrorResponse(
          `UIDs are only supported in Godot 4.4 or later. Current version: ${version}`
        );
      }

      // Prepare parameters for the operation (already in camelCase)
      const params = {
        projectPath: args.projectPath,
      };

      // Execute the operation
      const { stdout, stderr } = await this.executeOperation('resave_resources', params, args.projectPath);

      if (stderr && stderr.includes('Failed to')) {
        return createErrorResponse(
          `Failed to update project UIDs: ${stderr}`
        );
      }

      return {
        content: [
          {
            type: 'text',
            text: `Project UIDs updated successfully.\n\nOutput: ${stdout}`,
          },
        ],
      };
    } catch (error: any) {
      return createErrorResponse(
        `Failed to update project UIDs: ${error?.message || 'Unknown error'}`
      );
    }
  }

  /**
   * Run the MCP server
   */
  async run() {
    try {
      // Detect Godot path before starting the server
      await this.detectGodotPath();

      if (!this.godotPath) {
        console.error('[SERVER] Failed to find a valid Godot executable path');
        console.error('[SERVER] Please set GODOT_PATH environment variable or provide a valid path');
        process.exit(1);
      }

      // Check if the path is valid
      const isValid = await this.isValidGodotPath(this.godotPath);

      if (!isValid) {
        if (this.strictPathValidation) {
          // In strict mode, exit if the path is invalid
          console.error(`[SERVER] Invalid Godot path: ${this.godotPath}`);
          console.error('[SERVER] Please set a valid GODOT_PATH environment variable or provide a valid path');
          process.exit(1);
        } else {
          // In compatibility mode, warn but continue with the default path
          console.error(`[SERVER] Warning: Using potentially invalid Godot path: ${this.godotPath}`);
          console.error('[SERVER] This may cause issues when executing Godot commands');
          console.error('[SERVER] This fallback behavior will be removed in a future version. Set strictPathValidation: true to opt-in to the new behavior.');
        }
      }

      console.error(`[SERVER] Using Godot at: ${this.godotPath}`);

      const transport = new StdioServerTransport();
      await this.server.connect(transport);
      console.error('Godot MCP server running on stdio');
    } catch (error: unknown) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      console.error('[SERVER] Failed to start:', errorMessage);
      process.exit(1);
    }
  }

  // ── Internal helpers ───────────────────────────────────────────────────────

  private resolveResPath(projectPath: string, resPath: string): string {
    if (resPath.startsWith('res://')) return join(projectPath, resPath.slice('res://'.length));
    if (resPath.startsWith('/')) return resPath;
    return join(projectPath, resPath);
  }

  private collectFiles(dir: string, extensions: string[]): string[] {
    const results: string[] = [];
    const walk = (current: string) => {
      let entries: string[];
      try { entries = readdirSync(current, { withFileTypes: true } as any); } catch { return; }
      for (const e of entries as any[]) {
        const full = join(current, e.name);
        if (e.isDirectory()) {
          if (e.name === '.godot' || e.name === 'node_modules') continue;
          walk(full);
        } else if (extensions.some(ext => e.name.endsWith(ext))) {
          results.push(full);
        }
      }
    };
    walk(dir);
    return results;
  }

  private parseTscnNodes(content: string): Array<{ header: string; body: string; name: string; type: string; parent: string }> {
    const nodes: Array<{ header: string; body: string; name: string; type: string; parent: string }> = [];
    const sections = content.split(/(?=\[node )/);
    for (const sec of sections) {
      if (!sec.startsWith('[node ')) continue;
      const headerEnd = sec.indexOf(']');
      const header = sec.substring(0, headerEnd + 1);
      const body = sec.substring(headerEnd + 1);
      const nameMatch = header.match(/name="([^"]+)"/);
      const typeMatch = header.match(/type="([^"]+)"/);
      const parentMatch = header.match(/parent="([^"]+)"/);
      nodes.push({
        header,
        body,
        name: nameMatch ? nameMatch[1] : '',
        type: typeMatch ? typeMatch[1] : '',
        parent: parentMatch ? parentMatch[1] : '',
      });
    }
    return nodes;
  }

  private parseTscnConnections(content: string): Array<{ signal: string; from: string; to: string; method: string }> {
    const connections: Array<{ signal: string; from: string; to: string; method: string }> = [];
    const lines = content.split('\n');
    for (const line of lines) {
      if (!line.startsWith('[connection ')) continue;
      const signal = (line.match(/signal="([^"]+)"/) || [])[1] || '';
      const from = (line.match(/from="([^"]+)"/) || [])[1] || '';
      const to = (line.match(/to="([^"]+)"/) || [])[1] || '';
      const method = (line.match(/method="([^"]+)"/) || [])[1] || '';
      connections.push({ signal, from, to, method });
    }
    return connections;
  }

  private parseIniFile(content: string): Record<string, Record<string, string>> {
    const result: Record<string, Record<string, string>> = {};
    let section = '__global__';
    result[section] = {};
    for (const rawLine of content.split('\n')) {
      const line = rawLine.trim();
      if (!line || line.startsWith(';') || line.startsWith('#')) continue;
      const sectionMatch = line.match(/^\[(.+)\]$/);
      if (sectionMatch) { section = sectionMatch[1]; result[section] = {}; continue; }
      const eqIdx = line.indexOf('=');
      if (eqIdx === -1) continue;
      const key = line.substring(0, eqIdx).trim();
      let val = line.substring(eqIdx + 1).trim();
      if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
        val = val.slice(1, -1);
      }
      result[section][key] = val;
    }
    return result;
  }

  private serializeIniFile(parsed: Record<string, Record<string, string>>): string {
    const lines: string[] = [];
    for (const [section, kvs] of Object.entries(parsed)) {
      if (section !== '__global__') lines.push(`[${section}]`);
      for (const [k, v] of Object.entries(kvs)) lines.push(`${k}=${v}`);
      lines.push('');
    }
    return lines.join('\n');
  }

  // ── Batch & Refactoring ────────────────────────────────────────────────────

  private async handleFindNodesByType(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.nodeType) return createErrorResponse('projectPath and nodeType are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const tscnFiles = this.collectFiles(args.projectPath, ['.tscn']);
    const results: Array<{ scene: string; nodeName: string; nodePath: string }> = [];
    const searchType = (args.nodeType as string).toLowerCase();
    for (const file of tscnFiles) {
      let content: string;
      try { content = readFileSync(file, 'utf8'); } catch { continue; }
      const nodes = this.parseTscnNodes(content);
      const relScene = file.replace(args.projectPath, '').replace(/^\//, '');
      for (const node of nodes) {
        if (node.type.toLowerCase().includes(searchType)) {
          const nodePath = node.parent ? (node.parent === '.' ? node.name : `${node.parent}/${node.name}`) : node.name;
          results.push({ scene: relScene, nodeName: node.name, nodePath });
        }
      }
    }
    return { content: [{ type: 'text', text: JSON.stringify(results, null, 2) }] };
  }

  private async handleFindSignalConnections(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) return createErrorResponse('projectPath is required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const tscnFiles = this.collectFiles(args.projectPath, ['.tscn']);
    const results: Array<{ scene: string; signal: string; from: string; to: string; method: string }> = [];
    for (const file of tscnFiles) {
      let content: string;
      try { content = readFileSync(file, 'utf8'); } catch { continue; }
      const relScene = file.replace(args.projectPath, '').replace(/^\//, '');
      for (const conn of this.parseTscnConnections(content)) {
        results.push({ scene: relScene, ...conn });
      }
    }
    return { content: [{ type: 'text', text: JSON.stringify(results, null, 2) }] };
  }

  private async handleBatchSetProperty(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.nodeType || !args.propertyKey || args.propertyValue === undefined) {
      return createErrorResponse('projectPath, scenePath, nodeType, propertyKey, and propertyValue are required.');
    }
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to read scene: ${e.message}`); }
    const nodes = this.parseTscnNodes(content);
    const searchType = (args.nodeType as string).toLowerCase();
    const matchingNames = new Set(nodes.filter(n => n.type.toLowerCase().includes(searchType)).map(n => n.name));
    if (matchingNames.size === 0) return { content: [{ type: 'text', text: `No nodes of type "${args.nodeType}" found in scene.` }] };
    let modCount = 0;
    const newContent = content.replace(/(\[node [^\]]+\])([\s\S]*?)(?=\[node |\[connection |\[sub_resource |\[ext_resource |$)/g, (match, header, body) => {
      const nameMatch = header.match(/name="([^"]+)"/);
      if (!nameMatch || !matchingNames.has(nameMatch[1])) return match;
      modCount++;
      const propLine = `${args.propertyKey} = ${args.propertyValue}`;
      const propRegex = new RegExp(`^${args.propertyKey}\\s*=.*$`, 'm');
      if (propRegex.test(body)) {
        return header + body.replace(propRegex, propLine);
      }
      return header + body.trimEnd() + '\n' + propLine + '\n';
    });
    try { writeFileSync(absScene, newContent, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to write scene: ${e.message}`); }
    return { content: [{ type: 'text', text: `Set ${args.propertyKey}=${args.propertyValue} on ${modCount} node(s) of type "${args.nodeType}" in ${args.scenePath}.` }] };
  }

  private async handleFindNodeReferences(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.nodeName) return createErrorResponse('projectPath and nodeName are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const files = this.collectFiles(args.projectPath, ['.tscn', '.gd']);
    const results: Array<{ file: string; line: number; context: string }> = [];
    const search = args.nodeName as string;
    for (const file of files) {
      let content: string;
      try { content = readFileSync(file, 'utf8'); } catch { continue; }
      const relFile = file.replace(args.projectPath, '').replace(/^\//, '');
      const lines = content.split('\n');
      lines.forEach((ln, idx) => {
        if (ln.includes(search)) results.push({ file: relFile, line: idx + 1, context: ln.trim() });
      });
    }
    return { content: [{ type: 'text', text: JSON.stringify(results, null, 2) }] };
  }

  private async handleGetSceneDependencies(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath) return createErrorResponse('projectPath and scenePath are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to read scene: ${e.message}`); }
    const deps: Array<{ uid: string; type: string; path: string }> = [];
    for (const line of content.split('\n')) {
      if (!line.startsWith('[ext_resource')) continue;
      const uid = (line.match(/uid="([^"]+)"/) || [])[1] || '';
      const type = (line.match(/type="([^"]+)"/) || [])[1] || '';
      const path = (line.match(/path="([^"]+)"/) || [])[1] || '';
      deps.push({ uid, type, path });
    }
    return { content: [{ type: 'text', text: JSON.stringify(deps, null, 2) }] };
  }

  private async handleCrossSceneSetProperty(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.nodeType || !args.propertyKey || args.propertyValue === undefined) {
      return createErrorResponse('projectPath, nodeType, propertyKey, and propertyValue are required.');
    }
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const tscnFiles = this.collectFiles(args.projectPath, ['.tscn']);
    let totalModified = 0;
    const scenesModified: string[] = [];
    for (const file of tscnFiles) {
      let content: string;
      try { content = readFileSync(file, 'utf8'); } catch { continue; }
      const nodes = this.parseTscnNodes(content);
      const searchType = (args.nodeType as string).toLowerCase();
      const matchingNames = new Set(nodes.filter(n => n.type.toLowerCase().includes(searchType)).map(n => n.name));
      if (matchingNames.size === 0) continue;
      let modCount = 0;
      const newContent = content.replace(/(\[node [^\]]+\])([\s\S]*?)(?=\[node |\[connection |\[sub_resource |\[ext_resource |$)/g, (match, header, body) => {
        const nameMatch = header.match(/name="([^"]+)"/);
        if (!nameMatch || !matchingNames.has(nameMatch[1])) return match;
        modCount++;
        const propLine = `${args.propertyKey} = ${args.propertyValue}`;
        const propRegex = new RegExp(`^${args.propertyKey}\\s*=.*$`, 'm');
        if (propRegex.test(body)) return header + body.replace(propRegex, propLine);
        return header + body.trimEnd() + '\n' + propLine + '\n';
      });
      if (modCount > 0) {
        try { writeFileSync(file, newContent, 'utf8'); } catch { continue; }
        totalModified += modCount;
        scenesModified.push(file.replace(args.projectPath, '').replace(/^\//, ''));
      }
    }
    return { content: [{ type: 'text', text: JSON.stringify({ scenesModified, totalNodesModified: totalModified }, null, 2) }] };
  }

  private async handleFindScriptReferences(args: any) {
    args = normalizeParameters(args || {});
    args.searchTerm = args.searchTerm || args.pattern;
    if (!args.projectPath || !args.searchTerm) return createErrorResponse('projectPath and searchTerm (or pattern) are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const files = this.collectFiles(args.projectPath, ['.gd']);
    const results: Array<{ file: string; line: number; context: string }> = [];
    const search = args.searchTerm as string;
    for (const file of files) {
      let content: string;
      try { content = readFileSync(file, 'utf8'); } catch { continue; }
      const relFile = file.replace(args.projectPath, '').replace(/^\//, '');
      const lines = content.split('\n');
      lines.forEach((ln, idx) => {
        if (ln.includes(search)) results.push({ file: relFile, line: idx + 1, context: ln.trim() });
      });
    }
    return { content: [{ type: 'text', text: JSON.stringify(results, null, 2) }] };
  }

  private async handleDetectCircularDependencies(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) return createErrorResponse('projectPath is required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const tscnFiles = this.collectFiles(args.projectPath, ['.tscn']);
    const graph: Record<string, string[]> = {};
    for (const file of tscnFiles) {
      let content: string;
      try { content = readFileSync(file, 'utf8'); } catch { continue; }
      const relFile = file.replace(args.projectPath, '').replace(/^\//, '');
      graph[relFile] = [];
      for (const line of content.split('\n')) {
        if (!line.startsWith('[ext_resource')) continue;
        const pathMatch = line.match(/path="([^"]+)"/);
        if (pathMatch) {
          let dep = pathMatch[1].replace('res://', '');
          graph[relFile].push(dep);
        }
      }
    }
    const cycles: string[][] = [];
    const visited = new Set<string>();
    const inStack = new Set<string>();
    const dfs = (node: string, path: string[]) => {
      if (inStack.has(node)) { cycles.push([...path, node]); return; }
      if (visited.has(node)) return;
      visited.add(node);
      inStack.add(node);
      for (const dep of (graph[node] || [])) dfs(dep, [...path, node]);
      inStack.delete(node);
    };
    for (const node of Object.keys(graph)) dfs(node, []);
    return { content: [{ type: 'text', text: JSON.stringify({ cycles }, null, 2) }] };
  }

  // ── Analysis ───────────────────────────────────────────────────────────────

  private async handleAnalyzeSceneComplexity(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath) return createErrorResponse('projectPath and scenePath are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to read scene: ${e.message}`); }
    const nodes = this.parseTscnNodes(content);
    const connections = this.parseTscnConnections(content);
    const nodeTypes: Record<string, number> = {};
    let scriptCount = 0;
    for (const node of nodes) {
      if (node.type) nodeTypes[node.type] = (nodeTypes[node.type] || 0) + 1;
      if (node.body.includes('script = ExtResource')) scriptCount++;
    }
    const resourceCount = (content.match(/^\[ext_resource/gm) || []).length;
    const getDepth = (parent: string): number => {
      if (!parent || parent === '.') return 0;
      return parent.split('/').length + 1;
    };
    const maxDepth = nodes.reduce((max, n) => Math.max(max, getDepth(n.parent)), 0);
    return { content: [{ type: 'text', text: JSON.stringify({ nodeCount: nodes.length, maxDepth, scriptCount, resourceCount, signalConnectionCount: connections.length, nodeTypes }, null, 2) }] };
  }

  private async handleAnalyzeSignalFlow(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath) return createErrorResponse('projectPath and scenePath are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to read scene: ${e.message}`); }
    const connections = this.parseTscnConnections(content);
    return { content: [{ type: 'text', text: JSON.stringify({ connections }, null, 2) }] };
  }

  private async handleFindUnusedResources(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) return createErrorResponse('projectPath is required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const sourceFiles = this.collectFiles(args.projectPath, ['.tscn', '.gd', '.tres']);
    const referencedPaths = new Set<string>();
    const resPattern = /res:\/\/([^\s"']+)/g;
    for (const file of sourceFiles) {
      let content: string;
      try { content = readFileSync(file, 'utf8'); } catch { continue; }
      let m: RegExpExecArray | null;
      while ((m = resPattern.exec(content)) !== null) referencedPaths.add(m[1]);
    }
    const allFiles = this.collectFiles(args.projectPath, ['.png', '.jpg', '.jpeg', '.svg', '.wav', '.ogg', '.mp3', '.tres', '.tscn', '.gd', '.glb', '.obj']);
    const unreferenced: string[] = [];
    for (const file of allFiles) {
      const rel = file.replace(args.projectPath, '').replace(/^\//, '');
      if (!referencedPaths.has(rel)) unreferenced.push(rel);
    }
    return { content: [{ type: 'text', text: JSON.stringify({ unreferenced }, null, 2) }] };
  }

  private async handleGetProjectStatistics(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) return createErrorResponse('projectPath is required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const tscnFiles = this.collectFiles(args.projectPath, ['.tscn']);
    const gdFiles = this.collectFiles(args.projectPath, ['.gd']);
    const tresFiles = this.collectFiles(args.projectPath, ['.tres']);
    let totalLines = 0;
    for (const f of gdFiles) {
      try { totalLines += readFileSync(f, 'utf8').split('\n').length; } catch {}
    }
    let totalNodes = 0;
    for (const f of tscnFiles) {
      try { totalNodes += this.parseTscnNodes(readFileSync(f, 'utf8')).length; } catch {}
    }
    const projectFile = join(args.projectPath, 'project.godot');
    let pluginCount = 0;
    let autoloadCount = 0;
    if (existsSync(projectFile)) {
      const projContent = readFileSync(projectFile, 'utf8');
      pluginCount = (projContent.match(/\[plugin\]/gm) || []).length;
      autoloadCount = (projContent.match(/^autoload\//gm) || []).length;
    }
    return { content: [{ type: 'text', text: JSON.stringify({ sceneCount: tscnFiles.length, scriptCount: gdFiles.length, resourceCount: tresFiles.length, totalLines, totalNodes, pluginCount, autoloadCount }, null, 2) }] };
  }

  // ── Import Settings ────────────────────────────────────────────────────────

  private resolveImportPath(projectPath: string, resourcePath: string): string {
    if (resourcePath.startsWith('res://')) {
      return join(projectPath, resourcePath.replace('res://', '')) + '.import';
    }
    if (!resourcePath.startsWith('/')) {
      return join(projectPath, resourcePath) + '.import';
    }
    return resourcePath + '.import';
  }

  private async handleImportGetConfig(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.resourcePath) return createErrorResponse('projectPath and resourcePath are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const importPath = this.resolveImportPath(args.projectPath, args.resourcePath);
    if (!existsSync(importPath)) return createErrorResponse(`No .import file found at: ${importPath}`);
    let content: string;
    try { content = readFileSync(importPath, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to read .import file: ${e.message}`); }
    const parsed = this.parseIniFile(content);
    return { content: [{ type: 'text', text: JSON.stringify(parsed, null, 2) }] };
  }

  private async handleImportSetConfig(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.resourcePath || !args.settings) return createErrorResponse('projectPath, resourcePath, and settings are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const importPath = this.resolveImportPath(args.projectPath, args.resourcePath);
    let parsed: Record<string, Record<string, string>> = { __global__: {} };
    if (existsSync(importPath)) {
      try { parsed = this.parseIniFile(readFileSync(importPath, 'utf8')); } catch {}
    }
    for (const [k, v] of Object.entries(args.settings as Record<string, any>)) {
      const dotIdx = k.indexOf('.');
      if (dotIdx !== -1) {
        const section = k.substring(0, dotIdx);
        const key = k.substring(dotIdx + 1);
        if (!parsed[section]) parsed[section] = {};
        parsed[section][key] = String(v);
      } else {
        parsed['__global__'][k] = String(v);
      }
    }
    try { writeFileSync(importPath, this.serializeIniFile(parsed), 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to write .import file: ${e.message}`); }
    return { content: [{ type: 'text', text: `Updated .import file at: ${importPath}` }] };
  }

  private async handleImportListPresets(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) return createErrorResponse('projectPath is required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const importFiles = this.collectFiles(args.projectPath, ['.import']);
    const byImporter: Record<string, string[]> = {};
    for (const file of importFiles) {
      let content: string;
      try { content = readFileSync(file, 'utf8'); } catch { continue; }
      const parsed = this.parseIniFile(content);
      const importer = parsed['__global__']?.importer || parsed['remap']?.importer || 'unknown';
      if (!byImporter[importer]) byImporter[importer] = [];
      byImporter[importer].push(file.replace(args.projectPath, '').replace(/^\//, ''));
    }
    return { content: [{ type: 'text', text: JSON.stringify(byImporter, null, 2) }] };
  }

  private async handleImportReiimport(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) return createErrorResponse('projectPath is required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    if (!this.godotPath) {
      await this.detectGodotPath();
      if (!this.godotPath) return createErrorResponse('Could not find a valid Godot executable path.');
    }
    try {
      const { stdout, stderr } = await execFileAsync(this.godotPath!, ['--headless', '--import', '--path', args.projectPath]);
      return { content: [{ type: 'text', text: `Reimport completed.\n\nstdout: ${stdout}\nstderr: ${stderr}` }] };
    } catch (e: any) {
      return createErrorResponse(`Reimport failed: ${e?.message || 'Unknown error'}`);
    }
  }

  // ── Script Management ──────────────────────────────────────────────────────

  private async handleListScripts(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) return createErrorResponse('projectPath is required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const gdFiles = this.collectFiles(args.projectPath, ['.gd']);
    const scripts: Array<{ path: string; size: number; hasClass: boolean; className: string }> = [];
    for (const file of gdFiles) {
      let content: string;
      let size = 0;
      try { content = readFileSync(file, 'utf8'); size = Buffer.byteLength(content, 'utf8'); } catch { continue; }
      const classMatch = content.match(/^class_name\s+(\w+)/m);
      scripts.push({ path: file.replace(args.projectPath, '').replace(/^\//, ''), size, hasClass: !!classMatch, className: classMatch ? classMatch[1] : '' });
    }
    return { content: [{ type: 'text', text: JSON.stringify({ scripts }, null, 2) }] };
  }

  private async handleSearchInFiles(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.pattern) return createErrorResponse('projectPath and pattern are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const extensions: string[] = args.fileExtensions || ['.gd', '.tscn', '.tres'];
    const caseSensitive: boolean = args.caseSensitive !== false;
    const files = this.collectFiles(args.projectPath, extensions);
    const matches: Array<{ file: string; line: number; context: string }> = [];
    const pattern = caseSensitive ? args.pattern as string : (args.pattern as string).toLowerCase();
    for (const file of files) {
      let content: string;
      try { content = readFileSync(file, 'utf8'); } catch { continue; }
      const relFile = file.replace(args.projectPath, '').replace(/^\//, '');
      const lines = content.split('\n');
      lines.forEach((ln, idx) => {
        const lineToSearch = caseSensitive ? ln : ln.toLowerCase();
        if (lineToSearch.includes(pattern)) matches.push({ file: relFile, line: idx + 1, context: ln.trim() });
      });
    }
    return { content: [{ type: 'text', text: JSON.stringify({ matches }, null, 2) }] };
  }

  private async handleValidateScript(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scriptPath) return createErrorResponse('projectPath and scriptPath are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScript = join(args.projectPath, args.scriptPath);
    if (!existsSync(absScript)) return createErrorResponse(`Script not found: ${absScript}`);
    if (!this.godotPath) {
      await this.detectGodotPath();
      if (!this.godotPath) return createErrorResponse('Could not find a valid Godot executable path.');
    }
    try {
      const { stdout, stderr } = await execFileAsync(this.godotPath!, ['--headless', '--path', args.projectPath, '--check-only', absScript]);
      return { content: [{ type: 'text', text: `Validation result for ${args.scriptPath}:\n\nstdout: ${stdout}\nstderr: ${stderr}` }] };
    } catch (e: any) {
      return { content: [{ type: 'text', text: `Validation errors for ${args.scriptPath}:\n\n${e?.message || 'Unknown error'}\n\nstdout: ${e?.stdout || ''}\nstderr: ${e?.stderr || ''}` }] };
    }
  }

  // ── Scene Extras ───────────────────────────────────────────────────────────

  private async handleDeleteScene(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath) return createErrorResponse('projectPath and scenePath are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    const projectFile = join(args.projectPath, 'project.godot');
    if (existsSync(projectFile)) {
      const projContent = readFileSync(projectFile, 'utf8');
      const sceneResPath = `res://${args.scenePath.replace(/^\//, '')}`;
      if (projContent.includes(sceneResPath) && projContent.includes('run/main_scene')) {
        return createErrorResponse(`Refusing to delete: scene "${args.scenePath}" appears to be the main_scene in project.godot.`);
      }
    }
    try {
      unlinkSync(absScene);
      const deleteUidSidecar = args.deleteUidSidecar !== false;
      const uidPath = absScene + '.uid';
      if (deleteUidSidecar && existsSync(uidPath)) unlinkSync(uidPath);
      return { content: [{ type: 'text', text: `Deleted scene: ${args.scenePath}` + (deleteUidSidecar && existsSync(uidPath + '.uid') ? ' (and .uid sidecar)' : '') }] };
    } catch (e: any) {
      return createErrorResponse(`Failed to delete scene: ${e.message}`);
    }
  }

  private async handleGetSceneFileContent(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath) return createErrorResponse('projectPath and scenePath are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to read scene: ${e.message}`); }
    return { content: [{ type: 'text', text: content }] };
  }

  private async handleSceneSetUniqueName(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.nodePath || args.enabled === undefined) {
      return createErrorResponse('projectPath, scenePath, nodePath, and enabled are required.');
    }
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to read scene: ${e.message}`); }
    const nodeParts = (args.nodePath as string).split('/');
    const targetName = nodeParts[nodeParts.length - 1];
    const targetParent = nodeParts.length > 1 ? nodeParts.slice(0, -1).join('/') : '.';
    const sections = content.split(/(?=\[node )/);
    let found = false;
    const newSections = sections.map(sec => {
      if (!sec.startsWith('[node ')) return sec;
      const headerEnd = sec.indexOf(']');
      const header = sec.substring(0, headerEnd + 1);
      const body = sec.substring(headerEnd + 1);
      const nameMatch = header.match(/name="([^"]+)"/);
      const parentMatch = header.match(/parent="([^"]+)"/);
      const secName = nameMatch ? nameMatch[1] : '';
      const secParent = parentMatch ? parentMatch[1] : '.';
      if (secName !== targetName || secParent !== targetParent) return sec;
      found = true;
      const enabledStr = args.enabled ? 'true' : 'false';
      const uniqueLine = `unique_name_in_owner = ${enabledStr}`;
      const uniqueRegex = /^unique_name_in_owner\s*=.*$/m;
      if (uniqueRegex.test(body)) {
        return header + body.replace(uniqueRegex, uniqueLine);
      }
      return header + body.trimEnd() + '\n' + uniqueLine + '\n';
    });
    if (!found) return createErrorResponse(`Node not found at path "${args.nodePath}" in scene.`);
    try { writeFileSync(absScene, newSections.join(''), 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to write scene: ${e.message}`); }
    return { content: [{ type: 'text', text: `Set unique_name_in_owner = ${args.enabled} on node "${args.nodePath}" in ${args.scenePath}.` }] };
  }

  private async handleDuplicateNode(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.nodePath) return createErrorResponse('projectPath, scenePath, and nodePath are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to read scene: ${e.message}`); }
    const nodeParts = (args.nodePath as string).split('/');
    const targetName = nodeParts[nodeParts.length - 1];
    const targetParent = nodeParts.length > 1 ? nodeParts.slice(0, -1).join('/') : '.';
    const newName: string = args.newName || `${targetName}_copy`;
    const sections = content.split(/(?=\[node )/);
    let foundSection: string | null = null;
    for (const sec of sections) {
      if (!sec.startsWith('[node ')) continue;
      const headerEnd = sec.indexOf(']');
      const header = sec.substring(0, headerEnd + 1);
      const nameMatch = header.match(/name="([^"]+)"/);
      const parentMatch = header.match(/parent="([^"]+)"/);
      if (nameMatch && nameMatch[1] === targetName && (parentMatch ? parentMatch[1] : '.') === targetParent) {
        foundSection = sec;
        break;
      }
    }
    if (!foundSection) return createErrorResponse(`Node not found at path "${args.nodePath}" in scene.`);
    const copySection = foundSection.replace(`name="${targetName}"`, `name="${newName}"`);
    const insertAfter = foundSection;
    const newContent = content.replace(insertAfter, insertAfter + '\n' + copySection);
    try { writeFileSync(absScene, newContent, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to write scene: ${e.message}`); }
    return { content: [{ type: 'text', text: `Duplicated node "${args.nodePath}" as "${newName}" in ${args.scenePath}.` }] };
  }

  // ── VCS Integration ────────────────────────────────────────────────────────

  private async handleVcsStatus(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) return createErrorResponse('projectPath is required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    try {
      const { stdout } = await execFileAsync('git', ['status', '--short'], { cwd: args.projectPath });
      const lines = stdout.split('\n').filter(l => l.trim());
      const entries = lines.map(l => ({ status: l.substring(0, 2).trim(), file: l.substring(3).trim() }));
      return { content: [{ type: 'text', text: JSON.stringify({ entries }, null, 2) }] };
    } catch (e: any) {
      return createErrorResponse(`git status failed: ${e?.message || 'Unknown error'}`);
    }
  }

  private async handleVcsStage(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.files) return createErrorResponse('projectPath and files are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const files: string[] = Array.isArray(args.files) ? args.files : [args.files];
    try {
      const { stdout, stderr } = await execFileAsync('git', ['add', ...files], { cwd: args.projectPath });
      return { content: [{ type: 'text', text: `git add succeeded.\n\nstdout: ${stdout}\nstderr: ${stderr}` }] };
    } catch (e: any) {
      return createErrorResponse(`git add failed: ${e?.message || 'Unknown error'}`);
    }
  }

  private async handleVcsCommit(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.message) return createErrorResponse('projectPath and message are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    try {
      const { stdout, stderr } = await execFileAsync('git', ['commit', '-m', args.message], { cwd: args.projectPath });
      return { content: [{ type: 'text', text: `git commit succeeded.\n\nstdout: ${stdout}\nstderr: ${stderr}` }] };
    } catch (e: any) {
      return createErrorResponse(`git commit failed: ${e?.message || 'Unknown error'}`);
    }
  }

  private async handleVcsDiff(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) return createErrorResponse('projectPath is required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const gitArgs = args.filePath ? ['diff', args.filePath] : ['diff'];
    try {
      const { stdout } = await execFileAsync('git', gitArgs, { cwd: args.projectPath });
      return { content: [{ type: 'text', text: stdout || '(no diff)' }] };
    } catch (e: any) {
      return createErrorResponse(`git diff failed: ${e?.message || 'Unknown error'}`);
    }
  }

  private async handleVcsBranchList(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) return createErrorResponse('projectPath is required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    try {
      const { stdout } = await execFileAsync('git', ['branch', '-a'], { cwd: args.projectPath });
      const branches = stdout.split('\n').map(b => b.replace(/^\*?\s+/, '').trim()).filter(b => b);
      return { content: [{ type: 'text', text: JSON.stringify({ branches }, null, 2) }] };
    } catch (e: any) {
      return createErrorResponse(`git branch failed: ${e?.message || 'Unknown error'}`);
    }
  }

  private async handleVcsCheckout(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.branch) return createErrorResponse('projectPath and branch are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    try {
      const { stdout, stderr } = await execFileAsync('git', ['checkout', args.branch], { cwd: args.projectPath });
      return { content: [{ type: 'text', text: `Checked out branch "${args.branch}".\n\nstdout: ${stdout}\nstderr: ${stderr}` }] };
    } catch (e: any) {
      return createErrorResponse(`git checkout failed: ${e?.message || 'Unknown error'}`);
    }
  }

  // ── Testing & QA ───────────────────────────────────────────────────────────

  private async handleAssertNodeState(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.property || args.expectedValue === undefined) return createErrorResponse('nodePath, property, and expectedValue are required.');
    if (!this.activeProcess) return createErrorResponse('No active Godot process. Use run_project first.');
    if (!this.gameConnection.connected) return createErrorResponse('Not connected to game interaction server.');
    try {
      const response = await this.sendGameCommand('get_property', { node_path: args.nodePath, property: args.property });
      if (response.error) return createErrorResponse(`get_property failed: ${response.error}`);
      const actual = response.value !== undefined ? response.value : response.result;
      const expected = args.expectedValue;
      const passed = JSON.stringify(actual) === JSON.stringify(expected);
      return { content: [{ type: 'text', text: JSON.stringify({ passed, actual, expected, nodePath: args.nodePath, property: args.property }, null, 2) }] };
    } catch (e: any) {
      return createErrorResponse(`assert_node_state failed: ${e?.message || 'Unknown error'}`);
    }
  }

  private async handleAssertScreenText(args: any) {
    args = normalizeParameters(args || {});
    if (!args.text) return createErrorResponse('text is required.');
    if (!this.activeProcess) return createErrorResponse('No active Godot process. Use run_project first.');
    if (!this.gameConnection.connected) return createErrorResponse('Not connected to game interaction server.');
    try {
      const response = await this.sendGameCommand('find_text', { text: args.text });
      if (response.error) return createErrorResponse(`find_text failed: ${response.error}`);
      const found = !!(response.found || (response.locations && response.locations.length > 0));
      return { content: [{ type: 'text', text: JSON.stringify({ found, text: args.text, locations: response.locations || [] }, null, 2) }] };
    } catch (e: any) {
      return createErrorResponse(`assert_screen_text failed: ${e?.message || 'Unknown error'}`);
    }
  }

  private async handleCompareScreenshots(args: any) {
    args = normalizeParameters(args || {});
    if (!args.referencePath) return createErrorResponse('referencePath is required.');
    if (!this.activeProcess) return createErrorResponse('No active Godot process. Use run_project first.');
    if (!this.gameConnection.connected) return createErrorResponse('Not connected to game interaction server.');
    if (!existsSync(args.referencePath)) return createErrorResponse(`Reference file not found: ${args.referencePath}`);
    try {
      const screenshotResponse = await this.sendGameCommand('screenshot', {});
      if (screenshotResponse.error) return createErrorResponse(`Screenshot failed: ${screenshotResponse.error}`);
      const currentHash = screenshotResponse.data || screenshotResponse.base64 || '';
      const referenceContent = readFileSync(args.referencePath, 'base64');
      const match = currentHash === referenceContent;
      const diffPercent = match ? 0 : 100;
      return { content: [{ type: 'text', text: JSON.stringify({ match, diffPercent }, null, 2) }] };
    } catch (e: any) {
      return createErrorResponse(`compare_screenshots failed: ${e?.message || 'Unknown error'}`);
    }
  }

  private async handleRunStressTest(args: any) {
    args = normalizeParameters(args || {});
    if (!this.activeProcess) return createErrorResponse('No active Godot process. Use run_project first.');
    if (!this.gameConnection.connected) return createErrorResponse('Not connected to game interaction server.');
    const frames: number = args.frames ?? 300;
    const checkInterval: number = args.checkInterval ?? 60;
    const allErrors: string[] = [];
    try {
      let framesRun = 0;
      while (framesRun < frames) {
        const batch = Math.min(checkInterval, frames - framesRun);
        const waitResponse = await this.sendGameCommand('wait_frames', { frames: batch });
        if (waitResponse.error) { allErrors.push(`Frame ${framesRun + batch}: ${waitResponse.error}`); break; }
        const errResponse = await this.sendGameCommand('get_errors', {});
        if (errResponse.errors && Array.isArray(errResponse.errors)) allErrors.push(...errResponse.errors);
        framesRun += batch;
      }
      return { content: [{ type: 'text', text: JSON.stringify({ framesRun, errors: allErrors }, null, 2) }] };
    } catch (e: any) {
      return createErrorResponse(`run_stress_test failed: ${e?.message || 'Unknown error'}`);
    }
  }

  // ── AnimationPlayer ────────────────────────────────────────────────────────

  private async handleListAnimations(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath) return createErrorResponse('projectPath and scenePath are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to read scene: ${e.message}`); }
    const nodes = this.parseTscnNodes(content);
    const animPlayers = nodes.filter(n => n.type === 'AnimationPlayer');
    const result: Array<{ nodeName: string; animations: string[] }> = [];
    for (const ap of animPlayers) {
      const animNames: string[] = [];
      const animMatches = ap.body.matchAll(/anims\/([^\/\s"]+)\/[^=]+=\s*SubResource/g);
      const seenAnims = new Set<string>();
      for (const m of animMatches) { if (!seenAnims.has(m[1])) { seenAnims.add(m[1]); animNames.push(m[1]); } }
      const animMatches2 = ap.body.matchAll(/"([^"]+)":\s*SubResource/g);
      for (const m of animMatches2) { if (!seenAnims.has(m[1])) { seenAnims.add(m[1]); animNames.push(m[1]); } }
      result.push({ nodeName: ap.name, animations: animNames });
    }
    return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] };
  }

  private async handleRemoveAnimation(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.animationPlayerPath || !args.animationName) {
      return createErrorResponse('projectPath, scenePath, animationPlayerPath, and animationName are required.');
    }
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to read scene: ${e.message}`); }
    const animName = args.animationName as string;
    const escapedName = animName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const lineRegex = new RegExp(`^.*${escapedName}.*$\\n?`, 'gm');
    const newContent = content.replace(lineRegex, '');
    if (newContent === content) return createErrorResponse(`Animation "${animName}" not found in scene.`);
    try { writeFileSync(absScene, newContent, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to write scene: ${e.message}`); }
    return { content: [{ type: 'text', text: `Removed animation "${animName}" from AnimationPlayer "${args.animationPlayerPath}" in ${args.scenePath}.` }] };
  }

  // ── TileSet ────────────────────────────────────────────────────────────────

  private async handleTilesetCreate(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.tilesetPath) return createErrorResponse('projectPath and tilesetPath are required.');
    // TODO: GDScript implementation for tileset_create must also be updated in the operations script
    return this.headlessOp('tileset_create', args, a => ({
      projectPath: a.projectPath,
      params: { tilesetPath: a.tilesetPath },
    }));
  }

  private async handleTilesetAddSource(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.tilesetPath || !args.texturePath) return createErrorResponse('projectPath, tilesetPath, and texturePath are required.');
    // TODO: GDScript implementation for tileset_add_source must also be updated in the operations script
    return this.headlessOp('tileset_add_source', args, a => ({
      projectPath: a.projectPath,
      params: { tilesetPath: a.tilesetPath, texturePath: a.texturePath, tileSize: a.tileSize || { x: 16, y: 16 } },
    }));
  }

  // ── SpriteFrames ───────────────────────────────────────────────────────────

  private async handleSpriteframesCreate(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.spriteframesPath) return createErrorResponse('projectPath and spriteframesPath are required.');
    // TODO: GDScript implementation for spriteframes_create must also be updated in the operations script
    return this.headlessOp('spriteframes_create', args, a => ({
      projectPath: a.projectPath,
      params: { spriteframesPath: a.spriteframesPath },
    }));
  }

  private async handleSpriteframesAddAnimation(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.spriteframesPath || !args.animationName) return createErrorResponse('projectPath, spriteframesPath, and animationName are required.');
    // TODO: GDScript implementation for spriteframes_add_animation must also be updated in the operations script
    return this.headlessOp('spriteframes_add_animation', args, a => ({
      projectPath: a.projectPath,
      params: { spriteframesPath: a.spriteframesPath, animationName: a.animationName, fps: a.fps ?? 5, loop: a.loop !== false },
    }));
  }

  private async handleSpriteframesAddFrame(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.spriteframesPath || !args.animationName || !args.texturePath) return createErrorResponse('projectPath, spriteframesPath, animationName, and texturePath are required.');
    // TODO: GDScript implementation for spriteframes_add_frame must also be updated in the operations script
    return this.headlessOp('spriteframes_add_frame', args, a => ({
      projectPath: a.projectPath,
      params: { spriteframesPath: a.spriteframesPath, animationName: a.animationName, texturePath: a.texturePath, duration: a.duration ?? 1.0 },
    }));
  }

  // ── Runtime Game Tools ──────────────────────────────────────────────────

  private async handleFindNodesByScript(args: any) {
    args = normalizeParameters(args || {});
    if (!args.scriptPath) return createErrorResponse('scriptPath is required.');
    return this.gameCommand('find_nodes_by_script', args, a => ({
      script_path: a.scriptPath,
      partial: a.partial !== false,
    }));
  }

  private async handleBatchGetProperties(args: any) {
    args = normalizeParameters(args || {});
    if (!args.queries || !Array.isArray(args.queries)) return createErrorResponse('queries array is required.');
    return this.gameCommand('batch_get_properties', args, a => ({ queries: a.queries }));
  }

  private async handleClickButtonByText(args: any) {
    args = normalizeParameters(args || {});
    if (!args.text) return createErrorResponse('text is required.');
    return this.gameCommand('click_button_by_text', args, a => ({
      text: a.text,
      exact: a.exact === true,
    }));
  }

  private async handleWaitForNode(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath) return createErrorResponse('nodePath is required.');
    const timeoutMs = typeof args.timeoutMs === 'number' ? args.timeoutMs : 5000;
    return this.gameCommand('wait_for_node', args, a => ({
      node_path: a.nodePath,
      timeout_ms: timeoutMs,
    }), timeoutMs + 2000);
  }

  private async handleFindNearbyNodes(args: any) {
    args = normalizeParameters(args || {});
    if (!args.position || args.radius === undefined) return createErrorResponse('position and radius are required.');
    return this.gameCommand('find_nearby_nodes', args, a => ({
      position: a.position,
      radius: a.radius,
      node_type: a.nodeType || '',
    }));
  }

  private async handleCaptureFrames(args: any) {
    args = normalizeParameters(args || {});
    return this.gameCommand('capture_frames', args, a => ({
      count: typeof a.count === 'number' ? a.count : 5,
      interval_frames: typeof a.intervalFrames === 'number' ? a.intervalFrames : 10,
    }));
  }

  private async handleMonitorProperties(args: any) {
    args = normalizeParameters(args || {});
    if (!args.queries || !Array.isArray(args.queries)) return createErrorResponse('queries array is required.');
    return this.gameCommand('monitor_properties', args, a => ({
      queries: a.queries,
      frames: typeof a.frames === 'number' ? a.frames : 60,
      interval_frames: typeof a.intervalFrames === 'number' ? a.intervalFrames : 1,
    }));
  }

  private async handleStartRecording(_args: any) {
    return this.gameCommand('start_recording', {}, () => ({}));
  }

  private async handleStopRecording(_args: any) {
    return this.gameCommand('stop_recording', {}, () => ({}));
  }

  private async handleReplayRecording(args: any) {
    args = normalizeParameters(args || {});
    if (!args.events || !Array.isArray(args.events)) return createErrorResponse('events array is required.');
    return this.gameCommand('replay_recording', args, a => ({
      events: a.events,
      speed_scale: typeof a.speedScale === 'number' ? a.speedScale : 1.0,
    }));
  }

  // ── AnimationTree State Machine ─────────────────────────────────────────

  private async handleAnimtreeAddState(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.stateName || !args.animationName) {
      return createErrorResponse('nodePath, stateName, and animationName are required.');
    }
    return this.gameCommand('animtree_add_state', args, a => ({
      node_path: a.nodePath,
      state_name: a.stateName,
      animation_name: a.animationName,
    }));
  }

  private async handleAnimtreeRemoveState(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.stateName) return createErrorResponse('nodePath and stateName are required.');
    return this.gameCommand('animtree_remove_state', args, a => ({
      node_path: a.nodePath,
      state_name: a.stateName,
    }));
  }

  private async handleAnimtreeAddTransition(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.fromState || !args.toState) {
      return createErrorResponse('nodePath, fromState, and toState are required.');
    }
    return this.gameCommand('animtree_add_transition', args, a => ({
      node_path: a.nodePath,
      from_state: a.fromState,
      to_state: a.toState,
      switch_mode: a.switchMode || 'immediate',
    }));
  }

  private async handleAnimtreeRemoveTransition(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath || !args.fromState || !args.toState) {
      return createErrorResponse('nodePath, fromState, and toState are required.');
    }
    return this.gameCommand('animtree_remove_transition', args, a => ({
      node_path: a.nodePath,
      from_state: a.fromState,
      to_state: a.toState,
    }));
  }

  private async handleAnimtreeGetStructure(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath) return createErrorResponse('nodePath is required.');
    return this.gameCommand('animtree_get_structure', args, a => ({ node_path: a.nodePath }));
  }

  // ── Soft Debugger ───────────────────────────────────────────────────────

  private async handleDebuggerSetBreakpoint(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scriptPath || args.line === undefined) {
      return createErrorResponse('projectPath, scriptPath, and line are required.');
    }
    const absPath = this.resolveResPath(args.projectPath, args.scriptPath);
    if (!existsSync(absPath)) return createErrorResponse(`Script not found: ${absPath}`);
    let lines: string[];
    try { lines = readFileSync(absPath, 'utf8').split('\n'); } catch (e: any) { return createErrorResponse(`Failed to read script: ${e.message}`); }
    const lineIdx = (args.line as number) - 1;
    if (lineIdx < 0 || lineIdx >= lines.length) return createErrorResponse(`Line ${args.line} out of range.`);
    const marker = '# MCP_BREAKPOINT';
    if (args.enabled !== false) {
      if (!lines[lineIdx].trimEnd().endsWith(marker)) {
        lines.splice(lineIdx, 0, 'breakpoint ' + marker);
      }
    } else {
      lines = lines.filter(l => !l.trimEnd().endsWith(marker));
    }
    try { writeFileSync(absPath, lines.join('\n'), 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to write script: ${e.message}`); }
    return { content: [{ type: 'text', text: JSON.stringify({ success: true, scriptPath: args.scriptPath, line: args.line, enabled: args.enabled !== false }) }] };
  }

  private async handleDebuggerListBreakpoints(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) return createErrorResponse('projectPath is required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const gdFiles = this.collectFiles(args.projectPath, ['.gd']);
    const results: Array<{ file: string; line: number; context: string }> = [];
    const marker = '# MCP_BREAKPOINT';
    for (const file of gdFiles) {
      let content: string;
      try { content = readFileSync(file, 'utf8'); } catch { continue; }
      const fileLines = content.split('\n');
      for (let i = 0; i < fileLines.length; i++) {
        if (fileLines[i].trimEnd().endsWith(marker)) {
          results.push({ file, line: i + 1, context: fileLines[i].trim() });
        }
      }
    }
    return { content: [{ type: 'text', text: JSON.stringify(results, null, 2) }] };
  }

  private async handleDebuggerGetStack(_args: any) {
    return this.gameCommand('eval', { code: 'JSON.stringify(get_stack())' }, a => ({ code: a.code }));
  }

  private async handleDebuggerEvaluate(args: any) {
    args = normalizeParameters(args || {});
    if (!args.expression) return createErrorResponse('expression is required.');
    return this.gameCommand('eval', { code: args.expression }, a => ({ code: a.code }));
  }

  // ── Headless Scene Extras ───────────────────────────────────────────────

  private async handleAddSceneInstance(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.parentScenePath || !args.packedScenePath) {
      return createErrorResponse('projectPath, parentScenePath, and packedScenePath are required.');
    }
    return this.headlessOp('add_scene_instance', args, a => ({
      projectPath: a.projectPath,
      params: {
        scenePath: a.parentScenePath,
        packedScenePath: a.packedScenePath,
        instanceName: a.instanceName || '',
        parentNodePath: a.parentNodePath || '',
      },
    }));
  }

  private async handleMoveNode(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.nodePath || args.newIndex === undefined) {
      return createErrorResponse('projectPath, scenePath, nodePath, and newIndex are required.');
    }
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to read scene: ${e.message}`); }

    // Determine parent of the target node
    const nodePath = args.nodePath as string;
    const lastSlash = nodePath.lastIndexOf('/');
    const parentPath = lastSlash >= 0 ? nodePath.slice(0, lastSlash) : '.';
    const nodeName = lastSlash >= 0 ? nodePath.slice(lastSlash + 1) : nodePath;

    // Split content into sections: header + per-section blocks
    const sectionRegex = /(?=^\[(?!gd_scene|ext_resource|sub_resource)[^\]]+\])/m;
    const rawSections = content.split(/(?=^\[node )/m);

    // Identify the preamble (everything before first [node])
    const preamble = rawSections[0];
    const nodeSections = rawSections.slice(1);

    // Parse parent attribute from a node section header
    const getAttr = (header: string, attr: string): string | null => {
      const m = header.match(new RegExp(`\\b${attr}="([^"]*)"`));
      return m ? m[1] : null;
    };

    // Find siblings: nodes whose parent matches parentPath
    const siblings: number[] = [];
    let targetIdx = -1;
    for (let i = 0; i < nodeSections.length; i++) {
      const headerEnd = nodeSections[i].indexOf('\n');
      const header = nodeSections[i].slice(0, headerEnd);
      const nodeParent = getAttr(header, 'parent');
      const nodeNameAttr = getAttr(header, 'name');
      if (nodeParent === parentPath) {
        siblings.push(i);
        if (nodeNameAttr === nodeName) targetIdx = siblings.length - 1;
      }
    }
    if (targetIdx === -1) return createErrorResponse(`Node "${nodePath}" not found in scene.`);

    const newIdx = Math.max(0, Math.min(args.newIndex as number, siblings.length - 1));
    // Reorder: remove target from siblings list and insert at newIdx
    const removed = siblings.splice(targetIdx, 1)[0];
    siblings.splice(newIdx, 0, removed);

    // Rebuild nodeSections in new order: we need to figure out the full ordering
    // Build a mapping from old sibling position to new
    const reorderedAll = [...nodeSections];
    // Collect original sibling section indices and rearrange
    const siblingBlocks = siblings.map(si => nodeSections[si]);
    // Place rearranged sibling blocks back (siblings array now holds desired positions)
    // We need to put them back into reorderedAll in the right spots
    // Original sibling indices in sorted order:
    const origSiblingIndices = [...siblings].sort((a, b) => a - b); // these are wrong now since we mutated
    // Re-derive: we need to know which original indices were siblings
    // Let's redo: collect sibling indices before mutating
    // Actually we already have siblings[] = rearranged indices into nodeSections
    // and origSiblingIndices = sorted original indices
    const finalSections = [...nodeSections];
    // origSiblingIndices: indices in nodeSections that are siblings (sorted)
    // We need them sorted ascending to replace in order
    const sortedOriginals = [...siblings].sort((a, b) => a - b);
    for (let i = 0; i < sortedOriginals.length; i++) {
      finalSections[sortedOriginals[i]] = nodeSections[siblings[i]];
    }

    const newContent = preamble + finalSections.join('');
    try { writeFileSync(absScene, newContent, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to write scene: ${e.message}`); }
    return { content: [{ type: 'text', text: JSON.stringify({ success: true, nodePath, newIndex: newIdx }) }] };
  }

  private async handleGetNodeGroups(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.nodePath) {
      return createErrorResponse('projectPath, scenePath, and nodePath are required.');
    }
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to read scene: ${e.message}`); }

    const nodes = this.parseTscnNodes(content);
    const target = nodes.find(n => {
      const fullPath = n.parent === '.' ? n.name : `${n.parent}/${n.name}`;
      return fullPath === args.nodePath || n.name === args.nodePath;
    });
    if (!target) return createErrorResponse(`Node "${args.nodePath}" not found in scene.`);

    const groupsMatch = target.body.match(/^groups\s*=\s*\[([^\]]*)\]/m);
    let groups: string[] = [];
    if (groupsMatch) {
      groups = groupsMatch[1].split(',').map(s => s.trim().replace(/^"|"$/g, '')).filter(Boolean);
    }
    return { content: [{ type: 'text', text: JSON.stringify({ nodePath: args.nodePath, groups }) }] };
  }

  private async handleSetNodeGroups(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.nodePath || !Array.isArray(args.groups)) {
      return createErrorResponse('projectPath, scenePath, nodePath, and groups are required.');
    }
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to read scene: ${e.message}`); }

    const groups: string[] = args.groups;
    const groupsLine = `groups = [${groups.map(g => `"${g}"`).join(', ')}]`;

    // Find the node section and update/add the groups line
    const sections = content.split(/(?=^\[node )/m);
    let found = false;
    const updated = sections.map(sec => {
      if (!sec.startsWith('[node ')) return sec;
      const headerEnd = sec.indexOf('\n');
      const header = sec.slice(0, headerEnd);
      const nameMatch = header.match(/\bname="([^"]*)"/);
      const parentMatch = header.match(/\bparent="([^"]*)"/);
      if (!nameMatch) return sec;
      const fullPath = parentMatch ? (parentMatch[1] === '.' ? nameMatch[1] : `${parentMatch[1]}/${nameMatch[1]}`) : nameMatch[1];
      if (fullPath !== args.nodePath && nameMatch[1] !== args.nodePath) return sec;
      found = true;
      if (sec.match(/^groups\s*=/m)) {
        return sec.replace(/^groups\s*=\s*\[[^\]]*\]/m, groupsLine);
      } else {
        // Add after the header line
        return sec.slice(0, headerEnd + 1) + groupsLine + '\n' + sec.slice(headerEnd + 1);
      }
    });
    if (!found) return createErrorResponse(`Node "${args.nodePath}" not found in scene.`);
    try { writeFileSync(absScene, updated.join(''), 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to write scene: ${e.message}`); }
    return { content: [{ type: 'text', text: JSON.stringify({ success: true, nodePath: args.nodePath, groups }) }] };
  }

  private async handleFindNodesInGroup(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.group) {
      return createErrorResponse('projectPath, scenePath, and group are required.');
    }
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to read scene: ${e.message}`); }

    const nodes = this.parseTscnNodes(content);
    const group = args.group as string;
    const matches: Array<{ name: string; parent: string; nodePath: string }> = [];
    for (const n of nodes) {
      const groupsMatch = n.body.match(/^groups\s*=\s*\[([^\]]*)\]/m);
      if (!groupsMatch) continue;
      const nodeGroups = groupsMatch[1].split(',').map(s => s.trim().replace(/^"|"$/g, '')).filter(Boolean);
      if (nodeGroups.includes(group)) {
        const fullPath = n.parent === '.' ? n.name : `${n.parent}/${n.name}`;
        matches.push({ name: n.name, parent: n.parent, nodePath: fullPath });
      }
    }
    return { content: [{ type: 'text', text: JSON.stringify(matches, null, 2) }] };
  }

  private async handleSceneCreateInherited(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.baseScenePath || !args.newScenePath) {
      return createErrorResponse('projectPath, baseScenePath, and newScenePath are required.');
    }
    return this.headlessOp('create_inherited_scene', args, a => ({
      projectPath: a.projectPath,
      params: { baseScenePath: a.baseScenePath, newScenePath: a.newScenePath },
    }));
  }

  private async handleAddAutoload(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.name || !args.path) {
      return createErrorResponse('projectPath, name, and path are required.');
    }
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    let content: string;
    try { content = readFileSync(projectFile, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to read project.godot: ${e.message}`); }

    const autoloadLine = `${args.name}="*${args.path}"`;
    if (content.includes(`\n${args.name}=`)) {
      // Update existing entry
      content = content.replace(new RegExp(`^${args.name}=.*$`, 'm'), autoloadLine);
    } else if (content.includes('[autoload]')) {
      content = content.replace('[autoload]', `[autoload]\n${autoloadLine}`);
    } else {
      content += `\n[autoload]\n${autoloadLine}\n`;
    }
    try { writeFileSync(projectFile, content, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to write project.godot: ${e.message}`); }
    return { content: [{ type: 'text', text: JSON.stringify({ success: true, name: args.name, path: args.path }) }] };
  }

  private async handleRemoveAutoload(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.name) return createErrorResponse('projectPath and name are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    let content: string;
    try { content = readFileSync(projectFile, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to read project.godot: ${e.message}`); }

    const before = content;
    content = content.replace(new RegExp(`^${args.name}=.*\\n?`, 'm'), '');
    if (content === before) return createErrorResponse(`Autoload "${args.name}" not found in project.godot.`);
    try { writeFileSync(projectFile, content, 'utf8'); } catch (e: any) { return createErrorResponse(`Failed to write project.godot: ${e.message}`); }
    return { content: [{ type: 'text', text: JSON.stringify({ success: true, name: args.name }) }] };
  }

  // ── Resource Creation ───────────────────────────────────────────────────

  private async handleCurveCreate(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.curvePath || !Array.isArray(args.points)) {
      return createErrorResponse('projectPath, curvePath, and points are required.');
    }
    return this.headlessOp('curve_create', args, a => ({
      projectPath: a.projectPath,
      params: { curvePath: a.curvePath, points: a.points },
    }));
  }

  private async handleGradientCreate(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.gradientPath || !Array.isArray(args.colors) || !Array.isArray(args.offsets)) {
      return createErrorResponse('projectPath, gradientPath, colors, and offsets are required.');
    }
    return this.headlessOp('gradient_create', args, a => ({
      projectPath: a.projectPath,
      params: { gradientPath: a.gradientPath, colors: a.colors, offsets: a.offsets },
    }));
  }

  // ── Editor Tools ────────────────────────────────────────────────────────

  private async handleOpenScene(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath) return createErrorResponse('projectPath and scenePath are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    if (!this.godotPath) return createErrorResponse('Godot path not set. Use set_godot_path first.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    const child = spawn(this.godotPath, ['-e', '--path', args.projectPath, '--scene', absScene], {
      stdio: 'ignore',
      detached: true,
    });
    child.unref();
    return { content: [{ type: 'text', text: `Opened editor with scene: ${args.scenePath}` }] };
  }

  private async handleGdextensionList(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) return createErrorResponse('projectPath is required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const files = this.collectFiles(args.projectPath, ['.gdextension']);
    const results: Array<{ path: string; name: string; compatibility: string }> = [];
    for (const f of files) {
      let contentStr = '';
      try { contentStr = readFileSync(f, 'utf8'); } catch { continue; }
      const nameMatch = contentStr.match(/^\[configuration\][\s\S]*?^entry_symbol\s*=\s*"?([^"\n]+)"?/m)
        || contentStr.match(/^\[resource\][\s\S]*?^name\s*=\s*"?([^"\n]+)"?/m);
      const compatMatch = contentStr.match(/^compatibility_minimum\s*=\s*"?([^"\n"]+)"?/m);
      const relPath = f.startsWith(args.projectPath) ? f.slice(args.projectPath.length).replace(/^\//, '') : f;
      results.push({
        path: relPath,
        name: nameMatch ? nameMatch[1].trim() : basename(f, '.gdextension'),
        compatibility: compatMatch ? compatMatch[1].trim() : '',
      });
    }
    return { content: [{ type: 'text', text: JSON.stringify(results, null, 2) }] };
  }

  // ── Node Transform / Order ─────────────────────────────────────────────────

  private async handleReorderNode(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.nodeName || !args.direction)
      return createErrorResponse('projectPath, scenePath, nodeName, and direction are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Read failed: ${e.message}`); }
    const headerEnd = content.indexOf('[node ');
    const header = headerEnd > 0 ? content.slice(0, headerEnd) : '';
    const blocks = content.slice(headerEnd >= 0 ? headerEnd : 0).split(/(?=\[node )/).filter(b => b.trim());
    const idx = blocks.findIndex(b => {
      const m = b.match(/\[node name="([^"]+)"/);
      return m && m[1] === args.nodeName;
    });
    if (idx < 0) return createErrorResponse(`Node "${args.nodeName}" not found.`);
    const targetParent = (blocks[idx].match(/parent="([^"]+)"/) || [])[1] ?? '.';
    const siblingIndices = blocks.reduce<number[]>((acc, b, i) => {
      const p = (b.match(/parent="([^"]+)"/) || [])[1] ?? '.';
      if (p === targetParent) acc.push(i);
      return acc;
    }, []);
    const posInSiblings = siblingIndices.indexOf(idx);
    if (args.direction === 'up' && posInSiblings > 0) {
      const swapIdx = siblingIndices[posInSiblings - 1];
      [blocks[idx], blocks[swapIdx]] = [blocks[swapIdx], blocks[idx]];
    } else if (args.direction === 'down' && posInSiblings < siblingIndices.length - 1) {
      const swapIdx = siblingIndices[posInSiblings + 1];
      [blocks[idx], blocks[swapIdx]] = [blocks[swapIdx], blocks[idx]];
    } else {
      return createErrorResponse(`Cannot move "${args.nodeName}" ${args.direction}: already at boundary.`);
    }
    try { writeFileSync(absScene, header + blocks.join(''), 'utf8'); } catch (e: any) { return createErrorResponse(`Write failed: ${e.message}`); }
    return { content: [{ type: 'text', text: `Node "${args.nodeName}" moved ${args.direction}.` }] };
  }

  private async handleGetNodeTransform(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.nodeName)
      return createErrorResponse('projectPath, scenePath, and nodeName are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Read failed: ${e.message}`); }
    const nodes = this.parseTscnNodes(content);
    const node = nodes.find(n => n.name === args.nodeName);
    if (!node) return createErrorResponse(`Node "${args.nodeName}" not found.`);
    const parseVec2 = (s: string | undefined) => {
      if (!s) return null;
      const m = s.match(/Vector2\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)/);
      return m ? { x: parseFloat(m[1]), y: parseFloat(m[2]) } : null;
    };
    const parseVec3 = (s: string | undefined) => {
      if (!s) return null;
      const m = s.match(/Vector3\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)/);
      return m ? { x: parseFloat(m[1]), y: parseFloat(m[2]), z: parseFloat(m[3]) } : null;
    };
    const posMatch = node.body.match(/position\s*=\s*(Vector[23]\([^)]+\))/);
    const rotMatch = node.body.match(/rotation(?:_degrees)?\s*=\s*([-\d.]+)/);
    const scaleMatch = node.body.match(/scale\s*=\s*(Vector[23]\([^)]+\))/);
    const result = {
      nodeName: args.nodeName,
      position: posMatch ? (parseVec3(posMatch[1]) || parseVec2(posMatch[1])) : null,
      rotation: rotMatch ? parseFloat(rotMatch[1]) : null,
      scale: scaleMatch ? (parseVec3(scaleMatch[1]) || parseVec2(scaleMatch[1])) : null,
    };
    return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] };
  }

  private async handleSetNodeTransform(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.nodeName)
      return createErrorResponse('projectPath, scenePath, and nodeName are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Read failed: ${e.message}`); }
    const nodeRegex = new RegExp(`(\\[node name="${args.nodeName}"[^\\]]*\\][\\s\\S]*?)(?=\\[node |\\[connection |$)`);
    const match = content.match(nodeRegex);
    if (!match) return createErrorResponse(`Node "${args.nodeName}" not found.`);
    let block = match[1];
    const changes: string[] = [];
    if (args.position !== undefined) {
      const p = args.position;
      const vec = p.z !== undefined ? `Vector3(${p.x}, ${p.y}, ${p.z})` : `Vector2(${p.x}, ${p.y})`;
      if (/\nposition\s*=/.test(block)) block = block.replace(/\nposition\s*=.*/, `\nposition = ${vec}`);
      else block = block.replace(/\n$/, '') + `\nposition = ${vec}\n`;
      changes.push(`position=${JSON.stringify(p)}`);
    }
    if (args.rotation !== undefined) {
      const r = args.rotation as number;
      if (/\nrotation\s*=/.test(block)) block = block.replace(/\nrotation\s*=.*/, `\nrotation = ${r}`);
      else block = block.replace(/\n$/, '') + `\nrotation = ${r}\n`;
      changes.push(`rotation=${r}`);
    }
    if (args.scale !== undefined) {
      const s = args.scale;
      const vec = s.z !== undefined ? `Vector3(${s.x}, ${s.y}, ${s.z})` : `Vector2(${s.x}, ${s.y})`;
      if (/\nscale\s*=/.test(block)) block = block.replace(/\nscale\s*=.*/, `\nscale = ${vec}`);
      else block = block.replace(/\n$/, '') + `\nscale = ${vec}\n`;
      changes.push(`scale=${JSON.stringify(s)}`);
    }
    const newContent = content.replace(nodeRegex, block);
    try { writeFileSync(absScene, newContent, 'utf8'); } catch (e: any) { return createErrorResponse(`Write failed: ${e.message}`); }
    return { content: [{ type: 'text', text: `Updated ${changes.join(', ')} on node "${args.nodeName}".` }] };
  }

  // ── Groups ─────────────────────────────────────────────────────────────────

  private async handleListAllGroups(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) return createErrorResponse('projectPath is required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const scenes = this.collectFiles(args.projectPath, ['.tscn']);
    const groups = new Set<string>();
    const groupsByScene: Record<string, string[]> = {};
    for (const scene of scenes) {
      let content: string;
      try { content = readFileSync(scene, 'utf8'); } catch { continue; }
      const sceneGroups: string[] = [];
      const matches = content.matchAll(/groups=\[(.*?)\]/g);
      for (const m of matches) {
        const groupNames = m[1].match(/"([^"]+)"/g)?.map(s => s.slice(1, -1)) || [];
        for (const g of groupNames) { groups.add(g); sceneGroups.push(g); }
      }
      if (sceneGroups.length > 0) {
        const relPath = scene.startsWith(args.projectPath) ? scene.slice(args.projectPath.length + 1) : scene;
        groupsByScene[relPath] = [...new Set(sceneGroups)];
      }
    }
    return { content: [{ type: 'text', text: JSON.stringify({ groups: [...groups].sort(), groupsByScene }, null, 2) }] };
  }

  private async handleAddNodeToGroup(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.nodeName || !args.groupName)
      return createErrorResponse('projectPath, scenePath, nodeName, and groupName are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Read failed: ${e.message}`); }
    const nodeRegex = new RegExp(`(\\[node name="${args.nodeName}"[^\\]]*\\])([\\s\\S]*?)(?=\\[node |\\[connection |$)`);
    const match = content.match(nodeRegex);
    if (!match) return createErrorResponse(`Node "${args.nodeName}" not found.`);
    let block = match[2];
    if (block.includes('groups=[')) {
      if (block.includes(`"${args.groupName}"`)) return { content: [{ type: 'text', text: `Node already in group "${args.groupName}".` }] };
      block = block.replace(/groups=\[([^\]]*)\]/, (_, inner) => `groups=[${inner.trim() ? inner + ', "' + args.groupName + '"' : '"' + args.groupName + '"'}]`);
    } else {
      block = `\ngroups=["${args.groupName}"]` + block;
    }
    const newContent = content.replace(nodeRegex, match[1] + block);
    try { writeFileSync(absScene, newContent, 'utf8'); } catch (e: any) { return createErrorResponse(`Write failed: ${e.message}`); }
    return { content: [{ type: 'text', text: `Node "${args.nodeName}" added to group "${args.groupName}".` }] };
  }

  private async handleRemoveNodeFromGroup(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath || !args.nodeName || !args.groupName)
      return createErrorResponse('projectPath, scenePath, nodeName, and groupName are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Read failed: ${e.message}`); }
    const nodeRegex = new RegExp(`(\\[node name="${args.nodeName}"[^\\]]*\\])([\\s\\S]*?)(?=\\[node |\\[connection |$)`);
    const match = content.match(nodeRegex);
    if (!match) return createErrorResponse(`Node "${args.nodeName}" not found.`);
    let block = match[2];
    if (!block.includes(`"${args.groupName}"`)) return createErrorResponse(`Node "${args.nodeName}" not in group "${args.groupName}".`);
    block = block.replace(new RegExp(`,?\\s*"${args.groupName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"|"${args.groupName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"\\s*,?\\s*`, 'g'), '');
    block = block.replace(/groups=\[\s*\]\n?/, '');
    const newContent = content.replace(nodeRegex, match[1] + block);
    try { writeFileSync(absScene, newContent, 'utf8'); } catch (e: any) { return createErrorResponse(`Write failed: ${e.message}`); }
    return { content: [{ type: 'text', text: `Node "${args.nodeName}" removed from group "${args.groupName}".` }] };
  }

  // ── Plugins ────────────────────────────────────────────────────────────────

  private async handlePluginList(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) return createErrorResponse('projectPath is required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const addonsDir = join(args.projectPath, 'addons');
    const projectFile = join(args.projectPath, 'project.godot');
    const projectContent = existsSync(projectFile) ? readFileSync(projectFile, 'utf8') : '';
    const enabledMatch = projectContent.match(/\[editor_plugins\]([\s\S]*?)(?=\n\[|$)/);
    const enabledPlugins = new Set<string>();
    if (enabledMatch) {
      const pluginMatches = enabledMatch[1].matchAll(/"([^"]+)"\s*=\s*true/g);
      for (const m of pluginMatches) enabledPlugins.add(m[1]);
    }
    const plugins: Array<{ name: string; path: string; enabled: boolean; version?: string }> = [];
    if (existsSync(addonsDir)) {
      const { readdirSync } = await import('node:fs');
      for (const dir of readdirSync(addonsDir)) {
        const pluginCfg = join(addonsDir, dir, 'plugin.cfg');
        if (existsSync(pluginCfg)) {
          const cfg = readFileSync(pluginCfg, 'utf8');
          const nameMatch = cfg.match(/^name\s*=\s*"([^"]+)"/m);
          const versionMatch = cfg.match(/^version\s*=\s*"([^"]+)"/m);
          const pluginPath = `res://addons/${dir}/plugin.cfg`;
          plugins.push({
            name: nameMatch ? nameMatch[1] : dir,
            path: `addons/${dir}`,
            enabled: enabledPlugins.has(pluginPath),
            version: versionMatch ? versionMatch[1] : undefined,
          });
        }
      }
    }
    return { content: [{ type: 'text', text: JSON.stringify({ plugins, enabledCount: plugins.filter(p => p.enabled).length }, null, 2) }] };
  }

  private async handlePluginEnable(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.pluginPath) return createErrorResponse('projectPath and pluginPath are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    let content = readFileSync(projectFile, 'utf8');
    const entry = `"${args.pluginPath}"=true`;
    if (content.includes(entry)) return { content: [{ type: 'text', text: `Plugin "${args.pluginPath}" is already enabled.` }] };
    if (content.includes('[editor_plugins]')) {
      content = content.replace('[editor_plugins]', `[editor_plugins]\n\n${entry}`);
    } else {
      content += `\n[editor_plugins]\n\n${entry}\n`;
    }
    writeFileSync(projectFile, content, 'utf8');
    return { content: [{ type: 'text', text: `Plugin "${args.pluginPath}" enabled.` }] };
  }

  private async handlePluginDisable(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.pluginPath) return createErrorResponse('projectPath and pluginPath are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const projectFile = join(args.projectPath, 'project.godot');
    if (!existsSync(projectFile)) return createErrorResponse(`Not a valid Godot project: ${args.projectPath}`);
    let content = readFileSync(projectFile, 'utf8');
    const pattern = new RegExp(`\\n?"${args.pluginPath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"=true\\n?`, 'g');
    const newContent = content.replace(pattern, '\n');
    if (newContent === content) return createErrorResponse(`Plugin "${args.pluginPath}" not found or not enabled.`);
    writeFileSync(projectFile, newContent, 'utf8');
    return { content: [{ type: 'text', text: `Plugin "${args.pluginPath}" disabled.` }] };
  }

  // ── Assets ─────────────────────────────────────────────────────────────────

  private async handleShaderCreate(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.shaderPath) return createErrorResponse('projectPath and shaderPath are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absPath = this.resolveResPath(args.projectPath, args.shaderPath);
    const templates: Record<string, string> = {
      canvas_item: `shader_type canvas_item;\n\nvoid fragment() {\n\tCOLOR = texture(TEXTURE, UV);\n}\n`,
      spatial: `shader_type spatial;\n\nvoid fragment() {\n\tALBEDO = vec3(1.0);\n}\n`,
      particles: `shader_type particles;\n\nvoid process() {\n\t// particle logic here\n}\n`,
    };
    const type = args.shaderType || 'canvas_item';
    const template = templates[type] || templates['canvas_item'];
    if (existsSync(absPath) && !args.overwrite) return createErrorResponse(`File already exists: ${absPath}. Set overwrite=true to replace.`);
    try { writeFileSync(absPath, template, 'utf8'); } catch (e: any) { return createErrorResponse(`Write failed: ${e.message}`); }
    return { content: [{ type: 'text', text: `Created ${type} shader at ${args.shaderPath}.` }] };
  }

  private async handleMaterialCreate(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.materialPath) return createErrorResponse('projectPath and materialPath are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absPath = this.resolveResPath(args.projectPath, args.materialPath);
    const type = args.materialType || 'StandardMaterial3D';
    const templates: Record<string, string> = {
      StandardMaterial3D: `[gd_resource type="StandardMaterial3D" format=3]\n\n[resource]\n`,
      CanvasItemMaterial: `[gd_resource type="CanvasItemMaterial" format=3]\n\n[resource]\n`,
      ShaderMaterial: `[gd_resource type="ShaderMaterial" format=3]\n\n[resource]\n`,
    };
    const content = templates[type] || templates['StandardMaterial3D'];
    if (existsSync(absPath) && !args.overwrite) return createErrorResponse(`File already exists: ${absPath}. Set overwrite=true to replace.`);
    try { writeFileSync(absPath, content, 'utf8'); } catch (e: any) { return createErrorResponse(`Write failed: ${e.message}`); }
    return { content: [{ type: 'text', text: `Created ${type} material at ${args.materialPath}.` }] };
  }

  private async handleScriptTemplate(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scriptPath || !args.baseClass) return createErrorResponse('projectPath, scriptPath, and baseClass are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absPath = this.resolveResPath(args.projectPath, args.scriptPath);
    const cn = args.className ? `class_name ${args.className}\n` : '';
    const templates: Record<string, string> = {
      CharacterBody2D: `extends CharacterBody2D\n${cn}\nconst SPEED = 200.0\nconst JUMP_VELOCITY = -400.0\n\nfunc _physics_process(delta: float) -> void:\n\tif not is_on_floor():\n\t\tvelocity += get_gravity() * delta\n\tvar direction := Input.get_axis("ui_left", "ui_right")\n\tvelocity.x = direction * SPEED if direction else move_toward(velocity.x, 0, SPEED)\n\tmove_and_slide()\n`,
      CharacterBody3D: `extends CharacterBody3D\n${cn}\nconst SPEED = 5.0\nconst JUMP_VELOCITY = 4.5\n\nfunc _physics_process(delta: float) -> void:\n\tif not is_on_floor():\n\t\tvelocity += get_gravity() * delta\n\tvar input_dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")\n\tvar direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()\n\tvelocity.x = direction.x * SPEED if direction else move_toward(velocity.x, 0, SPEED)\n\tvelocity.z = direction.z * SPEED if direction else move_toward(velocity.z, 0, SPEED)\n\tmove_and_slide()\n`,
      RigidBody2D: `extends RigidBody2D\n${cn}\nfunc _ready() -> void:\n\tpass\n\nfunc _physics_process(_delta: float) -> void:\n\tpass\n`,
      Area2D: `extends Area2D\n${cn}\nfunc _ready() -> void:\n\tbody_entered.connect(_on_body_entered)\n\nfunc _on_body_entered(body: Node2D) -> void:\n\tpass\n`,
      Node: `extends Node\n${cn}\nfunc _ready() -> void:\n\tpass\n\nfunc _process(_delta: float) -> void:\n\tpass\n`,
    };
    const baseKey = Object.keys(templates).find(k => k === args.baseClass) || 'Node';
    const template = templates[baseKey] || `extends ${args.baseClass}\n${cn}\nfunc _ready() -> void:\n\tpass\n`;
    if (existsSync(absPath) && !args.overwrite) return createErrorResponse(`File already exists: ${absPath}. Set overwrite=true to replace.`);
    try { writeFileSync(absPath, template, 'utf8'); } catch (e: any) { return createErrorResponse(`Write failed: ${e.message}`); }
    return { content: [{ type: 'text', text: `Script template for ${args.baseClass} created at ${args.scriptPath}.` }] };
  }

  // ── Export ─────────────────────────────────────────────────────────────────

  private async handleExportListPresets(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath) return createErrorResponse('projectPath is required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const presetsFile = join(args.projectPath, 'export_presets.cfg');
    if (!existsSync(presetsFile)) return { content: [{ type: 'text', text: JSON.stringify({ presets: [] }) }] };
    let content: string;
    try { content = readFileSync(presetsFile, 'utf8'); } catch (e: any) { return createErrorResponse(`Read failed: ${e.message}`); }
    const presets: Array<{ name: string; platform: string; runnable: boolean }> = [];
    const presetMatches = content.matchAll(/\[preset\.\d+\]([\s\S]*?)(?=\n\[preset\.|$)/g);
    for (const m of presetMatches) {
      const block = m[1];
      const nameMatch = block.match(/^name\s*=\s*"([^"]+)"/m);
      const platformMatch = block.match(/^platform\s*=\s*"([^"]+)"/m);
      const runnableMatch = block.match(/^runnable\s*=\s*(true|false)/m);
      if (nameMatch) presets.push({
        name: nameMatch[1],
        platform: platformMatch ? platformMatch[1] : 'unknown',
        runnable: runnableMatch ? runnableMatch[1] === 'true' : false,
      });
    }
    return { content: [{ type: 'text', text: JSON.stringify({ presets }, null, 2) }] };
  }

  // ── TileMap (runtime) ──────────────────────────────────────────────────────

  private async handleTilemapSetCell(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath) return createErrorResponse('nodePath is required.');
    return this.gameCommand('tilemap_set_cell', args, a => ({
      node_path: a.nodePath,
      layer: a.layer ?? 0,
      x: a.x ?? 0,
      y: a.y ?? 0,
      source_id: a.sourceId ?? 0,
      atlas_coords_x: a.atlasCoordsX ?? 0,
      atlas_coords_y: a.atlasCoordsY ?? 0,
      alternative_tile: a.alternativeTile ?? 0,
    }));
  }

  private async handleTilemapGetUsedCells(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath) return createErrorResponse('nodePath is required.');
    return this.gameCommand('tilemap_get_used_cells', args, a => ({
      node_path: a.nodePath,
      layer: a.layer ?? 0,
    }));
  }

  private async handleTilemapClear(args: any) {
    args = normalizeParameters(args || {});
    if (!args.nodePath) return createErrorResponse('nodePath is required.');
    return this.gameCommand('tilemap_clear', args, a => ({
      node_path: a.nodePath,
      layer: a.layer ?? 0,
    }));
  }

  // ── Audio Bus (runtime) ────────────────────────────────────────────────────

  private async handleAudioBusList(args: any) {
    args = normalizeParameters(args || {});
    return this.gameCommand('audio_bus_list', args, () => ({}));
  }

  private async handleAudioBusCreate(args: any) {
    args = normalizeParameters(args || {});
    if (!args.busName) return createErrorResponse('busName is required.');
    return this.gameCommand('audio_bus_create', args, a => ({ bus_name: a.busName }));
  }

  private async handleAudioBusSetVolume(args: any) {
    args = normalizeParameters(args || {});
    if (!args.busName || args.volumeDb === undefined) return createErrorResponse('busName and volumeDb are required.');
    return this.gameCommand('audio_bus_set_volume', args, a => ({
      bus_name: a.busName,
      volume_db: a.volumeDb,
    }));
  }

  private async handleAudioBusAddEffect(args: any) {
    args = normalizeParameters(args || {});
    if (!args.busName || !args.effectType) return createErrorResponse('busName and effectType are required.');
    return this.gameCommand('audio_bus_add_effect', args, a => ({
      bus_name: a.busName,
      effect_type: a.effectType,
      effect_params: a.effectParams ?? {},
    }));
  }

  // ── Performance / Batch (runtime) ──────────────────────────────────────────

  private async handleGetPerformanceCounters(args: any) {
    args = normalizeParameters(args || {});
    return this.gameCommand('get_performance_counters', args, a => ({
      counter_names: a.counterNames ?? [],
    }));
  }

  private async handleBatchSetProperties(args: any) {
    args = normalizeParameters(args || {});
    if (!args.operations || !Array.isArray(args.operations) || args.operations.length === 0)
      return createErrorResponse('operations array is required and must not be empty.');
    return this.gameCommand('batch_set_properties', args, a => ({ operations: a.operations }));
  }

  // ── Class API / Scene Info ─────────────────────────────────────────────────

  private async handleGetClassApi(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.className) return createErrorResponse('projectPath and className are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    return this.headlessOp('get_class_api', args, a => ({
      projectPath: a.projectPath,
      params: { class_name: a.className },
    }));
  }

  private async handleSceneNodeCount(args: any) {
    args = normalizeParameters(args || {});
    if (!args.projectPath || !args.scenePath) return createErrorResponse('projectPath and scenePath are required.');
    if (!validatePath(args.projectPath)) return createErrorResponse('Invalid path.');
    const absScene = this.resolveResPath(args.projectPath, args.scenePath);
    if (!existsSync(absScene)) return createErrorResponse(`Scene not found: ${absScene}`);
    let content: string;
    try { content = readFileSync(absScene, 'utf8'); } catch (e: any) { return createErrorResponse(`Read failed: ${e.message}`); }
    const count = (content.match(/^\[node /gm) || []).length;
    const connectionCount = (content.match(/^\[connection /gm) || []).length;
    return { content: [{ type: 'text', text: JSON.stringify({ nodeCount: count, connectionCount, scenePath: args.scenePath }, null, 2) }] };
  }

}

// Create and run the server
const server = new GodotServer();
server.run().catch((error: unknown) => {
  const errorMessage = error instanceof Error ? error.message : 'Unknown error';
  console.error('Failed to run server:', errorMessage);
  process.exit(1);
});
