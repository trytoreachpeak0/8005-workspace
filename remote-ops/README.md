# 远程运维通道

进厂区机器的两条通道。动任何一台机器之前，先读它所在子目录的文档。

| 目录 | 目标机 | 协议 | 目标机 PowerShell | 先读 |
| --- | --- | --- | --- | --- |
| `onboard-hmi/` | AGV 车载上位机 | SSH（`ssh agv01`） | pwsh 7.6.5 | `onboard-hmi/docs/USAGE.md` |
| `factory-server/` | 厂区离线服务器 `WIN-0HD72AV4K31`（SQL Server + MES ingest） | WinRM，TCP 5985 | Windows PowerShell 5.1 | `factory-server/windows-server-2016-codex-winrm.md` |

## 两条通道共同的约束

- **能连上机器不等于能改代码。** 通过这里够到一台机器，不会获得那台机器上运行的
  代码所属仓库的写权限。写权限只看根 `CLAUDE.md`。
- **凭据不进仓库。** 上位机的运维私钥在 `~/.ssh/`，服务器的 DPAPI 凭据在控制机的
  `%LOCALAPPDATA%\CodexSecrets\`。两者都不在这里，也不要复制进来。
- **探测输出不进 git。** `probe-*.txt` 已 gitignore，内容是本机账户、管理员组、
  自动登录配置、防火墙状态和 IP 拓扑。

## 脚本语言

本工作区的脚本一律 PowerShell 7，见根 `CLAUDE.md` 的 Scripting baseline。
`factory-server/` 是唯一例外：那台 Windows Server 2016 只有 Windows PowerShell
5.1，也没有联网安装 pwsh 的途径，跑在它上面的脚本保持 `#Requires -Version 5.1`。
