#!/usr/bin/env node
const { spawnSync } = require("child_process");
const path = require("path");

const app = path.join(__dirname, "..", "app", "TokenTank.app");
const result = spawnSync("open", [app], { stdio: "inherit" });
process.exit(result.status ?? 1);
