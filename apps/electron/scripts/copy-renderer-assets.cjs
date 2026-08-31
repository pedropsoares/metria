const { cpSync, mkdirSync, copyFileSync, existsSync } = require("node:fs");
const { join } = require("node:path");
const source = join(__dirname, "..", "src", "renderer");
const destination = join(__dirname, "..", "dist", "renderer");
mkdirSync(destination, { recursive: true });
cpSync(source, destination, { recursive: true, filter: (path) => !path.endsWith(".ts") });

const assets = join(__dirname, "..", "..", "..", "Assets");
for (const name of ["claude-logo.png", "codex-logo.png", "opencode-logo.png", "metria-logo.png", "metria-mascot.png"]) {
  const sourceFile = join(assets, name);
  if (existsSync(sourceFile)) copyFileSync(sourceFile, join(destination, name));
}
