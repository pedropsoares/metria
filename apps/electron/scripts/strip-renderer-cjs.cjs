const { readFileSync, writeFileSync } = require("node:fs");
const { join } = require("node:path");

const directory = join(__dirname, "..", "dist", "renderer");
const preamble = 'Object.defineProperty(exports, "__esModule", { value: true });';

for (const name of require("node:fs").readdirSync(directory)) {
  if (!name.endsWith(".js")) continue;
  const path = join(directory, name);
  const source = readFileSync(path, "utf8");
  const lines = source.split("\n").filter((line) => line.trim() !== preamble && !line.trim().startsWith("exports."));
  writeFileSync(path, lines.join("\n"));
}
