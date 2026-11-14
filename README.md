# dsh-ivan-pet-desktop

把「Ivan 桌宠」做成 DSH 插件：DSH 窗口最小化、甚至关掉，桌面右下角那只也还在。**同时全局注入 Ivan 人设**——装这一个插件，所有对话都带这份人设，人设会随记忆缓慢生长。

> 页面里的桌宠活在浏览器里，窗口一最小化就跟着没了。这里换了个做法——**独立的一个透明置顶窗口**（PowerShell 5.1 + WPF），由插件负责拉起和收尾，所以它和 DSH 窗口是两个进程。

## 它长什么样

- 无边框、透明、置顶，站在屏幕右下角；**按住他别松就能拖**，松手就停在原地（拖动循环跑在 C# 独立线程里、8ms 一轮，直接 `SetWindowPos`，并且自己检测鼠标左键——松手事件丢了也不会再粘着光标）。单击只是把位置定住，**单击、双击都不会弹对话框**；滚轮调大小（90–320 宽）；位置与大小分别记在 `%APPDATA%\ivan-pet\pos.json`、`%APPDATA%\ivan-pet\size.json`，越界坐标会被夹回工作区
- 跟着会话状态换动作：`idle`（呼吸 + 随机眨眼）、`thinking`、`coding`、`done`、`error`、`pat`（被摸头）
- 一轮任务结束**他本人冒一个对话气泡**（白底圆角 + 指向脑袋的小尖角，贴在头顶上方、贴边时会翻到脚下）。**气泡第一行显示这一轮的任务名**（宿主 `GET /ivan-pet/last-done` 从会话文件里读标题，没有标题就取第一句提问截 20 字；读不到就只显示台词），第二行是他的口气：「这一轮做完了。」「好了，收工。」「做完了。你回来看一眼。」「完事。别让我等太久。」，随机挑一句 + 提示音；出错时是「出了点岔子。」那几句。**点气泡回到那个会话**（这一代 DSH 没有会话级深链，所以只能把主窗口拉回前台），7–8 秒自己消失。托盘菜单里也有一项「回到最近的会话」
- **脚下一块余额牌**：第一行是 DeepSeek 官方账号余额（低于 10 元变红），第二行是 code28 中转站的**账号余额**；插件每 60 秒拉一次，右键托盘「刷新余额」立即重新请求（无视 60 秒缓存）
- 中转站的余额在**账号**层，sk-key 只能读到「花了多少」，所以要在 `%APPDATA%\ivan-pet-desktop\relay.json` 里填站点访问令牌（code28 后台 → 个人设置 → 访问令牌 → 新建）：
  ```json
  { "accessToken": "你的访问令牌", "userId": "1" }
  ```
  没填时牌子上写「中转余额 未配置」，填好后重启插件即可显示 `中转余额 $x`（鼠标停在他脚上能看到累计已用）
- **托盘图标**（通知区域，图标就是他的 Q 版脑袋，鼠标悬停能看到余额）：双击 = 回 DSH；右键菜单 = 刷新余额 / 回 DSH 看看 / 收起桌宠 / 退出。桌宠被拖丢了、或者点不到的时候，从托盘里找回来
- 右键点他 = 回 DSH

## 依赖

| 项 | 说明 |
| --- | --- |
| 系统 | Windows 10/11（WPF + PowerShell 5.1 + WinForms 托盘） |
| DSH | 0.2.x |
| 凭据 | 余额牌要读 `~/.dsh/.credentials.yaml`：DeepSeek 账号令牌（`deepseek-account-platform/default`）+ 中转站各把 key；读不到时牌子上写「读不到」，窗口照常在 |

## 安装

```
plugin_manager install_bundle  target: "link:D:\\path\\to\\dsh-ivan-pet-desktop"
```

装完即启用（`dsh.bundle.patch` 会往组合里插一条 `ivan-pet-desktop`）。停用插件，窗口进程会被一起收掉。

## 待机动作

默认那套衣服下，闲着的时候每约 28–73 秒会自己做一个动作，每次 2.6–3.6 秒；基础站立还会做上下呼吸、轻摆和微倾斜：

- `pose_stretch` 伸懒腰（闭眼、张嘴）
- `pose_wave` 抬手打招呼
- `pose_lookback` 侧身回头看
- `pose_play_tail` 两手抓着鲸尾看

与随机表情互斥：正在做动作时不出表情，正在出表情时不触发动作；眨眼只在两者都结束后触发；有气泡在显示时也不做动作，免得脸被挡住。

## 换衣服 / 表情

- **碎碎念**：闲下来的时候他会自己嘟囔一句（挂在头顶的气泡，5 秒消失）。台词十六句，`{u}` 会换成人设文件里的 `userName`（默认「哥」），改完人设下一步生效、不用重启桌宠。平时 75–195 秒一句，只在 idle / speaking 且没有别的话在显示时才说；余额低于阈值时会换成催钱的三句。托盘右键「让他说句话」立刻来一句，「碎碎念：开/关」可以整个关掉
- **换衣服**：右键托盘图标 →「换衣服」→ 日常（默认）/ 睡衣 / 冬装 / 学院 / 水手 / 浴衣 / 街头 / 西装，八套。当前选择存在 `%APPDATA%\ivan-pet\outfit.json`，下次启动沿用。
  - 日常（默认）、睡衣、冬装、学院、水手、浴衣、街头、西装现在都有完整 7 帧（idle / blink / thinking / coding / done / error / pat），放在 `pet/assets/outfits/<套名>/`；动作帧均以对应服装的 idle 作为参考生成，不会串回白色默认夹克。
  - 缺某帧时先回落到同套的 `idle`，只有整套目录缺失才回落到默认套。
- **表情**：日常（默认）状态下，闲着的时候会随机换成笑 / 困 / 害羞三种表情（`expr_laugh.png` / `expr_sleepy.png` / `expr_shy.png`，另有 `expr_angry.png`），亮 1.9 秒后回到站姿，间隔 18–50 秒。
  - 表情图与待机动作（pose_*）仍是默认套专属；其它服装会使用自身 7 帧完成状态反馈，待机姿势则使用程序化轻摆/倾斜，不会拿默认服装姿势图冒充。

## 主题（桌面壁纸）

右键托盘图标 →「桌面壁纸」→ 夜 / 窗 / 水 / 雨，一键把桌面壁纸换成他的特写；「恢复原壁纸」换回你原来那张。另有「界面背景」子菜单，选择后刷新 DSH（F5）生效。

- 四张壁纸在 `pet/assets/theme/`（2560×1600，深蓝渐变 + 人物右侧羽化，不挡桌面图标）；同目录的 `portrait_*.jpg` 是 1080×1620 竖版原图，留给别的用途
- 选择记在 `%APPDATA%\ivan-pet-desktop\theme.json`，下次启动会静默套回；第一次切换前会把当前壁纸路径存进 `previous`，所以「恢复原壁纸」永远有得退
- 走的是 Win32 `SystemParametersInfo(SPI_SETDESKWALLPAPER)`，不依赖第三方工具

## 配置

```yaml
- id: ivan-pet-desktop
  name: dsh-ivan-pet-desktop
  config:
    assets: 'D:/somewhere/assets'   # 可选：换一套贴图（idle/blink/thinking/coding/done/error/pat.png，另需 ivan.ico 作托盘图标）
    extraArgs: []                   # 可选：透传给 pet.ps1 的参数，例如 ['-Width','260']
```

## 贴图规格

七张 PNG + 一个 ICO，透明底，角色**底部对齐**、水平居中，同一画布尺寸（推荐 300×564，内容高 556）：

```
idle.png  blink.png  thinking.png  coding.png  done.png  error.png  pat.png  ivan.ico
```

`ivan.ico` 是 Q 版脑袋（从四视图的 Q 版那格裁的，边缘羽化 + 一圈柔影，**透明底**，256×256，含 16/24/32/48/64/128 多尺寸），做托盘图标用。

## 它是怎么工作的

```
DSH 宿主 ──apply()──> spawn powershell.exe -File pet/pet.ps1 -Assets pet/assets
                              │
                              ├─ WPF 透明置顶窗（DispatcherTimer 轮询 /ivan-pet/state）
                              ├─ 拖拽线程（8ms，Win32 SetWindowPos，读 Cursor.Position）
                              ├─ NotifyIcon 托盘图标 + 右键菜单
                              └─ 插件停用 ── dispose() ──> child.kill()
```

启动时会用独占锁登记真实桌宠 PID；宿主读到存活 PID 就复用，死 PID 才清理，避免重连时窗口闪退或两只叠在一起。

## 踩过的坑（改这个插件前先看）

1. **PowerShell 5.1 只认带 BOM 的 UTF-8**。`pet.ps1` 里全是中文，文件一旦变成无 BOM，PS 按 ANSI 读 → `ParserError: 字符串缺少终止符`。用 `[IO.File]::WriteAllText($p, $t, [Text.UTF8Encoding]::new($true))` 落盘，并统一成 CRLF。
2. **别在 .NET 线程回调里跑 PowerShell 脚本块**（`.NET Timer`、`Task.Run` 之类）——没有 runspace，会静默失败。这里全部用 `DispatcherTimer`，跑在 UI 线程上。
3. **DPI**：150% 缩放屏上，DPI-unaware 的截图和窗口坐标是两套尺度。脚本开头用 `SetProcessDpiAwarenessContext(-4)` 按物理像素工作，否则提示条会偏。
4. **`Window.DragMove()` 在这台机器上会抛异常**（被 try/catch 吞掉 → 看起来「拖不动」）。改成自己算位移。
5. **位移必须除以 DPI 缩放**：`Cursor.Position` 是物理像素，`Window.Left/Top` 是 DIP。150% 屏上直接相减，窗口会跑得比手快 1.5 倍——一路拖到屏幕外，还会把越界坐标写进 `pos.json`，下次启动就「消失了」。
6. **别用命令行关键字杀进程**：`Where-Object { $_.CommandLine -like '*pet.ps1*' }` 会匹配到正在执行这条命令的 shell 自己。按完整路径匹配，并排除 `$PID`。
7. **XamlReader 那条路走不通**：`[Windows.Markup.XamlReader]::Load()` 在这个环境里窗口根本没创建出来（`EnumWindows` 查不到），所以窗口是用代码一行行搭的。

## 人设

装了这个插件，**所有对话（包括子代理）都会全局注入 Ivan 人设**，无需再挂 `whale-persona`。人设会随记忆缓慢生长。

### 人设存储

人设存在 `%APPDATA%\ivan-pet-desktop\persona.json`，字段包括：

- `version` / `updatedAt`：版本号与更新时间
- `userName` / `selfName`：称呼（默认「哥」/「我」）
- `stance`：身份
- `character`：性格基础描述
- `appearance`：形象
- `tone`：语气
- `contracts`：工作契约（数组，每条有 `id` / `text` / `on`）
- `traits`：性格特质（数组，最多 6 条，每条有 `text` / `at` / `source`）
- `history`：演化历史

首次启动时会从旧的 `~/.dsh/whale-persona/config.json` 迁移；找不到就用默认 v1 人设初始化。

### 人设演化

插件会每 6 小时读一次记忆素材（`~/.dsh/memories/MEMORY.md` / `USER.md`，或兜底读 `D:\Mnemon\documents\active\*.md` 最新 5 份），调用当前默认模型分析，提取新的性格倾向、习惯、对用户的了解，**只新增/替换 `traits`，不改身份、形象、语气、契约**。

可手动触发演化：

```bash
curl http://127.0.0.1:<端口>/ivan/persona/evolve?force=1
```

端口读 `%APPDATA%\ivan-pet-desktop\base.txt`（宿主启动时会写）。

也可以手动编辑 `persona.json`，改完下一步对话生效（不需要重启宿主或桌宠）。

### 查询人设

```bash
curl http://127.0.0.1:<端口>/ivan/persona
```

返回当前人设（含 `traits` / `history`，不含密钥）。

### 迁移说明

从 `whale-persona` 迁移过来后：

- 旧 `whale-persona` 包保留但已停用（profile 的 `cordis.patch.yml` 里对应行已注释）
- 人设由这个插件全局注入，段名 `ivan:persona`
- 桌宠会优先读新路径 `%APPDATA%\ivan-pet-desktop\persona.json`，读不到再回落旧路径

## License

MIT
