#!/usr/bin/env node
const { spawnSync } = require("child_process");
const path = require("path");

const app = path.join(__dirname, "..", "app", "TokenTank.app");
const running = () => spawnSync("pgrep", ["-x", "TokenTank"]).status === 0;

if (running()) {
  spawnSync("pkill", ["-x", "TokenTank"]);
  const deadline = Date.now() + 5000;
  while (running() && Date.now() < deadline) spawnSync("sleep", ["0.2"]);
  if (running()) {
    console.error("正在运行的 TokenTank 没有退出，请先手动退出再运行 tokentank");
    process.exit(1);
  }
}

const result = spawnSync("open", [app], { stdio: "inherit" });
process.exit(result.status ?? 1);
