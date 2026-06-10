# HIT 校园网 PPPoE + Clash 修复工具

这个仓库用于解决 HIT 校园网 PPPoE 拨号上网后，Clash Verge/mihomo、Codex 或 OpenAI 无法正常走代理的问题。

推荐使用一键可视化界面：连接有线网时输入账号密码，切回 WLAN 时点击一个按钮即可。

## 适用环境

- Windows
- HITnet PPPoE 拨号
- Clash Verge / mihomo 正在运行
- Clash TUN/Meta 网卡存在
- 本机代理端口为 `127.0.0.1:7897`

## 一键使用

双击运行：

```text
Start-HitNetClashFix.cmd
```

连接有线网：

1. 输入 HIT 校园网账号和密码。
2. 按需勾选“记住账号”“记住密码”。
3. 如需成功后自动退出，勾选“成功后自动关闭”。
4. 点击“连接有线网”。

切换回 WLAN：

1. 再次双击 `Start-HitNetClashFix.cmd`。
2. 如需成功后自动退出，勾选“成功后自动关闭”。
3. 点击“一键切换回 WLAN”。

下方输出框会显示刷新状态、连接和切换过程中的摘要与脚本输出。默认成功后窗口保持打开，便于确认状态。

## 文件说明

- `Start-HitNetClashFix.cmd`：双击启动 UI。
- `Start-HitNetClashFix.ps1`：可视化界面。
- `enter_pppoe_codex.ps1`：连接有线 PPPoE + Clash 的后端脚本。
- `restore_wlan_clash.ps1`：恢复 WLAN + Clash 的后端脚本。
- `diagnostics/pppoe_clash_test_and_restore.ps1`：诊断和受控测试脚本。

## 本地凭据

- 默认不保存账号和密码。
- “记住账号”会保存到 `.local/settings.json`。
- “记住密码”会使用 Windows DPAPI 加密，只能由当前 Windows 用户解密。
- `.local/` 已加入 `.gitignore`，不会上传到 GitHub。

## 运行文件归档

- 日志：`.runtime/logs/`
- done marker：`.runtime/markers/`
- active state：`.runtime/state/pppoe_codex_active_state.json`
- `.runtime/` 已加入 `.gitignore`，不会上传到 GitHub。

## 高级命令行用法

连接有线网：

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

连接成功后，`api.openai.com` 通常会解析到 `198.18.x.x`，OpenAI direct/proxy 均应返回 `401`。

## 故障处理

- RAS `629`：PPPoE 认证/注册阶段被校园侧终止，通常不是 Clash 问题。等待 1-2 分钟后重试，若持续出现，请检查账号权限、在线会话限制、墙口/交换机端口、VLAN 或 PPPoE 服务状态。
- Clash 探测失败：确认 Clash Verge/mihomo 正在运行，且 `127.0.0.1:7897` 正在监听。
- 无法恢复：运行 `restore_wlan_clash.ps1`。脚本只清理本项目创建的临时 NRPT 和 split route。

## 安全说明

- 不把密码写入命令行参数。
- 不关闭 WLAN。
- 不修改 Clash 配置。
- 不修改 DNS、MTU 或系统代理的永久配置。
- 不上传日志、运行状态、Clash 配置备份、`.runtime/` 或 `.local/` 本地凭据。

## License

MIT
