# TokenTank

Mac 菜单栏小工具：点一下菜单栏上的加油枪图标，弹出面板查看 Claude / Codex / Grok 的会员额度，还能一键把这几个 CLI 升到最新版。

## 安装

```bash
npm i -g tokentank
tokentank
```

只支持 macOS 14 及以上，Apple 芯片和 Intel 都能用。左键点图标弹出/收起面板，右键退出。

## 功能

- **额度**：显示各家的已用百分比和重置时间，每 3 分钟自动刷新，打开面板时也会刷新一次。
  - Claude：读取 Claude Code 存在钥匙串里的登录信息，请求 Anthropic 的用量接口。第一次运行时 macOS 会询问是否允许读取，选「始终允许」即可。
  - Codex：通过 `codex app-server` 读取 5 小时和每周额度。
  - Grok：用 `~/.grok/auth.json` 里的登录态请求 Grok CLI 的计费接口；登录过期时会先运行一次 `grok models`，让 CLI 自己刷新登录。
- **一键升级**：检查当前版本和最新版本，有新版本时依次执行：
  - `claude update`
  - `npm install -g @openai/codex@latest`
  - `grok update`

没装的 CLI 会显示读取失败，不影响其他几项。

## 从源码构建

需要 Xcode 命令行工具和 Node.js。

```bash
./build.sh
open app/TokenTank.app
```
