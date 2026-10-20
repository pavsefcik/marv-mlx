/**
 * marv-mlx — keeps pi's list of local MLX models in sync with what's actually
 * downloaded in the Hugging Face hub cache, and starts/switches marv-mlx to the
 * selected local model on :11500.
 *
 * Distributed as part of the marv-mlx repo (a pi package):
 *
 *   pi install git:github.com/pavsefcik/marv-mlx
 *
 * or copied into ~/.pi/agent/extensions/marv-mlx.ts — `sh install.sh` from a
 * clone does the copy and generates the ~/.pi/agent/bin/marv-mlx wrapper for you.
 * Hot-reload with /reload. The factory runs on every pi start and /reload.
 *
 * Commands:
 *   /marv-mlx-sync   re-scan the HF hub cache and re-register the "local" provider
 *   /marv-mlx-setup  install/repair marv-mlx + deps (uv, gum, mlx-vlm — no brew,
 *                no Xcode CLT needed) and wire
 *                pi → marv-mlx: copy marv-mlx.zsh (+ lib, curated-llms.md) to
 *                ~/.local/share/marv-mlx (a stable dir, because pi resets
 *                git-package checkouts on update) and write the
 *                ~/.pi/agent/bin/marv-mlx wrapper. Also offered automatically on
 *                session start when marv-mlx isn't wired in yet.
 *
 * Discovery: scans ~/.cache/huggingface/hub for `models--*` directories and
 * re-registers the local provider via `pi.registerProvider(..., { models })`,
 * exactly like marv-mlx's own enumerator (`models--ORG--NAME` -> `ORG/NAME`). So
 * /model, Ctrl+P cycling and `pi --list-models` always show what's on disk.
 *
 * Selection: on `model_select`, if the newly selected model belongs to the local
 * MLX provider, runs `marv-mlx run <model-id>` headless (blocking until the server
 * is ready) so pi's next request hits the right model. Each registered model
 * carries pi-ai `compat` (system role, no reasoning_effort, qwen-chat-template
 * thinking) so requests match what mlx_vlm.server expects.
 *
 * Environment (all optional):
 *   MARV_MLX_PI_PROVIDER  provider name in pi's catalog (default "local")
 *   MARV_MLX_HUB_DIR      HF hub cache dir        (default ~/.cache/huggingface/hub)
 *   MARV_MLX_BIN          wrapper path            (default ~/.pi/agent/bin/marv-mlx)
 *   MARV_MLX_REPO         marv-mlx repo root          (default: pi's git-package clone)
 *   MARV_MLX_ZSH          explicit path to marv-mlx.zsh
 *   MARV_MLX_STABLE_DIR   dir marv-mlx.zsh is copied to (default ~/.local/share/marv-mlx)
 */

import { execFile } from "node:child_process";
import { constants as FS_CONST } from "node:fs";
import {
  access,
  chmod,
  copyFile,
  mkdir,
  readFile,
  readdir,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { promisify } from "node:util";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const execFileRaw = promisify(execFile);

// uv and gum both install into the user's own bin dir (no Homebrew), which pi's
// inherited PATH may not know about yet when setup runs in-process.
const LOCAL_BIN = process.env.XDG_BIN_HOME ?? join(homedir(), ".local", "bin");
function pathEnv(): NodeJS.ProcessEnv {
  return { ...process.env, PATH: `${LOCAL_BIN}:${process.env.PATH ?? ""}` };
}

/** execFile with LOCAL_BIN prepended to PATH (uv/gum live there). */
async function execFileP(
  file: string,
  args: readonly string[],
  opts: Record<string, unknown> = {}
): Promise<{ stdout: string; stderr: string }> {
  return (
    execFileRaw as unknown as (
      f: string,
      a: readonly string[],
      o: Record<string, unknown>
    ) => Promise<{ stdout: string; stderr: string }>
  )(file, args, { ...opts, env: pathEnv() });
}

// gum release used by install.sh and /marv-mlx-setup alike (keep in sync —
// `make doctor` guards these).
const GUM_VERSION = "2.0.2";
const GUM_SHA256 = "4777a69b1170b8db23c95d5889fb32186cfda1a3ac950d339aa17e3513633890";
// Astral's standalone uv installer: a prebuilt binary, so no compiler, no
// Xcode CLT and no Homebrew on the happy path. UV_NO_MODIFY_PATH keeps PATH
// wiring in our hands (one line per bin dir in ~/.zshrc).
const UV_INSTALL_CMD =
  "curl -LsSf https://astral.sh/uv/install.sh | UV_NO_MODIFY_PATH=1 sh";

// Provider name for marv-mlx in pi's model catalog (defaults to "local", matching models.json).
const MARV_MLX_PROVIDER = process.env.MARV_MLX_PI_PROVIDER ?? "local";
// Wrapper that executes the real marv-mlx.zsh headlessly. install.sh writes this;
// /marv-mlx-setup can too.
const WRAPPER =
  process.env.MARV_MLX_BIN ?? join(homedir(), ".pi", "agent", "bin", "marv-mlx");
// Where marv-mlx keeps its downloaded MLX models (Hugging Face hub cache).
const HUB_DIR =
  process.env.MARV_MLX_HUB_DIR ?? join(homedir(), ".cache", "huggingface", "hub");
// Stable copy target for marv-mlx.zsh + lib/: pi git-packages get reset on
// `pi update --extensions`, so the wrapper must never point into the package
// clone. install.sh points the wrapper at the repo directly (fine — it's the
// user's own clone); /marv-mlx-setup copies into this dir instead.
const MARV_MLX_STABLE =
  process.env.MARV_MLX_STABLE_DIR ?? join(homedir(), ".local", "share", "marv-mlx");
// Where the pi git-package clone lands when installed via
// `pi install git:github.com/pavsefcik/marv-mlx` (docs/packages.md).
const MARV_MLX_CLONE = join(
  homedir(),
  ".pi",
  "agent",
  "git",
  "github.com",
  "pavsefcik",
  "marv-mlx"
);
const LOAD_TIMEOUT_MS = 25 * 60 * 1000; // matches marv-mlx's readiness loop

const ZERO_COST = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

interface LocalModel {
  id: string;
  name: string;
  reasoning: boolean;
  input: ("image" | "text")[];
  contextWindow: number;
  maxTokens: number;
  cost: typeof ZERO_COST;
  thinkingLevelMap: { off: string; low: string; high: string };
  compat: {
    supportsDeveloperRole: false;
    supportsReasoningEffort: false;
    thinkingFormat: "qwen-chat-template";
  };
}

interface SetupUI {
  setStatus(key: string, value: string): void;
  notify(message: string, type?: "error" | "info" | "warning"): void;
}

/* ------------------------------------------------------------------ */
/* Small helpers                                                      */
/* ------------------------------------------------------------------ */

async function pathOk(p: string | undefined, mode = FS_CONST.R_OK): Promise<boolean> {
  if (!p) return false;
  try {
    await access(p, mode);
    return true;
  } catch {
    return false;
  }
}

/** Whether a command is available on PATH. */
async function onPath(cmd: string): Promise<boolean> {
  try {
    await execFileP("sh", ["-c", `command -v ${cmd}`]);
    return true;
  } catch {
    return false;
  }
}

function errMsg(err: unknown): string {
  const e = err as { stderr?: string; stdout?: string; message?: string };
  return e.stderr?.trim() || e.message || String(err);
}

/**
 * Resolve a directory from uv (`uv tool dir` / `uv tool dir --bin`).
 * uv's dirs are configurable (UV_TOOL_BIN_DIR, XDG_BIN_HOME, XDG_DATA_HOME) and
 * depend on how uv was installed, so we ask uv — only falling back to the
 * hardcoded default when the query itself fails (matching install.sh step 4).
 */
async function uvDir(args: string[], fallback: string): Promise<string> {
  try {
    return (await execFileP("uv", args)).stdout.trim() || fallback;
  } catch {
    return fallback;
  }
}

/** First marv-mlx.zsh we can find: explicit env, then known repo locations. */
async function findMarvMlxZsh(): Promise<string | undefined> {
  const env = process.env.MARV_MLX_ZSH;
  if (await pathOk(env)) return env;
  const roots = [
    process.env.MARV_MLX_REPO,
    MARV_MLX_CLONE,
    join(homedir(), "Dev", "projects", "marv-mlx"), // local clone (dev fallback)
  ];
  for (const root of roots) {
    if (!root) continue;
    const zsh = join(root, "marv-mlx.zsh");
    if (await pathOk(zsh)) return zsh;
  }
  return undefined;
}

async function ensureLocalBinOnPath(ui: SetupUI, uvToolBin: string): Promise<void> {
  if (!(await pathOk(join(uvToolBin, "mlx_vlm.server"), FS_CONST.X_OK))) return;
  const zshrc = join(homedir(), ".zshrc");
  try {
    const cur = await readFile(zshrc, "utf8").catch(() => "");
    // Mirror install.sh step 5: wire the dirs uv actually used, not a hardcoded
    // ~/.local/bin (uv's bin dir is configurable via UV_TOOL_BIN_DIR / XDG_BIN_HOME).
    // LOCAL_BIN is where uv and gum themselves live.
    let next = cur;
    for (const dir of [LOCAL_BIN, uvToolBin]) {
      if (next.includes(dir)) continue;
      next = `${next}\nexport PATH="${dir}:$PATH"\n`;
      ui.notify(`marv-mlx-setup: appended ${dir} to ~/.zshrc`, "info");
    }
    if (next !== cur) await writeFile(zshrc, next);
  } catch {
    // best effort
  }
}

/**
 * Install uv from Astral's standalone installer (matches install.sh step 2).
 * Homebrew is only a fallback for hosts where the download fails.
 */
async function ensureUv(ui: SetupUI, key: string): Promise<boolean> {
  if (await onPath("uv")) return true;
  ui.setStatus(key, "⟳ installing uv…");
  try {
    await execFileP("sh", ["-c", UV_INSTALL_CMD], { timeout: 15 * 60 * 1000 });
  } catch (err) {
    if (await onPath("brew")) {
      try {
        await execFileP("brew", ["install", "uv"], { timeout: 15 * 60 * 1000 });
      } catch (err2) {
        ui.notify(`marv-mlx-setup: uv install failed — ${errMsg(err2)}`, "error");
        return false;
      }
    } else {
      ui.notify(
        `marv-mlx-setup: uv install failed — ${errMsg(err)}\nInstall it from https://docs.astral.sh/uv/ and re-run.`,
        "error"
      );
      return false;
    }
  }
  if (!(await onPath("uv"))) {
    ui.notify(
      `marv-mlx-setup: uv installed to ${LOCAL_BIN} but isn't on PATH yet — open a new terminal, then re-run /marv-mlx-setup`,
      "error"
    );
    return false;
  }
  return true;
}

/**
 * Install gum from its GitHub release binary (matches install.sh step 3): a
 * standalone Go binary, so no Homebrew and no Xcode CLT. sha256-checked against
 * the digest pinned above; brew is only a fallback when the download fails.
 */
async function ensureGum(ui: SetupUI, key: string): Promise<boolean> {
  if (await onPath("gum")) return true;
  ui.setStatus(key, `⟳ installing gum ${GUM_VERSION}…`);
  const script = [
    "set -e",
    'tmp="$(mktemp -d "${TMPDIR:-/tmp}/marv-mlx-gum.XXXXXX")"',
    'trap \'rm -rf "$tmp"\' EXIT',
    `url="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Darwin_arm64.tar.gz"`,
    'curl -fsSL "$url" -o "$tmp/gum.tar.gz"',
    'got="$(shasum -a 256 "$tmp/gum.tar.gz" | cut -d" " -f1)"',
    `[ "$got" = "${GUM_SHA256}" ] || { echo "checksum mismatch: $got" >&2; exit 1; }`,
    'tar -xzf "$tmp/gum.tar.gz" -C "$tmp"',
    'bin="$(find "$tmp" -type f -name gum | head -n1)"',
    `mkdir -p "${LOCAL_BIN}"`,
    `install -m 755 "$bin" "${LOCAL_BIN}/gum"`,
  ].join("\n");
  try {
    await execFileP("sh", ["-c", script], { timeout: 10 * 60 * 1000 });
  } catch (err) {
    if (await onPath("brew")) {
      try {
        await execFileP("brew", ["install", "gum"], { timeout: 15 * 60 * 1000 });
      } catch (err2) {
        ui.notify(`marv-mlx-setup: gum install failed — ${errMsg(err2)}`, "error");
        return false;
      }
    } else {
      ui.notify(
        `marv-mlx-setup: gum download failed — ${errMsg(err)}\nCheck your network and re-run /marv-mlx-setup.`,
        "error"
      );
      return false;
    }
  }
  return onPath("gum");
}

/**
 * Install the APC sitecustomize into the mlx-vlm uv tool env so prefix caching
 * is on for every server launch from that env, whatever launched it.
 * Idempotent (content-compare); a foreign sitecustomize.py is left untouched.
 */
async function installApcSitecustomize(ui: SetupUI): Promise<void> {
  const marker = "marv-mlx APC sitecustomize";
  const zsh = await findMarvMlxZsh();
  const src = zsh
    ? join(dirname(zsh), "lib", "marv-mlx-apc-sitecustomize.py")
    : join(MARV_MLX_STABLE, "lib", "marv-mlx-apc-sitecustomize.py");
  if (!(await pathOk(src))) return;

  let toolsDir: string;
  try {
    toolsDir = (await execFileP("uv", ["tool", "dir"])).stdout.trim();
  } catch {
    toolsDir = join(homedir(), ".local", "share", "uv", "tools");
  }
  const libDir = join(toolsDir, "mlx-vlm", "lib");
  let sp: string | undefined;
  try {
    for (const name of await readdir(libDir)) {
      const candidate = join(libDir, name, "site-packages");
      if (name.startsWith("python") && (await pathOk(candidate))) {
        sp = candidate;
        break;
      }
    }
  } catch {
    return; // no mlx-vlm tool env yet
  }
  if (!sp) return;

  const dst = join(sp, "sitecustomize.py");
  try {
    let cur: string | undefined;
    try {
      cur = await readFile(dst, "utf8");
    } catch {
      cur = undefined; // not present yet
    }
    if (cur !== undefined && !cur.includes(marker)) {
      ui.notify(`marv-mlx-setup: foreign sitecustomize.py in ${sp} — left untouched`, "info");
      return;
    }
    const want = await readFile(src, "utf8");
    if (cur !== want) {
      await copyFile(src, dst);
      ui.notify(`marv-mlx-setup: APC sitecustomize installed in ${sp} (prefix caching on for any launcher)`, "info");
    }
  } catch (err) {
    ui.notify(`marv-mlx-setup: APC sitecustomize install failed — ${errMsg(err)}`, "error");
  }
}

/**
 * /marv-mlx-setup — idempotent install/repair:
 *   1. uv (Astral standalone installer; brew only as a fallback)
 *   2. gum (sha256-checked release binary; brew only as a fallback)
 *   3. mlx-vlm+jinja2+setproctitle (uv tool)
 *   4. PATH fix 5. stable marv-mlx.zsh copy + generated wrapper
 */
let setupRunning = false;

async function runSetup(ui: SetupUI): Promise<void> {
  if (setupRunning) {
    ui.notify("marv-mlx-setup: already running", "info");
    return;
  }
  setupRunning = true;
  const key = "marv-mlx-setup";
  try {
    ui.setStatus(key, "⟳ marv-mlx setup…");

    // 1-2. uv + gum — brew-free and CLT-free, exactly like install.sh.
    if (!(await ensureUv(ui, key))) return;
    if (!(await ensureGum(ui, key))) return;

    // 3. mlx-vlm as a uv tool — mirrors install.sh step 4 so pi-managed setups
    //    get the identical, reproducible env: pinned version, jinja2
    //    (apply_chat_template needs it for every request and mlx-vlm's own
    //    requirements don't declare it), setproctitle (server renames itself to
    //    the model in ps/Activity Monitor), and --force. Resolve uv's tool + bin
    //    dirs up front (configurable, so don't hardcode them).
    ui.setStatus(key, "⟳ installing mlx-vlm (uv tool)…");
    const uvToolBin = await uvDir(["tool", "dir", "--bin"], join(homedir(), ".local", "bin"));
    const uvToolDir = await uvDir(["tool", "dir"], join(homedir(), ".local", "share", "uv", "tools"));
    // The tool is large and network-bound; retry the install a couple of times.
    let installed = false;
    for (let attempt = 1; attempt <= 3 && !installed; attempt++) {
      try {
        await execFileP(
          "uv",
          ["tool", "install", "mlx-vlm@0.7.4", "--with", "jinja2", "--with", "setproctitle", "--force"],
          { timeout: 15 * 60 * 1000 }
        );
        installed = true;
      } catch (err) {
        if (attempt === 3) {
          ui.notify(`marv-mlx-setup: mlx-vlm install failed after ${attempt} attempts — ${errMsg(err)}`, "error");
          return;
        }
        ui.setStatus(key, `⟳ mlx-vlm install failed — retrying (attempt ${attempt})…`);
      }
    }

    // uv occasionally fails to link every console script (seen: it links only
    // convert+generate and skips mlx_vlm.server). marv-mlx needs
    // mlx_vlm.server, so synthesize the same fallback shim install.sh writes.
    if (!(await pathOk(join(uvToolBin, "mlx_vlm.server"), FS_CONST.X_OK)) && !(await onPath("mlx_vlm.server"))) {
      try {
        const shim = join(uvToolBin, "mlx_vlm.server");
        await mkdir(uvToolBin, { recursive: true });
        await writeFile(
          shim,
          `#!/usr/bin/env bash\n` +
            `# marv-mlx fallback shim — uv didn't link mlx_vlm.server; run the tool env module.\n` +
            `exec "${uvToolDir}/mlx-vlm/bin/python" -m mlx_vlm.server "$@"\n`
        );
        await chmod(shim, 0o755);
        ui.notify(`marv-mlx-setup: created mlx_vlm.server shim in ${uvToolBin} (uv did not link it)`, "info");
      } catch (err) {
        ui.notify(`marv-mlx-setup: could not create mlx_vlm.server shim — ${errMsg(err)}`, "error");
        return;
      }
    }

    // 4b. Prune unused heavy deps (install.sh step 4b): an older mlx-vlm — or a
    //     stale/extra'd env — can leave `datasets` (-> pandas/pyarrow, ~160MB)
    //     behind. It is never used at inference/server runtime. opencv/scipy/
    //     mlx-audio are deliberately kept (VLM/audio models need them).
    try {
      await execFileP(
        "uv",
        [
          "pip",
          "uninstall",
          "--python",
          join(uvToolDir, "mlx-vlm", "bin", "python"),
          "-q",
          "datasets",
          "pandas",
          "pyarrow",
        ],
        { timeout: 5 * 60 * 1000 }
      );
    } catch {
      // best effort — pruning is an optimization, not a requirement
    }

    // 4c. APC sitecustomize: default mlx-vlm's prefix caching ON inside the
    //     tool env, so servers launched by ANY tool (marv's embedded launch
    //     included — it spawns mlx_vlm.server directly, bypassing marv-mlx)
    //     reuse the conversation KV instead of re-prefilling every turn.
    await installApcSitecustomize(ui);

    // 5. uv's tool bin dir on PATH for future shells.
    await ensureLocalBinOnPath(ui, uvToolBin);

    // 6. Wire the wrapper (stable copy if we can find a marv-mlx.zsh source).
    const wired = await wireMarvMlx(ui);
    if (!wired) return;

    const depsOk = !!(await onPath("gum")) && !!(await onPath("uv")) && !!(await onPath("mlx_vlm.server"));
    ui.notify(
      depsOk
        ? "marv-mlx-setup: deps + wrapper ready — pick a local model via /model"
        : `marv-mlx-setup: deps installed — open a new terminal so ${uvToolBin} is on PATH, then /model`,
      "info"
    );
  } finally {
    ui.setStatus(key, "");
    setupRunning = false;
  }
}

/** Copy marv-mlx.zsh + lib into the stable dir and (re)generate the wrapper. */
async function wireMarvMlx(ui: SetupUI): Promise<boolean> {
  const zsh = await findMarvMlxZsh();
  if (zsh) {
    try {
      await mkdir(join(MARV_MLX_STABLE, "lib"), { recursive: true });
      await copyFile(zsh, join(MARV_MLX_STABLE, "marv-mlx.zsh"));
      await copyFile(
        join(dirname(zsh), "lib", "marv-mlx-helpers.zsh"),
        join(MARV_MLX_STABLE, "lib", "marv-mlx-helpers.zsh")
      );
      // The chat REPL runs as its own Python file (not a zsh heredoc).
      await copyFile(
        join(dirname(zsh), "lib", "marv_mlx_repl.py"),
        join(MARV_MLX_STABLE, "lib", "marv_mlx_repl.py")
      );
      // APC sitecustomize payload (installed into the mlx-vlm tool env by
      // installApcSitecustomize below).
      await copyFile(
        join(dirname(zsh), "lib", "marv-mlx-apc-sitecustomize.py"),
        join(MARV_MLX_STABLE, "lib", "marv-mlx-apc-sitecustomize.py")
      ).catch(() => {});
      // Bundled curated catalog (the Download menu / `marv-mlx curated`).
      await copyFile(
        join(dirname(zsh), "curated-llms.md"),
        join(MARV_MLX_STABLE, "curated-llms.md")
      ).catch(() => {});
      // Version lives next to marv-mlx.zsh (self-update notice reads it); best-effort.
      await copyFile(
        join(dirname(zsh), "VERSION"),
        join(MARV_MLX_STABLE, "VERSION")
      ).catch(() => {});
    } catch (err) {
      ui.notify(`marv-mlx-setup: failed copying marv-mlx.zsh → ${MARV_MLX_STABLE} — ${errMsg(err)}`, "error");
      return false;
    }
  } else if (!(await pathOk(WRAPPER))) {
    // No marv-mlx.zsh anywhere and no existing wrapper (e.g. install.sh never ran).
    ui.notify(
      "marv-mlx-setup: can't find marv-mlx.zsh. Clone it and set MARV_MLX_REPO (or run its install.sh), or set MARV_MLX_ZSH=/path/to/marv-mlx.zsh, then /reload and re-run /marv-mlx-setup.",
      "error"
    );
    return false;
  } else {
    // Existing wrapper (install.sh generated it, pointing at the user's clone).
    return true;
  }

  const target = join(MARV_MLX_STABLE, "marv-mlx.zsh");
  const script = [
    "#!/usr/bin/env bash",
    "# Generated by marv-mlx-sync (/marv-mlx-setup) — points at the stable copy of marv-mlx.zsh.",
    "set -euo pipefail",
    `MARV_MLX_ZSH="${target}" exec zsh "${target}" "$@"`,
    "",
  ].join("\n");
  try {
    await mkdir(dirname(WRAPPER), { recursive: true });
    await writeFile(WRAPPER, script, { mode: 0o755 });
  } catch (err) {
    ui.notify(`marv-mlx-setup: failed writing ${WRAPPER} — ${errMsg(err)}`, "error");
    return false;
  }
  ui.setStatus("marv-mlx-setup", `✓ wrote ${WRAPPER}`);
  return true;
}

/* ------------------------------------------------------------------ */
/* Model discovery + provider registration                            */
/* ------------------------------------------------------------------ */

/** File names under `dir`, recursing a couple of levels (GGUF quant subdirs). */
async function listWeightFiles(dir: string, depth = 0): Promise<string[]> {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return [];
  }
  const names: string[] = [];
  for (const entry of entries) {
    if (entry.isDirectory()) {
      if (depth < 2) names.push(...(await listWeightFiles(join(dir, entry.name), depth + 1)));
    } else {
      names.push(entry.name);
    }
  }
  return names;
}

/**
 * Whether mlx-vlm can serve this model at all — mirrored from
 * `_marv_mlx_model_unsupported_reason` in marv-mlx's zsh helpers. mlx-vlm loads
 * `*.safetensors` (MLX-quantized or plain bf16/fp16 HF), so these cannot be
 * served: GGUF, weightless/PyTorch-.bin/ONNX/CoreML repos, and weights packed
 * for another runtime (bitsandbytes/gptq/awq/compressed-tensors). fp8 is fine.
 */
async function isServableModel(id: string, dir: string): Promise<boolean> {
  if (/gguf/i.test(id)) return false;
  const snapshots = join(dir, "snapshots");
  let revs;
  try {
    revs = await readdir(snapshots, { withFileTypes: true });
  } catch {
    return true; // no snapshot yet: nothing contradicts it being MLX
  }
  let sawSnapshot = false;
  for (const rev of revs) {
    if (!rev.isDirectory()) continue;
    sawSnapshot = true;
    const snap = join(snapshots, rev.name);
    const names = await listWeightFiles(snap);
    if (names.some((n) => /\.gguf$/i.test(n))) continue;
    const hasSafetensors = names.some(
      (n) => /\.safetensors$/i.test(n) && !/consolidated\.safetensors$/i.test(n),
    );
    if (!hasSafetensors) continue;
    let quantMethod = "";
    try {
      const cfg = JSON.parse(await readFile(join(snap, "config.json"), "utf8"));
      quantMethod = String(cfg?.quantization_config?.quant_method ?? "").toLowerCase();
    } catch {
      // No/invalid config.json: leave the verdict to the server.
    }
    if (quantMethod && quantMethod !== "fp8") continue;
    return true;
  }
  return !sawSnapshot;
}

/**
 * Discover local MLX models from the HF hub cache. `models--ORG--NAME`
 * directories become `ORG/NAME` model ids, exactly like marv-mlx's enumerator.
 */
async function discoverModels(): Promise<LocalModel[]> {
  let entries;
  try {
    entries = await readdir(HUB_DIR, { withFileTypes: true });
  } catch {
    return [];
  }

  const models: LocalModel[] = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || !entry.name.startsWith("models--")) continue;
    const id = entry.name.slice("models--".length).replace(/--/g, "/");
    if (!(await isServableModel(id, join(HUB_DIR, entry.name)))) continue;
    models.push({
      id,
      name: id, // id is the exact string `marv-mlx run <id>` expects
      reasoning: true,
      input: ["text"],
      contextWindow: 131072,
      maxTokens: 8192,
      cost: ZERO_COST,
      thinkingLevelMap: { off: "off", low: "on", high: "on" },
      // Per-model compat (pi reads model.compat at request time): keep the
      // system prompt as "system" (mlx_vlm.server is OpenAI-shaped), never send
      // reasoning_effort, and route the thinking toggle through
      // chat_template_kwargs.enable_thinking — the field mlx_vlm.server reads.
      compat: {
        supportsDeveloperRole: false,
        supportsReasoningEffort: false,
        thinkingFormat: "qwen-chat-template",
      },
    });
  }
  return models;
}

/** Re-scan the hub cache and re-register the marv-mlx provider with the models found. */
async function refresh(pi: ExtensionAPI): Promise<LocalModel[]> {
  const models = await discoverModels();
  pi.registerProvider(MARV_MLX_PROVIDER, {
    name: "Local MLX (marv-mlx)",
    baseUrl: "http://localhost:11500/v1",
    api: "openai-completions",
    apiKey: "local",
    models,
  });
  return models;
}

/* ------------------------------------------------------------------ */
/* Extension entry point                                              */
/* ------------------------------------------------------------------ */

export default async function (pi: ExtensionAPI) {
  // Refresh the available-model list on every pi start and /reload.
  await refresh(pi);

  // Serialize switches so rapid consecutive selections don't stomp each other.
  let chain: Promise<void> = Promise.resolve();

  pi.on("model_select", async (event, ctx) => {
    const { model, source } = event;
    if (model.provider !== MARV_MLX_PROVIDER) return;

    // Session restore just rings the model up; don't force a switch on clean restores.
    if (source === "restore") return;

    const modelId = model.id;
    const ui = ctx.ui;
    const statusKey = "marv-mlx";

    if (!(await pathOk(WRAPPER))) {
      ui.notify(`marv-mlx: wrapper ${WRAPPER} missing — run /marv-mlx-setup first`, "error");
      return;
    }

    const sync = async (): Promise<void> => {
      ui.setStatus(statusKey, `⟳ loading ${modelId}…`);
      try {
        await execFileP(WRAPPER, ["run", modelId], { timeout: LOAD_TIMEOUT_MS });
        ui.notify(`marv-mlx: ${modelId} ready on :11500`, "info");
      } catch (err) {
        ui.notify(
          `marv-mlx: failed to start ${modelId} — ${errMsg(err)}`,
          "error"
        );
      } finally {
        ui.setStatus(statusKey, "");
      }
    };

    chain = chain.then(sync, sync);
    await chain; // surface errors so pi doesn't treat the handler as crashed
  });

  // Manual re-sync: re-scan the hub cache and re-register the provider.
  pi.registerCommand("marv-mlx-sync", {
    description: "Re-scan the HF hub cache and register available local MLX models",
    handler: async (_args, ctx) => {
      const models = await refresh(pi);
      const ids = models.map((m) => m.id).join(", ") || "(none)";
      ctx.ui.notify(`marv-mlx-sync: registered ${models.length} model(s): ${ids}`, "info");
    },
  });

  // One-shot install/repair of marv-mlx + deps and the pi→marv-mlx wiring.
  pi.registerCommand("marv-mlx-setup", {
    description:
      "Install/repair marv-mlx + deps (uv, gum, mlx-vlm — no brew or CLT needed) and wire pi → marv-mlx",
    handler: async (_args, ctx) => {
      await runSetup(ctx.ui);
    },
  });

  // Offer setup once per process when marv-mlx isn't wired in yet.
  let offered = false;
  pi.on("session_start", async (_event, ctx) => {
    if (offered || !ctx.hasUI) return;
    offered = true;
    if ((await pathOk(WRAPPER)) || (await onPath("marv-mlx"))) return;
    const yes = await ctx.ui.confirm(
      "marv-mlx",
      "marv-mlx isn't wired into pi yet. Run setup now (uv + gum + mlx-vlm, no brew needed; writes ~/.pi/agent/bin/marv-mlx wrapper)?"
    );
    if (yes) await runSetup(ctx.ui);
  });
}