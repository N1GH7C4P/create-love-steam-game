#!/usr/bin/env node
import { fileURLToPath } from "url";
import path from "path";
import fs from "fs";
import { execSync } from "child_process";
import fse from "fs-extra";
import chalk from "chalk";
import inquirer from "inquirer";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TEMPLATES_DIR = path.join(__dirname, "templates");

// ── Helpers ───────────────────────────────────────────────────────────────────

function toSlug(name) {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

function toTag(name) {
  return name.toLowerCase().replace(/[^a-z0-9]/g, "");
}

function toPascal(name) {
  return name.replace(/(?:^|[\s\-_])(.)/g, (_, c) => c.toUpperCase());
}

function substituteVars(content, vars) {
  return content.replace(/\{\{([A-Z_]+)\}\}/g, (_, key) =>
    vars[key] !== undefined ? vars[key] : `{{${key}}}`
  );
}

const TEXT_EXTENSIONS = new Set([
  ".lua", ".sh", ".md", ".txt", ".json", ".env", ".example", ".gitignore",
]);

function isTextFile(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  const base = path.basename(filePath);
  return TEXT_EXTENSIONS.has(ext) || base.startsWith(".") || ext === "";
}

async function copyAndSubstitute(src, dest, vars) {
  const entries = await fse.readdir(src, { withFileTypes: true });
  for (const entry of entries) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      await fse.ensureDir(destPath);
      await copyAndSubstitute(srcPath, destPath, vars);
    } else {
      if (isTextFile(srcPath)) {
        const content = await fse.readFile(srcPath, "utf8");
        await fse.outputFile(destPath, substituteVars(content, vars));
      } else {
        await fse.copy(srcPath, destPath);
      }
      const relPath = path.relative(dest, destPath);
      process.stdout.write(chalk.green("  ✔ ") + relPath + "\n");
    }
  }
}

// ── Banner ────────────────────────────────────────────────────────────────────

function printBanner() {
  console.log();
  console.log(chalk.cyan("  ╔══════════════════════════════════════════════╗"));
  console.log(chalk.cyan("  ║") + chalk.bold("   create-love-steam-game") + chalk.dim("  v0.1.0          ") + chalk.cyan("║"));
  console.log(chalk.cyan("  ║") + chalk.dim("   Love2D + Steam multiplayer scaffold        ") + chalk.cyan("║"));
  console.log(chalk.cyan("  ╚══════════════════════════════════════════════╝"));
  console.log();
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  printBanner();

  const dirArg = process.argv[2];

  const answers = await inquirer.prompt([
    {
      type: "input",
      name: "gameName",
      message: "Game name:",
      default: dirArg ? toPascal(dirArg.replace(/[-_]/g, " ")) : "My Game",
      validate: (v) => v.trim().length > 0 || "Game name is required.",
    },
    {
      type: "input",
      name: "destDir",
      message: "Project directory:",
      default: (a) => dirArg || toSlug(a.gameName),
    },
    {
      type: "input",
      name: "steamAppId",
      message: "Steam App ID:",
      default: "0",
      validate: (v) => /^\d+$/.test(v.trim()) || "Must be a number.",
    },
    {
      type: "input",
      name: "depotMacos",
      message: "macOS Depot ID:",
      default: (a) => String(parseInt(a.steamAppId) + 2),
      validate: (v) => /^\d+$/.test(v.trim()) || "Must be a number.",
    },
    {
      type: "input",
      name: "depotWindows",
      message: "Windows Depot ID:",
      default: (a) => String(parseInt(a.steamAppId) + 3),
      validate: (v) => /^\d+$/.test(v.trim()) || "Must be a number.",
    },
    {
      type: "input",
      name: "depotLinux",
      message: "Linux Depot ID:",
      default: (a) => String(parseInt(a.steamAppId) + 4),
      validate: (v) => /^\d+$/.test(v.trim()) || "Must be a number.",
    },
    {
      type: "input",
      name: "port",
      message: "Default network port:",
      default: "9999",
      validate: (v) => /^\d+$/.test(v.trim()) || "Must be a number.",
    },
    {
      type: "list",
      name: "windowSize",
      message: "Window size:",
      choices: ["1280x800", "1920x1080", "1024x768", "1600x900"],
      default: "1280x800",
    },
  ]);

  const gameName = answers.gameName.trim();
  const destDir  = path.resolve(answers.destDir.trim());
  const [windowWidth, windowHeight] = answers.windowSize.split("x");

  const appId = answers.steamAppId.trim();

  const vars = {
    GAME_NAME:           gameName,
    GAME_SLUG:           toSlug(gameName),
    GAME_TAG:            toTag(gameName),
    GAME_IDENTITY:       toPascal(gameName),
    STEAM_APP_ID:        appId,
    STEAM_DEPOT_MACOS:   answers.depotMacos.trim(),
    STEAM_DEPOT_WINDOWS: answers.depotWindows.trim(),
    STEAM_DEPOT_LINUX:   answers.depotLinux.trim(),
    DEFAULT_PORT:        answers.port.trim(),
    WINDOW_WIDTH:        windowWidth,
    WINDOW_HEIGHT:       windowHeight,
    // 480 = Spacewar (Valve's dev test app). Used locally when no real App ID is set yet.
    STEAM_APPID_LOCAL:   appId === "0" ? "480" : appId,
  };

  if (fs.existsSync(destDir)) {
    const { overwrite } = await inquirer.prompt([{
      type: "confirm",
      name: "overwrite",
      message: `${chalk.yellow(answers.destDir.trim())} already exists. Overwrite?`,
      default: false,
    }]);
    if (!overwrite) { console.log(chalk.red("  Aborted.")); process.exit(1); }
  }

  console.log();
  console.log(chalk.bold(`  Scaffolding ${chalk.cyan(answers.destDir.trim())}/`));
  console.log();

  await fse.ensureDir(destDir);
  await copyAndSubstitute(TEMPLATES_DIR, destDir, vars);

  // chmod +x on shell scripts
  const scripts = ["scripts/build-native.sh", "scripts/deploy-steam.sh", "scripts/download-libs.sh"];
  for (const s of scripts) {
    const p = path.join(destDir, s);
    if (fs.existsSync(p)) fs.chmodSync(p, 0o755);
  }

  // Download luasteam native libraries automatically
  console.log();
  console.log(chalk.bold("  Downloading luasteam…"));
  try {
    execSync(`bash "${path.join(destDir, "scripts/download-libs.sh")}"`, { stdio: "inherit" });
  } catch {
    console.log(chalk.yellow("  ⚠ luasteam download failed — run scripts/download-libs.sh manually."));
  }

  // Check for unreplaced tokens (development guard)
  let unreplaced = 0;
  function checkTokens(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) { checkTokens(full); continue; }
      if (!isTextFile(full)) continue;
      const content = fs.readFileSync(full, "utf8");
      const matches = content.match(/\{\{[A-Z_]+\}\}/g);
      if (matches) {
        unreplaced += matches.length;
        console.warn(chalk.yellow(`  ⚠ Unreplaced tokens in ${path.relative(destDir, full)}: ${matches.join(", ")}`));
      }
    }
  }
  checkTokens(destDir);

  console.log();
  if (unreplaced > 0) {
    console.log(chalk.yellow(`  ⚠ ${unreplaced} unreplaced template token(s) above.`));
  } else {
    console.log(chalk.green("  ✔ All template variables substituted."));
  }
  console.log();
  console.log(chalk.bold("  Next steps:"));
  console.log();
  console.log(`    cd ${answers.destDir.trim()}`);
  console.log(`    # Add steam_api to lib/ (see lib/README.md — requires Steamworks SDK)`);
  console.log(`    love .`);
  console.log();
  console.log(chalk.dim("  To build and deploy to Steam:"));
  console.log(chalk.dim(`    scripts/build-native.sh`));
  console.log(chalk.dim(`    scripts/deploy-steam.sh --branch beta`));
  console.log();
}

main().catch((err) => {
  console.error(chalk.red("\n  Error: ") + err.message);
  process.exit(1);
});
