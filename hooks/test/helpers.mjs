// Shared test helpers for the pre-commit hook (#124).
//
// All tests run the hook as a subprocess against a freshly-built fixture repo
// laid down in a tmpdir. Helpers here cover: (a) creating that fixture repo
// with a configurable manifest of TypeScript source files; (b) staging files
// for commit; (c) spawning the hook with the matching argv shape the
// `pre-commit` framework would use; (d) cleanup.

import { spawnSync } from 'node:child_process';
import {
  mkdirSync,
  writeFileSync,
  mkdtempSync,
  rmSync,
  readFileSync,
  existsSync,
  statSync,
  utimesSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
export const HOOK_PATH = resolve(__dirname, '..', 'pre-commit-audit.mjs');
export const REPO_ROOT = resolve(__dirname, '..', '..');

/**
 * Create a temporary git repo with a TypeScript file manifest. Returns
 * { root, cleanup }. The repo is initialized with a single root commit
 * (so `git diff --cached` and `git rev-parse` work without warnings) and
 * any files in `manifest` are written to disk and `git add`-ed.
 *
 * @param {Object<string,string>} manifest  Path → file contents.
 * @param {{ stagedSubset?: string[] }} [opts]  If given, only paths in
 *   `stagedSubset` are staged (the rest stay in the working tree).
 */
export function makeFixtureRepo(manifest, opts = {}) {
  const root = mkdtempSync(join(tmpdir(), 'code-audit-hook-'));
  const env = { ...process.env, GIT_TERMINAL_PROMPT: '0' };
  const git = (...args) => spawnSync('git', args, { cwd: root, encoding: 'utf8', env });
  git('init', '-q', '-b', 'main');
  git('config', 'user.email', 'test@example.com');
  git('config', 'user.name', 'Test');
  git('config', 'commit.gpgsign', 'false');

  // Drop in an initial baseline file + commit so HEAD exists.
  writeFileSync(join(root, '.gitignore'), 'node_modules/\n');
  git('add', '.gitignore');
  git('commit', '-q', '-m', 'initial');

  const written = [];
  for (const [rel, content] of Object.entries(manifest)) {
    const abs = join(root, rel);
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, content);
    written.push(rel);
  }

  const toStage = opts.stagedSubset ?? written;
  if (toStage.length > 0) {
    git('add', '--', ...toStage);
  }

  return {
    root,
    git,
    cleanup() {
      try { rmSync(root, { recursive: true, force: true }); } catch { /* ignore */ }
    },
  };
}

/**
 * Run the pre-commit hook with the given staged file list, mimicking the
 * pre-commit framework's invocation (`node hooks/pre-commit-audit.mjs <files>`).
 * `cwd` defaults to the fixture repo root.
 */
export function runHook(stagedPaths, { cwd, env = {}, timeoutMs = 30000 } = {}) {
  const res = spawnSync('node', [HOOK_PATH, ...stagedPaths], {
    cwd,
    encoding: 'utf8',
    env: { ...process.env, ...env },
    timeout: timeoutMs,
  });
  return {
    status: res.status,
    stdout: res.stdout,
    stderr: res.stderr,
    error: res.error,
  };
}

/**
 * Read the cache meta JSON from .git/audit/catalog.meta.json. Returns null
 * if the file doesn't exist (cold path that bailed before writing).
 */
export function readMeta(repoRoot) {
  const p = join(repoRoot, '.git', 'audit', 'catalog.meta.json');
  if (!existsSync(p)) return null;
  return JSON.parse(readFileSync(p, 'utf8'));
}

/**
 * Read the most recent report markdown.
 */
export function readReport(repoRoot) {
  const p = join(repoRoot, '.git', 'audit', 'last-report.md');
  if (!existsSync(p)) return null;
  return readFileSync(p, 'utf8');
}

/**
 * Read timing log lines (opt-in via CODE_AUDIT_TIMING=1). Returns array.
 */
export function readTimingLog(repoRoot) {
  const p = join(repoRoot, '.git', 'audit', 'timing.log');
  if (!existsSync(p)) return [];
  return readFileSync(p, 'utf8').split('\n').filter(Boolean);
}

/**
 * Touch a file forward in time (mtime). Used to verify cache-staleness
 * detection. Default is +60s into the future.
 */
export function touchForward(absPath, secondsForward = 60) {
  const st = statSync(absPath);
  const newMtime = new Date(st.mtimeMs + secondsForward * 1000);
  utimesSync(absPath, newMtime, newMtime);
}

/**
 * Touch a file backward to simulate "built more than TTL ago".
 */
export function touchBackward(absPath, secondsBackward) {
  const st = statSync(absPath);
  const newMtime = new Date(st.mtimeMs - secondsBackward * 1000);
  utimesSync(absPath, newMtime, newMtime);
}

/**
 * Manually rewrite the meta file's `built_at` to look older than `ageMs`.
 */
export function ageCacheMeta(repoRoot, ageMs) {
  const p = join(repoRoot, '.git', 'audit', 'catalog.meta.json');
  const meta = JSON.parse(readFileSync(p, 'utf8'));
  meta.built_at = Date.now() - ageMs;
  writeFileSync(p, JSON.stringify(meta));
}
