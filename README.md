# HIT 校园网 PPPoE + Clash 修复脚本

这个仓库用于解决 HIT 校园网 PPPoE 拨号上网后，Clash Verge/mihomo、Codex 或 OpenAI 连接不稳定、无法正常走代理的问题。

脚本面向 Windows 环境，默认保持 WLAN 和 Clash 不关闭，通过临时 NRPT 规则和 Clash Meta 网卡 split route，让关键域名在 PPPoE 环境下仍能进入 Clash。退出时可一键恢复 WLAN + Clash。

## 适用环境

- Windows
- HITnet PPPoE 拨号
- Clash Verge / mihomo 正在运行
- Clash TUN/Meta 网卡存在
- 本机代理端口为 `127.0.0.1:7897`

## 文件说明

- `enter_pppoe_codex.ps1`：进入有线 PPPoE + Clash 可用环境。
- `restore_wlan_clash.ps1`：删除临时规则并恢复 WLAN + Clash。
- `diagnostics/pppoe_clash_test_and_restore.ps1`：诊断和受控测试脚本。

## 使用方法

先确认 Clash Verge 正常运行，且不要关闭 WLAN。

```powershell
cd .\hit-campus-pppoe-clash-fix
.\enter_pppoe_codex.ps1
```

脚本会依次提示输入：

- `HIT 校园网账号`
- `HIT 校园网密码`

密码只在内存中用于拨号，不写入脚本、日志或状态文件。

成功标志：

- 终端出现 `ENTER_PPPOE_CODEX_OK`
- `HITnet` 已连接
- OpenAI direct 与 Clash proxy 都返回 `401`

## 恢复 WLAN + Clash

退出有线环境时执行：

```powershell
cd .\hit-campus-pppoe-clash-fix
.\restore_wlan_clash.ps1
```

如果 Codex 在有线环境中断连，也可以直接在本机 PowerShell 执行同一条恢复命令。

恢复脚本会删除临时 NRPT、删除临时 split route、断开 `HITnet`，并验证 Clash 显式代理。

## 常用检查

检查 PPPoE：

```powershell
rasdial
```

检查 Clash 代理：

```powershell
curl.exe --max-time 10 -I -L --proxy http://127.0.0.1:7897 https://api.openai.com/v1/models
```

检查 direct 是否被 Clash TUN 接管：

```powershell
Resolve-DnsName api.openai.com -Type A -DnsOnly
curl.exe --max-time 15 -I -L --noproxy "*" https://api.openai.com/v1/models
```

期望 DNS 返回 `198.18.x.x`，OpenAI 返回 `401`。

## 故障处理

- RAS `629`：PPPoE 认证/注册阶段被校园侧终止，通常不是 Clash 问题。等待 1-2 分钟后重试，若持续出现，请检查账号权限、在线会话限制、墙口/交换机端口、VLAN 或 PPPoE 服务状态。
- Clash 探测失败：先确认 Clash Verge/mihomo 正在运行，且 `127.0.0.1:7897` 正在监听。
- 无法恢复：手动执行 `restore_wlan_clash.ps1`。脚本只清理本项目创建的临时 NRPT 和 split route。

## 安全说明

- 不保存校园网账号密码。
- 不关闭 WLAN。
- 不修改 Clash 配置。
- 不修改 DNS、MTU 或系统代理的永久配置。
- 不上传日志、运行状态或 Clash 配置备份。

## License

MIT
