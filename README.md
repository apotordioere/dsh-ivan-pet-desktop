# dsh-ivan-pet-desktop

把「Ivan 桌宠」做成 DSH 插件：DSH 窗口最小化、甚至关掉，桌面右下角那只也还在。

> 页面里的桌宠活在浏览器里，窗口一最小化就跟着没了。这里换了个做法——**独立的一个透明置顶窗口**（PowerShell 5.1 + WPF），由插件负责拉起和收尾，所以它和 DSH 窗口是两个进程。

## 它长什么样

- 无边框、透明、置顶，站在屏幕右下角；**按住就能拖**，滚轮调大小（90–320 宽），位置与大小分别记在 `%APPDATA%\ivan-pet-desktop\pos.json`、`%APPDATA%\ivan-pet\size.json`
- 跟着会话状态换动作：`idle`（呼吸 + 随机眨眼）、`thinking`、`coding`、`done`、`error`、`pat`（被摸头）
- 一轮任务结束弹一条提示条：「任务好了 / 点这里回去看看」，带提示音；点提示条把 DSH 拉回前台
- **点一下就跟他说话**：弹出一个小输入框，回车发送；宿主把话交给当前会话的默认模型，用 Ivan 的口气回你一两句
- 右键 = 回 DSH

## 依赖

| 项 | 说明 |
| --- | --- |
| 系统 | Windows 10/11（WPF + PowerShell 5.1） |
| DSH | 0.2.x |
| 可选 | `ivan-pet` 插件提供 `/ivan-pet/state`；没有就一直是 `idle`，窗口照样在 |

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
    assets: 'D:/somewhere/assets'   # 可选：换一套贴图（idle/blink/thinking/coding/done/error/pat.png）
    extraArgs: []                   # 可选：透传给 pet.ps1 的参数，例如 ['-Width','260']
```

## 贴图规格

七张 PNG，透明底，角色**底部对齐**、水平居中，同一画布尺寸（推荐 300×564，内容高 556）：

```
idle.png  blink.png  thinking.png  coding.png  done.png  error.png  pat.png
```

## 它是怎么工作的

```
DSH 宿主 ──apply()──> spawn powershell.exe -File pet/pet.ps1 -Assets pet/assets
                              │
                              ├─ WPF 透明置顶窗（DispatcherTimer 轮询 /ivan-pet/state）
                              └─ 插件停用 ── dispose() ──> child.kill()
```

开始前会读 `%APPDATA%\ivan-pet-desktop\pet.pid`，把上次遗留的进程收掉，避免两只叠在一起。

## 踩过的坑（改这个插件前先看）

1. **PowerShell 5.1 只认带 BOM 的 UTF-8**。`pet.ps1` 里全是中文，文件一旦变成无 BOM，PS 按 ANSI 读 → `ParserError: 字符串缺少终止符`。用 `[IO.File]::WriteAllText($p, $t, [Text.UTF8Encoding]::new($true))` 落盘，并统一成 CRLF。
2. **别在 .NET 线程回调里跑 PowerShell 脚本块**（`.NET Timer`、`Task.Run` 之类）——没有 runspace，会静默失败。这里全部用 `DispatcherTimer`，跑在 UI 线程上。
3. **DPI**：150% 缩放屏上，DPI-unaware 的截图和窗口坐标是两套尺度。脚本开头用 `SetProcessDpiAwarenessContext(-4)` 按物理像素工作，否则提示条会偏。
4. **XamlReader 那条路走不通**：`[Windows.Markup.XamlReader]::Load()` 在这个环境里窗口根本没创建出来（`EnumWindows` 查不到），所以窗口是用代码一行行搭的。

## License

MIT
