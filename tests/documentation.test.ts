import { describe, expect, it } from 'vitest';
import { existsSync, readFileSync, readdirSync } from 'fs';
import { dirname, join, resolve } from 'path';

function markdownFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? markdownFiles(path) : path.endsWith('.md') ? [path] : [];
  });
}

const files = ['README.md', 'CHANGELOG.md', 'SECURITY.md', 'SUPPORT.md', ...markdownFiles('docs')];

describe('Documentation', () => {
  it('has no broken relative Markdown links', () => {
    const broken: Array<{ file: string; target: string }> = [];
    for (const file of files) {
      const text = readFileSync(file, 'utf8');
      for (const match of text.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
        const target = match[1];
        if (/^(?:https?:|mailto:|#)/.test(target)) continue;
        const path = target.split('#')[0];
        if (path && !existsSync(resolve(dirname(file), path))) broken.push({ file, target });
      }
    }
    expect(broken).toEqual([]);
  });

  it('keeps release metadata and documentation synchronized', () => {
    const packageJson = JSON.parse(readFileSync('package.json', 'utf8'));
    const serverJson = JSON.parse(readFileSync('server.json', 'utf8'));
    const readme = readFileSync('README.md', 'utf8');
    const changelog = readFileSync('CHANGELOG.md', 'utf8');
    expect(packageJson.name).toBe('godot-mcp-1969');
    expect(packageJson.version).toBe('1.0.0');
    expect(serverJson.version).toBe(packageJson.version);
    expect(readme).toContain('npm install -g godot-mcp-1969');
    expect(readme).not.toContain('once published');
    expect(changelog).toContain('## 1.0.0 - 2026-07-12');
  });
});
