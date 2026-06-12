# HIT 校园网 PPPoE + Clash 代理修复工具

这个仓库用于解决 HIT 校园网 PPPoE 拨号连接后，Clash Verge/mihomo 代理无法正常使用的问题。

主流程是：电脑开机后插好有线网，打开工具，一键启动/等待 Clash，并完成 PPPoE 拨号与代理修复。WLAN 只是回退路径，不是进入有线环境的前提。

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
4. 点击“一键修复并连接有线 PPPoE”。

切换回 WLAN：

1. 再次双击 `Start-HitNetClashFix.cmd`。
2. 点击“一键切换回 WLAN”。

登录后自动连接：

1. 在 UI 中勾选“记住账号”和“记住密码”。
2. 勾选“登录后自动连接”。
3. 之后当前 Windows 用户登录后，工具会自动启动/等待 Clash，并连接有线 PPPoE + Clash。

下方输出框会显示状态、预检结果、拨号过程和恢复过程。默认成功后窗口保持打开；需要自动退出时可勾选“成功后自动关闭”。

## 可迁移配置

公开默认配置在 `config.example.json` 中，适合其他用户按需修改参考：

- `RasEntry`：PPPoE 拨号名称，默认 `HITnet`
- `ProxyUrl`：Clash 本机代理地址，默认 `http://127.0.0.1:7897`
- `TunInterfaceAlias`：Clash TUN 网卡名，默认 `Meta`
- `ClashExecutableCandidates`：Clash Verge 启动程序候选路径
- `NrptNamespaces`：需要定向到 Clash DNS 的域名后缀

本机实际设置保存在 `.local/settings.json`，不会上传 GitHub。UI 中可直接修改 PPPoE 名称、代理地址、TUN 网卡名和 Clash 路径。

## 文件说明

- `Start-HitNetClashFix.cmd`：双击启动 UI。
- `Start-HitNetClashFix.ps1`：可视化界面。
- `HitNetClashConfig.ps1`：共享配置读取与自动探测逻辑。
- `config.example.json`：公开模板配置。
- `enter_pppoe_codex.ps1`：一键修复并连接有线 PPPoE + Clash。
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

## License

MIT
