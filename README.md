# HIT 校园网 PPPoE + Clash 代理修复工具

这个仓库用于解决 HIT 校园网 PPPoE 拨号连接后，Clash Verge/mihomo 代理无法正常使用的问题。

主流程是：电脑开机后插好有线网，打开工具，一键启动/等待 Clash，并完成 PPPoE 拨号与代理修复。WLAN 只是回退路径，不是进入有线环境的前提。进入活动状态后，可启用每 15 分钟一次的断线恢复：连续确认意外掉线后重拨、启动已停止的 RayLink，并协调本项目 NRPT 和 split routes。健康连接保持在线。

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

登录后自动连接与断线恢复：

1. 在 UI 中勾选“记住账号”和“记住密码”。
2. 勾选“登录自连 + 15分钟网络检查”。
3. UI 统一管理两个当前用户、最高权限的计划任务：原有登录自动连接，以及每 15 分钟运行一次的恢复任务。保留原有 `HitCampusPppoeClashHealthCheck` 任务名，动作更新为 `guard_pppoe_clash.ps1`。
4. 项目活动状态存在且有线链路在线时，连续两个 15 分钟周期均观察到意外 PPPoE 掉线才允许重拨；同一活动会话的两次观察间隔须在 12–20 分钟内（含边界），超过 20 分钟则重新确认。首次重拨通常等待 15–30 分钟。拨号失败和本守护的服务启动重试均冷却 15 分钟，每轮只尝试一次，任务最长运行 3 分钟；不在轮次之间短暂复查。
5. “切回 WLAN”先保存暂停意图，确认本地清理成功后才清除活动状态；清理失败保留状态以便重试。RAS 631（用户断开）或 830（注销）也持久暂停重拨，事件超过三天后仍保持暂停。再次点击“修复 PPPoE + Clash”成功后恢复守护，已连接的快速路径同样生效。直接关闭 TUN 或系统代理不会触发强制重启 Clash。
6. RayLink 已安装、未禁用且服务停止时，恢复任务只启动该服务，不重启正在运行的服务。安装器可另行配置 Windows 服务失败恢复。

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
- `auto_connect_pppoe_clash.ps1`：登录自动连接与低频健康检查入口。
- `guard_pppoe_clash.ps1`：每 15 分钟网络检查入口；`-ObserveOnly` 只读查看恢复条件。
- `HitNetClashGuard.ps1`：恢复决策、共享 RAS 调用、服务检查和计划任务注册。
- `HitNetClashResources.ps1`：路由与 NRPT 归属记录、精确清理和结果验证。
- `Watch-HitNetOperation.ps1`：连接超时后，仅依据本次操作日志清理新增资源，保留 RAS 连接。
- `Install-HitNetClashGuard.ps1`：升级现有周期任务，并配置 RayLink 服务失败后延迟重启；不拨号或重启当前服务。
- `Test-HitNetClashGuard.ps1`：使用模拟网络和服务验证恢复及不干扰健康连接的行为。
- `Test-HitNetClashStability.ps1`：不依赖校园网的归属、回滚、凭据、暂停及配置损坏模拟测试。
- `restore_wlan_clash.ps1`：恢复 WLAN + Clash。
- `diagnostics/pppoe_clash_test_and_restore.ps1`：诊断和受控测试脚本。

## 本地凭据与运行文件

- 默认不保存账号和密码。
- “记住账号”会保存到 `.local/settings.json`。
- “记住密码”使用 Windows DPAPI 加密，只能由当前 Windows 用户解密。
- “登录自连 + 15分钟网络检查”使用两个 Windows 计划任务触发。手动连接、仅拨号、登录自连和守护重拨统一使用 Windows RAS API，不把密码放入子进程命令行。守护仅在确认需要重拨时解密保存的凭据。
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

只协调活动环境中的项目 NRPT/split routes（不拨号、不启停进程）：

```powershell
.\enter_pppoe_codex.ps1 -ReconcileOnly -ProbeMode Minimal
.\auto_connect_pppoe_clash.ps1 -HealthCheckOnly
```

健康入口的终态日志为 `HEALTH_CHECK_ALREADY_OK`、`HEALTH_CHECK_REPAIRED`、`HEALTH_CHECK_SKIPPED_*`、`HEALTH_CHECK_BLOCKED` 或 `HEALTH_CHECK_FAILED`。状态文件使用同目录临时文件原子替换；修复失败时只撤销本次新增的 NRPT/route，不运行完整恢复脚本。

旧 `-HealthCheckOnly` 保持“不拨号、不启停进程”的兼容行为。无人值守恢复使用新入口：

```powershell
# 不改变网络、服务或守护状态文件
.\guard_pppoe_clash.ps1 -ObserveOnly
# 同一 Windows 用户的管理员 PowerShell 中升级任务，无需断开网络
.\Install-HitNetClashGuard.ps1
```

守护结果写入 `.runtime/state/connection_guard.json` 和每日 `connection_guard_YYYYMMDD.log`。`GUARD_LOCAL_OK` / `GUARD_RECOVERED` 表示本地就绪；意外掉线确认、退避、恢复失败或服务异常返回退出码 2，避免调度器把“未恢复”显示为成功。`GUARD_INACTIVE`、`GUARD_MANUAL_DISCONNECT` 属于主动暂停，返回 0。

每个本地 PPPoE、代理和 TUN 就绪的 15 分钟检查轮次，统一做一组两次最多 8 秒的 OpenAI HTTP HEAD 探测；本轮刚重拨恢复也只探测一组，不另设探测计时器。记录不显式指定代理和指定 Clash 代理的响应码。401 表示可到达 HTTP 服务，不代表已登录；不指定代理仍可能经过 TUN。探测失败只报告 `GUARD_HTTP_WARNING`，不触发断开、回滚或进程重启。它也不能代替异地 RayLink 控制端的实际连接验证。

安装器把原任务 XML 和 RayLink 原失败策略保存到 `.runtime/backups/guard-install-*`。RayLink 的 Windows 失败恢复等待时间为 60、120、300 秒，24 小时重置失败计数；配置过程不会重启正在运行的服务。停止周期恢复可取消 UI 勾选或禁用 `HitCampusPppoeClashHealthCheck`；服务失败恢复是独立的事件触发设置，不属于每 15 分钟周期检测，在 Windows 服务属性中管理。周期任务首次运行安排在注册后 15 分钟，登录自连和手动修复仍按原有入口立即执行。

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

RayLink 连续超时时先检查 `.runtime/state/connection_guard.json`：

1. 在本机点击“修复 PPPoE + Clash”，或运行 `enter_pppoe_codex.ps1 -ProbeMode Balanced`。
2. 确认日志出现 `LOCAL_ENTER_REPAIR_OK`，并确认 Meta、代理和四条 split routes 正常。
3. 等待最多 30 秒，让 RayLink 按自身现有重试周期自动恢复。
4. 若仍未恢复：代理/TUN 异常时，在本机手动重启 Clash 后再运行一次完整修复；网络完全正常但 RayLink 仍超时时，在本机手动重启 RayLink 一次。
5. 新守护会处理意外 PPPoE 掉线和已停止的 RayLink，但不因 HTTP 超时重拨健康 PPPoE，也不重启仍在运行的 Clash/RayLink。缺失代理/TUN 会报告异常；服务仍在运行但内部卡死的情况尚不能可靠识别和自动恢复。

- Clash 未启动：工具会按配置路径尝试启动 Clash Verge；若失败，请在 UI 中选择正确的 `clash-verge.exe`。
- TUN 网卡未就绪：请先在 Clash Verge 中开启 TUN/Meta；本工具不会修改 Clash 配置。
- TUN 已提前创建 split route：工具会复用现有路由，不会因此判定连接失败。
- 已处于 PPPoE + Clash 修复状态：工具会走快速路径，不断开、不重拨。
- 仅拨号模式仍经过 Clash：说明 Clash TUN 或系统代理已经在本机启用；该模式不会替你关闭或修改 Clash，请在 Clash 中手动关闭 TUN/系统代理后再试。
- RAS `623`：通常是电话簿连接项未找到（或读取不到 `rasphone.pbk`）。确认 `Settings` 中 `RasEntry` 与 Windows 电话簿中的 PPPoE 名称完全一致；若不一致，用 `rasphone.exe -a` 重新创建同名条目。系统会在预检阶段提示可见连接项与修复动作，未匹配时直接返回 `RAS_ENTRY_NOT_FOUND`。
- RAS `629`：通常是校园侧终止 PPPoE 认证/注册。等待 1-2 分钟后重试，若持续出现，请检查账号权限、在线会话限制、墙口/交换机端口、VLAN 或 PPPoE 服务状态。
- RAS `828`：[Microsoft 定义为连接空闲超时](https://learn.microsoft.com/en-us/windows/win32/rras/routing-and-remote-access-error-codes)。记录断开事件、电话簿当时的空闲策略及校园侧会话记录后再判断来源；不能仅凭这个码归因于 Clash 或网线。守护会记录最近的 RAS 原因码、时间和事件记录号，并对非主动断线进行有界重连。
- Office 登录失败（例如 Microsoft Store / Word 等）：本项目不改 Office 登录策略。若在开启系统代理时登录受阻，可先关闭系统代理测试；如果可恢复，说明是代理策略对该应用的影响，后续可采用按需重试或临时关闭系统代理。
- 无法恢复：运行 `restore_wlan_clash.ps1`。脚本只清理有明确归属且内容仍匹配的 NRPT 和 ActiveStore split route。复用和旧版来源不明的路由保留并报告；本地清理未完成时返回失败，不显示“已切换回 WLAN”。

## 安全说明

- 所有拨号入口共用原生 RAS API，不把密码写入子进程命令行参数。
- 不关闭 WLAN。
- 不修改 Clash 配置。
- 不自动开启 Clash TUN。
- 旧 `-HealthCheckOnly` 不拨号；新守护只重连已断开的 PPPoE、启动已停止的 RayLink，不主动断开健康 PPPoE、不重启 Clash/TUN，不运行完整回滚流程。
- 日志不写入凭据、订阅地址、代理节点或完整外部 IP。
- 不在 Windows 用户登录前解密或使用密码。
- 默认恢复验证使用模拟故障，不在承载远程控制和 Codex 的真实网卡、PPPoE、Clash/TUN 上注入断网故障。
- 不修改 DNS、MTU 或系统代理的永久配置。
- 不上传日志、运行状态、Clash 配置备份、`.runtime/` 或 `.local/` 本地凭据。

## 项目维护

### 稳定性版本 v0.2.0

- 新建 split route 显式使用 `ActiveStore`；活动状态版本为 `SchemaVersion=2`，记录 `Created`、`Reused` 或 `Unknown` 归属及存储位置。
- 旧版本没有记录路由来源，而且可能写入了 `PersistentStore`。升级不会自动认领或删除这些路由；旧记录按 `Unknown` 保留，核实前不要清空路由表。
- 普通连接不再预先删除已有路由或规则。失败时只撤销本次新增项，只释放本次拨号取得的 RAS 句柄；已有 PPPoE 保持连接。成功提交活动状态后，不因日志或旧路由清理失败而撤销已验证的工作路由。
- 活动状态与设置均采用原子 JSON 写入。已有 JSON 损坏时明确报错，不静默替换为默认配置。命令行参数与原有 DPAPI 凭据格式保持兼容。
- 成功的手动连接更新活动会话时间；定期路由协调保留原时间，不重置用户暂停意图。仅拨号模式不启用 Clash 守护。
- 超时看门狗只处理本次操作日志记录的新增路由和规则。操作仍持锁或已有同次/更新的成功状态时不修改网络；进程异常退出后也不按连接名称强制断开 PPPoE。
- GitHub Actions 使用 Windows PowerShell 5.1，运行解析与模拟测试，不需要真实账号、Clash 或校园网。完整本机自检仍使用下方原入口。

- `HitNetClashRuntime.ps1`：共享运行时 helper，集中日志、RAS、端口、TUN、NRPT、split route、OpenAI probe 和 mutex 工具函数。
- `Test-HitNetClashProject.ps1`：发布前自检入口，覆盖 PowerShell parser、CLI/UI 兼容性、模拟协调计划、原子状态替换、auto-connect ValidateOnly、`config.example.json`、`git diff --check` 和敏感信息扫描。
- 默认自检不执行会切换网络状态的 restore 或 enter 冷启动流程；需要验证 enter 单实例锁时可加 `-IncludeBusyLockCheck`。

```powershell
.\Test-HitNetClashProject.ps1
.\Test-HitNetClashProject.ps1 -IncludeBusyLockCheck
```

## License

MIT
