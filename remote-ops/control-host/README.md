# control-host — 把所有通道装配成控制端的一份 SSH 配置

这里不是一条通道，是**跨全部通道的控制端装配层**。它只在控制端跑，不碰任何远程机器，
也不写私钥。

```bash
pwsh remote-ops/control-host/Build-SshConfig.ps1 -ValidateOnly
```

只校验、不写盘，有重名就非零退出。改完任何一个 `ssh_config.*` 片段后先跑这个。

```bash
pwsh remote-ops/control-host/Build-SshConfig.ps1
```

校验通过后写盘：每个族生成一份 `~/.ssh/conf.d/remote-ops-<族>.conf`，并在
`~/.ssh/config` 顶部装一个带标记的块，里面只有一行 `Include`。**标记块以外的内容原样保留**，
你自己手写的 `Host github.com` 之类不会被动。

## 为什么要有这一层

`~/.ssh/config` 只有一份，而 `remote-ops/` 下每条通道都有自己的 ssh 片段。在这之前
是靠手工把三段拼进那一个文件的，而 `onboard-hmi/scripts/05-setup-control-host.ps1`
会**整文件覆盖**它——在控制端跑一次，`factory01` 和 `vm01` 两段就没了。通道只有两条时
这是个隐患，通道多起来之后它是必然。

第二层作用：**片段就是名字注册表**。一个别名只要写进片段就算被占用，哪怕它背后的机器
还不存在。跨月份、跨通道写出来的配置能不撞名，靠的是这个，不是靠人记得住。

## 它强制的七条命名规则

| # | 规则 | 违反时 |
| --- | --- | --- |
| 1 | 片段路径是 `remote-ops/<通道>/config/ssh_config.<族>` | 扫不到，等于没登记 |
| 2 | `<族>` 是小写 kebab-case，且**跨全部通道唯一** | 报错退出 |
| 3 | 片段里每个 `Host` 模式都必须以自己的 `<族>` 开头 | 报错退出 |
| 4 | 具体别名是 `<族>` + 两位数字：`agv01`、`factory01`、`vm01` | 报错退出 |
| 5 | 别名跨全部片段唯一（规则 2–4 已经蕴含，仍单独查一遍，因为打错字能绕过约定） | 报错退出 |
| 6 | `ProxyJump` 的目标必须是某个片段定义过的别名 | 报错退出 |
| 7 | `HostName` 写成 `REPLACE_*` 表示**名字已占、机器未上线** | 报告并跳过该块 |

规则 2 是承重的那条：族名唯一，加上规则 3 的「不许越族」，别名唯一就是自动的结论而不是
需要有人去核对的事。

规则 7 的意思是：`agv02` 的块留在 git 里占着名，但不会进生成的配置，所以 `ssh agv02`
报的是「不认识这个主机」，而不是解析到一个假地址然后连上别的东西。

## 别名与密钥的对应

一个信任域一把密钥，密钥不通用、各自轮换。族与密钥不是一对一——`factory` 和 `vm` 是两个
族、两个信任域、两把钥匙，但同属 `factory-server` 一条通道。

| 族 | 通道 | 密钥（控制端 `~/.ssh/`） |
| --- | --- | --- |
| `agv` | `onboard-hmi/` | `agv_ops_ed25519` |
| `factory` | `factory-server/` | `agv_srv_ed25519` |
| `vm` | `factory-server/` | `agv_vm_ed25519` |

片段里的 `IdentityFile` 写的是写它那台机器上的绝对路径。装配时**逐行**改写到当前机器的
`~/.ssh/`——逐行是关键，三条通道三把钥匙，一次全局替换会把它们指到同一个文件上。

## 一次性迁移

控制端的 `~/.ssh/config` 如果还是老样子（三段直接内联在里面），装配器会拒绝写入并告诉你
原因：**ssh 取第一个匹配**，内联的那几段会盖过 `Include`，片段改了也不生效。带
`-ReplaceExisting` 再跑一次，它会先备份成 `config.backup-<时间戳>`，再把这些被接管的
`Host` 块（连同紧贴在上面的注释）删掉。标记块以外的其他内容不动。

## 一个实测结论：`Include` 不认 Windows 绝对路径

在 OpenSSH_10.5p1 for Windows 上实测：`Include` 能解析 `~/...` 和相对 `~/.ssh` 的路径，
但 `C:/Users/szy/.ssh/conf.d/*.conf` 和它的反斜杠写法都**静默地什么也不包含**——不报错，
就是没生效。所以生成的那行永远是 `Include ~/.ssh/conf.d/remote-ops-*.conf`。

连带后果：`-SshDir` 只能把生成的文件隔离到别处看，**不能**用
`ssh -F <那个目录>/config` 去验证——那份 config 里的 Include 指的仍是真的 `~/.ssh`。
要验证就直接 `-F` 指向 `conf.d/` 下的某个片段。

## 新增一个通道时

1. 建 `remote-ops/<通道>/config/ssh_config.<新族>`，族名别和 `agv`/`factory`/`vm` 撞。
2. 机器还没上线就先写 `HostName REPLACE_...` 占名。
3. `pwsh remote-ops/control-host/Build-SshConfig.ps1 -ValidateOnly`。
4. 过了再不带参数跑一次。
5. `ssh -G <别名>` 确认解析结果，再真的连。

编号脚本前缀（`01-`、`02-`……）**只在单个通道的 `scripts/` 内唯一**，跨通道可以重复，
现状就是这样（`onboard-hmi/scripts/01-probe.ps1` 与
`factory-server/scripts/01-control-host-route.ps1` 并存）。装配器不管这个。
