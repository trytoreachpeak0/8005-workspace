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
  N1-4 等恢复。已转现场会话核对，核对结论不在本证据里。
- 只读核对：取屏开始与结束时前台窗口都是车载端主窗口（`0x103A8`，`SQCD.Agv.Wpf`），
  `focusDisturbed=false`。
- 残留核对：`run.json` 里 `vehicleCleanup=RUN_DIRECTORY_REMOVED`、`leftoverTasksAfter` 为空；
  事后另查，车上 `C:\8005\capture` 为空，唯一的 `W2G-` 任务是原有的 `W2G-ClockResyncAtStartup`。
- 与条码自动录入不同时跑：取之前人工查过车上没有 `W2G-EnterSublot-*` 任务。**同时想查
  `agv-enter-sublot-uia` 进程是否在跑，那条查询写错（`Get-CimInstance: 无效查询`）没有执行，
  所以「没有录入进程」这一条没有核到。**这次之后该检查已写进脚本预检（`DESKTOP_BUSY`）。
- 截图里没有密码框（`maskedPasswordBoxes=0`），也没有凭据，原样入库。

## 第二次：锁屏

待做。按用户选的做法：C 段两步之间车静止时，由现场的人按 Win+L，取完点「登录」解锁。
