# dsh-ivan-pet-desktop

把「Ivan 桌宠」做成 DSH 插件：DSH 窗口最小化、甚至关掉，桌面右下角那只也还在。

> 页面里的桌宠活在浏览器里，窗口一最小化就跟着没了。这里换了个做法——**独立的一个透明置顶窗口**（PowerShell 5.1 + WPF），由插件负责拉起和收尾，所以它和 DSH 窗口是两个进程。

## 它长什么样

- 无边框、透明、置顶，站在屏幕右下角；**按住他别松就能拖**，松手就停在原地（拖动循环跑在 C# 独立线程里、8ms 一轮，直接 `SetWindowPos`，并且自己检测鼠标左键——松手事件丢了也不会再粘着光标）。单击只是把位置定住，**单击、双击都不会弹对话框**；滚轮调大小（90–320 宽）；位置与大小分别记在 `%APPDATA%\ivan-pet\pos.json`、`%APPDATA%\ivan-pet\size.json`，越界坐标会被夹回工作区
- 跟着会话状态换动作：`idle`（呼吸 + 随机眨眼）、`thinking`、`coding`、`done`、`error`、`pat`（被摸头）
- 一轮任务结束**他本人冒一个对话气泡**（白底圆角 + 指向脑袋的小尖角，贴在头顶上方、贴边时会翻到脚下），内容是他的口气：「这一轮做完了。」「好了，收工。」「做完了。你回来看一眼。」「完事。别让我等太久。」，随机挑一句 + 提示音；出错时是「出了点岔子。」那几句。点气泡把 DSH 拉回前台，7–8 秒自己消失
- **右下角那个「说」按钮**：点它开输入框（回车发送、Esc 关）；输入框右上角有 `×` 关掉。这是他身上唯一的对话入口——点他本人不会再弹框
- **托盘图标**（通知区域，图标就是他的 Q 版脑袋）：双击 = 说话；右键菜单 = 跟我说话 / 回 DSH 看看 / 收起桌宠 / 退出。桌宠被拖丢了、或者点不到的时候，从托盘里找回来
- 右键点他 = 回 DSH

## 依赖

| 项 | 说明 |
| --- | --- |
| 系统 | Windows 10/11（WPF + PowerShell 5.1 + WinForms 托盘） |
| DSH | 0.2.x |
| 可选 | `ivan-pet` 插件提供 `/ivan-pet/state` 与 `/ivan-pet/chat`；没有的话一直是 `idle`，窗口照样在，说话会提示「还没连上」 |

## 安装

```
plugin_manager install_bundle  target: "link:D:\\path\\to\\dsh-ivan-pet-desktop"
```

装完即启用（`dsh.bundle.patch` 会往组合里插一条 `ivan-pet-desktop`）。停用插件，窗口进程会被一起收掉。

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
                              ├─ 拖拽计时器（15ms，读 Cursor.Position，按 DPI 换算成 DIP）
                              ├─ NotifyIcon 托盘图标 + 右键菜单
                              └─ 插件停用 ── dispose() ──> child.kill()
```

开始前会读 `%APPDATA%\ivan-pet-desktop\pet.pid`，把上次遗留的进程收掉，避免两只叠在一起。

## 踩过的坑（改这个插件前先看）

1. **PowerShell 5.1 只认带 BOM 的 UTF-8**。`pet.ps1` 里全是中文，文件一旦变成无 BOM，PS 按 ANSI 读 → `ParserError: 字符串缺少终止符`。用 `[IO.File]::WriteAllText($p, $t, [Text.UTF8Encoding]::new($true))` 落盘，并统一成 CRLF。
2. **别在 .NET 线程回调里跑 PowerShell 脚本块**（`.NET Timer`、`Task.Run` 之类）——没有 runspace，会静默失败。这里全部用 `DispatcherTimer`，跑在 UI 线程上。
3. **DPI**：150% 缩放屏上，DPI-unaware 的截图和窗口坐标是两套尺度。脚本开头用 `SetProcessDpiAwarenessContext(-4)` 按物理像素工作，否则提示条会偏。
4. **`Window.DragMove()` 在这台机器上会抛异常**（被 try/catch 吞掉 → 看起来「拖不动」）。改成自己算位移。
5. **位移必须除以 DPI 缩放**：`Cursor.Position` 是物理像素，`Window.Left/Top` 是 DIP。150% 屏上直接相减，窗口会跑得比手快 1.5 倍——一路拖到屏幕外，还会把越界坐标写进 `pos.json`，下次启动就「消失了」。
6. **别用命令行关键字杀进程**：`Where-Object { $_.CommandLine -like '*pet.ps1*' }` 会匹配到正在执行这条命令的 shell 自己。按完整路径匹配，并排除 `$PID`。
7. **XamlReader 那条路走不通**：`[Windows.Markup.XamlReader]::Load()` 在这个环境里窗口根本没创建出来（`EnumWindows` 查不到），所以窗口是用代码一行行搭的。

## License

MIT
