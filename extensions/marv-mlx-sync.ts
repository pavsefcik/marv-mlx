/**
 * marv-mlx-sync — keeps pi's list of local MLX models in sync with what's actually
 * downloaded in the Hugging Face hub cache, and starts/switches marv-mlx to the
 * selected local model on :11500.
 *
 * Distributed as part of the marv-mlx repo (a pi package):
 *
 *   pi install git:github.com/pavsefcik/marv-mlx
 *
 * or copied into ~/.pi/agent/extensions/marv-mlx-sync.ts — `sh install.sh` from a
 * clone does the copy and generates the ~/.pi/agent/bin/marv-mlx wrapper for you.
 * Hot-reload with /reload. The factory runs on every pi start and /reload.
 *
 * Commands:
 *   /marv-mlx-sync   re-scan the HF hub cache and re-register the "local" provider
 *   /marv-mlx-setup  install/repair marv-mlx + deps (uv, gum, mlx-vlm via brew) and wire
 *                pi → marv-mlx: copy marv-mlx.zsh to ~/.local/share/marv-mlx (a stable dir,
 *                because pi resets git-package checkouts on update) and write the
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

const execFileP = promisify(execFile);

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

async function ensureLocalBinOnPath(ui: SetupUI): Promise<void> {
  if (!(await pathOk(join(homedir(), ".local", "bin", "mlx_vlm.server")))) return;
  const zshrc = join(homedir(), ".zshrc");
  try {
    const cur = await readFile(zshrc, "utf8").catch(() => "");
    if (!cur.includes("local/bin")) {
      await writeFile(zshrc, `${cur}\nexport PATH="$HOME/.local/bin:$PATH"\n`);
      ui.notify("marv-mlx-setup: appended ~/.local/bin to ~/.zshrc", "info");
    }
  } catch {
    // best effort
  }
}

/**
 * /marv-mlx-setup — idempotent install/repair:
 *   1. Xcode CLT 2. brew 3. uv+gum 4. mlx-vlm+jinja2 (uv tool)
 *   5. PATH fix 6. stable marv-mlx.zsh copy + generated wrapper
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

    // 1. Xcode CLT — cannot be automated (GUI prompt); fail fast with instructions.
    try {
      await execFileP("xcode-select", ["-p"]);
    } catch {
      ui.notify(
        "marv-mlx-setup: install Xcode Command Line Tools first — run 'xcode-select --install'",
        "error"
      );
      return;
    }

    // 2. Homebrew (also needs manual install the first time).
    if (!(await onPath("brew"))) {
      ui.notify(
        "marv-mlx-setup: Homebrew missing — install it first:\n  /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"\nthen re-run /marv-mlx-setup",
        "error"
      );
      return;
    }

    // 3. uv + gum via brew (skipped when already present).
    for (const tool of ["uv", "gum"]) {
      if (await onPath(tool)) continue;
      ui.setStatus(key, `⟳ installing ${tool} (brew)…`);
      try {
        await execFileP("brew", ["install", tool], { timeout: 15 * 60 * 1000 });
      } catch (err) {
        ui.notify(`marv-mlx-setup: brew install ${tool} failed — ${errMsg(err)}`, "error");
        return;
      }
    }

    // 4. mlx-vlm as a uv tool. Always re-run so jinja2 is guaranteed (mlx-vlm's
    //    apply_chat_template needs it for every request and its own requirements
    //    don't declare it).
    ui.setStatus(key, "⟳ installing mlx-vlm (uv tool)…");
    try {
      await execFileP("uv", ["tool", "install", "mlx-vlm", "--with", "jinja2"], {
        timeout: 15 * 60 * 1000,
      });
    } catch (err) {
      ui.notify(`marv-mlx-setup: mlx-vlm install failed — ${errMsg(err)}`, "error");
      return;
    }

    // 5. ~/.local/bin on PATH for future shells.
    await ensureLocalBinOnPath(ui);

    // 6. Wire the wrapper (stable copy if we can find a marv-mlx.zsh source).
    const wired = await wireMarvMlx(ui);
    if (!wired) return;

    const depsOk = !!(await onPath("gum")) && !!(await onPath("uv")) && !!(await onPath("mlx_vlm.server"));
    ui.notify(
      depsOk
        ? "marv-mlx-setup: deps + wrapper ready — pick a local model via /model"
        : "marv-mlx-setup: deps installed — open a new terminal so ~/.local/bin is on PATH, then /model",
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
    description: "Install/repair marv-mlx + deps (uv, gum, mlx-vlm via brew) and wire pi → marv-mlx",
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
      "marv-mlx isn't wired into pi yet. Run setup now (brew: uv, gum; uv tool: mlx-vlm; writes ~/.pi/agent/bin/marv-mlx wrapper)?"
    );
    if (yes) await runSetup(ctx.ui);
  });
}