# workspace#16 实车取屏证据（agv02，2026-10-11）

工具：`remote-ops/onboard-hmi/scripts/17-capture-hmi-screen.ps1`。文件名里的时刻取自控制端时钟。
每次运行四个文件：`-screen.png` 全屏截图，`-window-<n>.png` 车载端窗口图，`-uia.json` 车端记录
（控件树、`visibleTexts` 屏上文字、前台窗口、锁屏判断），`-run.json` 控制端记录（预检、结果码、
清理与残留检查）。

## 第一次：栈运行、车静止（`agv02-20261011T123756-*`）

- 调度 Coordinator 10 同意后取，cs#566 现场续场二 C 段期间，车载端栈由现场会话起好。
- 结果码 `CAPTURED`，控制端 12:37:56 开始，车端 12:38:26 写完结果。
- 屏上：车辆「老厂前线新多仓位2」，上层会话「需恢复」，到站 N1-4（取货，焊线→质检关卡），
  发车安全「禁止发车」；横幅「需要恢复　上层会话要求恢复：DEPARTURE_UNSAFE。请保持车辆停稳，
  禁止重复操作仓门。」；行程计划 N1-3 已完成、N1-4 已到达、关卡待前往；1～8 号仓门全部已锁，
  1、2 号有货。
- 与调度当时的认识不一致：调度以为车 12:35:51 已从站 4 出发去关卡；屏显示车载端认为自己仍在
  N1-4 等恢复。调度随后（约 12:45 转达）确认 agv02 确实停在 N1-4、会话要求恢复，与截屏一致；
  原因由现场会话查，不在本证据里。
- **与真屏对照**：用户在车边看过这张截屏，原话「一样的，只是几分钟之前的画面」，即截屏与车上
  屏幕一致，只是截的是几分钟前那一刻。出处：用户在调度窗口里确认，由调度 Coordinator 10 转达，
  本会话 2026-10-11 12:44 收到。
- 只读核对：取屏开始与结束时前台窗口都是车载端主窗口（`0x103A8`，`SQCD.Agv.Wpf`），
  `focusDisturbed=false`。
- 残留核对：`run.json` 里 `vehicleCleanup=RUN_DIRECTORY_REMOVED`、`leftoverTasksAfter` 为空；
  事后另查，车上 `C:\8005\capture` 为空，唯一的 `W2G-` 任务是原有的 `W2G-ClockResyncAtStartup`。
- 与条码自动录入不同时跑：取之前人工查过车上没有 `W2G-EnterSublot-*` 任务。**同时想查
  `agv-enter-sublot-uia` 进程是否在跑，那条查询写错（`Get-CimInstance: 无效查询`）没有执行，
  所以「没有录入进程」这一条没有核到。**这次之后该检查已写进脚本预检（`DESKTOP_BUSY`）。
- 截图里没有密码框（`maskedPasswordBoxes=0`），也没有凭据，原样入库。

## 第二次：锁屏

文件 `agv02-20261011T200419-*`。由 cs#566 现场会话代跑，结果原件在 v2 工作区
`evidence/cs566b/20261011-ws16-lockscreen-capture/`，这里是逐字节拷贝；那边的 `00-console.txt`（终端
输出，中文因代码页显示成乱码，内容与 `-run.json` 重复）没有拷过来。

- 脚本：本分支 `b55d108`，现场会话在自己的 detached worktree `F:/8005-scratch/ws16-capture` 里运行。
- 条件（现场会话转述）：两车静止于等待点（agv02 在 216），没有在途单，闸门关。用户在 agv02 上按 Win+L，
  确认已锁屏、看到的是锁屏画面后运行；取完用户已解锁。
- 结果码 `DESKTOP_LOCKED`，退出码 3，这次测试的预期结果。控制端 20:04:19 开始，20:04:43 结束。
- 预检：`console: HT session 1; locked: True`，`logonUi=true`，没有残留任务，也没有条码录入在跑
  （`otherDesktopTools` 为空，这次是脚本预检核的）。
- 全屏图 `-screen.png`：锁屏画面（风景图与 20:04 时钟），没有车载端界面。本会话看过原图。
- 窗口图 `-window-1.png`：完整的车载端界面，上层会话「就绪」，到站「在等待点 等待点3 待命」，发车安全
  「允许发车」，8 个仓已锁空仓。本会话看过原图。
- UIA：106 个节点，`visibleTexts` 含上述文字与行程计划「等待点3 已到达」。
- 车端 `desktop`：`locked=true`、`logonUiInSession=true`、`inputDesktop="Default"`。锁屏时输入桌面仍是
  `Default`，与取屏前的预期（安全桌面）不同，判锁屏靠的是 `LogonUI`。
- 只读核对：前台窗口开始与结束都是 `LockApp`（`0x1041E`），`focusDisturbed=false`。
- 残留核对：`vehicleCleanup=RUN_DIRECTORY_REMOVED`，`leftoverTasksAfter` 为空。
- 小疑点，照实记：启动回报的 `lastRunTime=20:04:04` 早于控制端开始时刻 20:04:19 与车上预检时钟
  20:04:24，原因未查（任务计划程序报的时刻口径未核），不影响结果。
