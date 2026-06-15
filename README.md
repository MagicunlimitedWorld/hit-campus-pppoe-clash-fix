# HIT 校园网 PPPoE + Clash 代理修复工具

这个仓库用于解决 HIT 校园网 PPPoE 拨号连接后，Clash Verge/mihomo 代理无法正常使用的问题。

主流程是：电脑开机后插好有线网，打开工具，一键启动/等待 Clash，并完成 PPPoE 拨号与代理修复。WLAN 只是回退路径，不是进入有线环境的前提。

如果需要临时排查校园正版化/GP 激活，也可以使用“仅拨号有线 PPPoE”模式。该模式只执行 PPPoE 拨号，不启动 Clash、不修改 Clash、不添加 NRPT 或 split route。

## 适用环境

- Windows
- HITnet 或类似 PPPoE 校园网拨号
- Clash Verge / mihomo
- Clash TUN/Meta 网卡已在 Clash 中开启
- 默认本机代理为 `http://127.0.0.1:7897`

## 一键使用

双击运行：

```text
Start-HitNetClashFix.cmd
```

修复并连接有线 PPPoE：

1. 插好有线网，确认以太网适配器为已连接。
2. 输入校园网账号和密码。
3. 首次使用时检查 PPPoE 名称、代理地址、TUN 网卡名、Clash 路径。
4. 点击“修复 PPPoE + Clash”。

仅拨号有线 PPPoE：

1. 输入校园网账号和密码。
2. 点击“仅拨号有线 PPPoE”。
3. 工具只拨号，不处理 Clash。若 Clash TUN 已开启，系统流量仍可能经过 Clash，需要你在 Clash 中自行关闭 TUN 或系统代理。

切换回 WLAN：

1. 再次双击 `Start-HitNetClashFix.cmd`。
2. 点击“切回 WLAN”。

登录后自动连接：

1. 在 UI 中勾选“记住账号”和“记住密码”。
2. 勾选“登录后自动连接”。
3. 之后当前 Windows 用户登录后，工具会自动启动/等待 Clash，并连接有线 PPPoE + Clash。

下方输出框会显示状态、预检结果、拨号过程和恢复过程。默认成功后窗口保持打开；需要自动退出时可勾选“成功后自动关闭”。“刷新状态”和“复制脱敏诊断”都是只读操作，不会拨号、删路由或修改 Clash。

### 第一次使用检查清单

1. Clash Verge 已启动，且 TUN/Meta 已在 Clash 中开启。
2. UI 顶部显示 Clash 代理端口已监听；若未监听，先检查代理地址和端口。
3. PPPoE 名称与 Windows 宽带连接名称一致，HIT 常见为 `HITnet`。
4. TUN 网卡名与系统中的 Clash TUN 适配器一致，默认通常为 `Meta`。
5. Clash 路径存在；若自动识别失败，点击“浏览”选择 `clash-verge.exe`。
6. 遇到问题时先点“复制脱敏诊断”，再把摘要发给维护者；摘要不包含密码、日志全文或 Clash 节点。

## 可迁移配置

公开默认配置在 `config.example.json` 中，适合其他用户按需修改参考：

- `RasEntry`：PPPoE 拨号名称，默认 `HITnet`
- `ProxyUrl`：Clash 本机代理地址，默认 `http://127.0.0.1:7897`
- `TunInterfaceAlias`：Clash TUN 网卡名，默认 `Meta`
- `ClashExecutableCandidates`：Clash Verge 启动程序候选路径
- `NrptNamespaces`：需要定向到 Clash DNS 的域名后缀

本机实际设置保存在 `.local/settings.json`，不会上传 GitHub。UI 中可直接修改 PPPoE 名称、代理地址、TUN 网卡名和 Clash 路径。

其他 HIT 用户通常只需要核对这几项：

- PPPoE 名称：Windows 中宽带连接名称不是 `HITnet` 时修改。
- Clash 代理端口：Clash 本机端口不是 `7897` 时修改。
- TUN 网卡名：Clash TUN 不叫 `Meta` 时修改。
- Clash 路径：自动识别不到 Clash Verge 安装位置时手动选择。
- 有线网卡候选名：状态栏一直显示有线未就绪，但实际已插线时，在本地配置中补充 `EthernetNamePatterns`。

## 文件说明

- `Start-HitNetClashFix.cmd`：双击启动 UI。
- `Start-HitNetClashFix.ps1`：可视化界面。
- `HitNetClashConfig.ps1`：共享配置读取与自动探测逻辑。
- `config.example.json`：公开模板配置。
- `enter_pppoe_codex.ps1`：一键修复并连接有线 PPPoE + Clash。
- `connect_pppoe_only.ps1`：仅 PPPoE 拨号，不启动或修改 Clash。
- `auto_connect_pppoe_clash.ps1`：登录后自动连接入口。
- `restore_wlan_clash.ps1`：恢复 WLAN + Clash。
- `diagnostics/pppoe_clash_test_and_restore.ps1`：诊断和受控测试脚本。

## 本地凭据与运行文件

- 默认不保存账号和密码。
- “记住账号”会保存到 `.local/settings.json`。
- “记住密码”使用 Windows DPAPI 加密，只能由当前 Windows 用户解密。
- “登录后自动连接”使用 Windows 计划任务触发，不会把账号密码写入任务参数或日志。
- 日志、done marker、状态文件都放在 `.runtime/` 下。
- `.local/` 和 `.runtime/` 已加入 `.gitignore`，不会上传 GitHub。

## 高级命令行用法

修复并连接有线 PPPoE + Clash：

```powershell
.\enter_pppoe_codex.ps1
```

验证模式可选：

```powershell
.\enter_pppoe_codex.ps1 -ProbeMode Balanced
.\enter_pppoe_codex.ps1 -ProbeMode Minimal
.\enter_pppoe_codex.ps1 -ProbeMode Full
```

默认 `Balanced` 会保留关键本地检查和一次 OpenAI/Clash 探测；本地状态已就绪时，OpenAI 短时探测失败只记为警告，不会自动回滚。`Minimal` 不访问 OpenAI；`Full` 输出更完整诊断并保持更严格的探测判定。

日志中 `LOCAL_ENTER_REPAIR_*` 表示本地 PPPoE、Clash、TUN、NRPT 和 split route 修复状态；`EXTERNAL_CONNECTIVITY_PROBE_*` 表示 OpenAI 等外部连通性探测状态。两类结果分开看：本地修复成功但外部探测警告，通常是上游节点、校园网出口或目标服务短时波动。

仅拨号有线 PPPoE：

```powershell
.\connect_pppoe_only.ps1
```

恢复 WLAN + Clash：

```powershell
.\restore_wlan_clash.ps1
```

常用检查：

```powershell
rasdial
curl.exe --max-time 10 -I -L --proxy http://127.0.0.1:7897 https://api.openai.com/v1/models
Resolve-DnsName api.openai.com -Type A -DnsOnly
```

连接成功后，`api.openai.com` 通常会解析到 `198.18.x.x`，可用作 Clash 代理链路验证。

## 故障处理

- Clash 未启动：工具会按配置路径尝试启动 Clash Verge；若失败，请在 UI 中选择正确的 `clash-verge.exe`。
- TUN 网卡未就绪：请先在 Clash Verge 中开启 TUN/Meta；本工具不会修改 Clash 配置。
- TUN 已提前创建 split route：工具会复用现有路由，不会因此判定连接失败。
- 已处于 PPPoE + Clash 修复状态：工具会走快速路径，不断开、不重拨。
- 仅拨号模式仍经过 Clash：说明 Clash TUN 或系统代理已经在本机启用；该模式不会替你关闭或修改 Clash，请在 Clash 中手动关闭 TUN/系统代理后再试。
- RAS `629`：通常是校园侧终止 PPPoE 认证/注册。等待 1-2 分钟后重试，若持续出现，请检查账号权限、在线会话限制、墙口/交换机端口、VLAN 或 PPPoE 服务状态。
- 无法恢复：运行 `restore_wlan_clash.ps1`。脚本只清理本项目创建的临时 NRPT 和 split route。

## 安全说明

- 不把密码写入命令行参数。
- 不关闭 WLAN。
- 不修改 Clash 配置。
- 不自动开启 Clash TUN。
- 不在 Windows 用户登录前解密或使用密码。
- 不修改 DNS、MTU 或系统代理的永久配置。
- 不上传日志、运行状态、Clash 配置备份、`.runtime/` 或 `.local/` 本地凭据。

## 项目维护

- `HitNetClashRuntime.ps1`：共享运行时 helper，集中日志、RAS、端口、TUN、NRPT、split route、OpenAI probe 和 mutex 工具函数。
- `Test-HitNetClashProject.ps1`：发布前自检入口，默认执行 PowerShell parser、UI SelfTest、auto-connect ValidateOnly、`config.example.json` 解析、`git diff --check` 和敏感信息扫描。
- 默认自检不执行会切换网络状态的 restore 或 enter 冷启动流程；需要验证 enter 单实例锁时可加 `-IncludeBusyLockCheck`。

```powershell
.\Test-HitNetClashProject.ps1
.\Test-HitNetClashProject.ps1 -IncludeBusyLockCheck
```

## License

MIT
