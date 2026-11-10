param(
  [string]$Assets = (Join-Path $PSScriptRoot 'assets'),
  [int]$Width = 150,
  [int]$Height = 282,
  [string]$Base = '',
  [switch]$DemoToast
)

# 桌面常驻版 Ivan：独立置顶透明窗口，DSH 最小化也看得见；轮询宿主状态换动作；任务完成弹提示。
$ErrorActionPreference = 'Stop'

# 按物理像素工作：150% 缩放屏上也不糊，坐标与实际屏幕一致
try {
  Add-Type @"
using System;
using System.Runtime.InteropServices;
public class PetDpi {
  [DllImport("user32.dll")] public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
}
"@
  try { [void][PetDpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) }
  catch { [void][PetDpi]::SetProcessDpiAwareness(2) }
} catch { }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$script:Assets = $Assets
$script:BaseFile = Join-Path $env:APPDATA 'ivan-pet-desktop\base.txt'
$script:Base = $null
$script:PollFails = 0
if ($Base) { $script:Base = $Base.TrimEnd('/') }
$script:LastState = 'idle'
$script:PatUntil = [DateTime]::MinValue
$script:BlinkUntil = [DateTime]::MinValue
$script:NextBlink = [DateTime]::Now.AddSeconds(4)
$script:LatestState = 'idle'
$script:ToastUntil = [DateTime]::MinValue
$script:PosFile = Join-Path $env:APPDATA 'ivan-pet\pos.json'
$script:LogFile = Join-Path $env:APPDATA 'ivan-pet\pet.log'
$script:SizeFile = Join-Path $env:APPDATA 'ivan-pet\size.json'
$script:Aspect = 414 / 220        # 窗口默认长宽比，滚轮缩放时锁死
$script:MinW = 90
$script:MaxW = 320

function Write-Log([string]$m) {
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path $script:LogFile) | Out-Null
    Add-Content -Path $script:LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8
  } catch { }
}

function Find-Base {
  $ports = @()
  try {
    $pids = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'DeepSeek' } | Select-Object -ExpandProperty Id)
    if ($pids.Count -gt 0) {
      $ports = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $pids -contains $_.OwningProcess } |
        Select-Object -ExpandProperty LocalPort -Unique)
    }
  } catch { }
  foreach ($p in ($ports + @(56602, 52046, 50486))) {
    try {
      $r = Invoke-RestMethod -Uri "http://127.0.0.1:$p/ivan-pet/state" -TimeoutSec 1 -ErrorAction Stop
      if ($r -and $r.state) { return "http://127.0.0.1:$p" }
    } catch { }
  }
  return $null
}

# ---------- 窗口 ----------
$win = New-Object System.Windows.Window
$win.WindowStyle = [System.Windows.WindowStyle]::None
$win.AllowsTransparency = $true
$win.Background = [System.Windows.Media.Brushes]::Transparent
$win.Topmost = $true
$win.ShowInTaskbar = $false
$win.ResizeMode = [System.Windows.ResizeMode]::NoResize
$win.Width = $Width
$win.Height = $Height

# 上次滚轮调过的大小（存在 size.json 里）
if (Test-Path $script:SizeFile) {
  try {
    $sz = Get-Content $script:SizeFile -Raw | ConvertFrom-Json
    if ($sz.width -and $sz.width -ge $script:MinW -and $sz.width -le $script:MaxW) {
      $Width = [int]$sz.width
      $Height = [int][math]::Round($Width * $script:Aspect)
      $win.Width = $Width
      $win.Height = $Height
    }
  } catch { }
}

$grid = New-Object System.Windows.Controls.Grid
$grid.Background = [System.Windows.Media.Brushes]::Transparent

$img = New-Object System.Windows.Controls.Image
$img.Stretch = [System.Windows.Media.Stretch]::Uniform
[System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, [System.Windows.Media.BitmapScalingMode]::HighQuality)
$img.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 1)

$scale = New-Object System.Windows.Media.ScaleTransform(1, 1)
$move = New-Object System.Windows.Media.TranslateTransform(0, 0)
$tg = New-Object System.Windows.Media.TransformGroup
$tg.Children.Add($scale) | Out-Null
$tg.Children.Add($move) | Out-Null
$img.RenderTransform = $tg

$grid.Children.Add($img) | Out-Null

# 说话按钮：常驻，点它开输入框
$chatBtn = New-Object System.Windows.Controls.Border
$chatBtn.Width = 26
$chatBtn.Height = 26
$chatBtn.CornerRadius = New-Object System.Windows.CornerRadius 13
$chatBtn.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(210, 255, 255, 255))
$chatBtn.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(60, 27, 42, 74))
$chatBtn.BorderThickness = New-Object System.Windows.Thickness 1
$chatBtn.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
$chatBtn.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
$chatBtn.Margin = New-Object System.Windows.Thickness(0, 0, 4, 6)
$chatBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$chatBtn.ToolTip = '跟我说话'
$chatBtnText = New-Object System.Windows.Controls.TextBlock
$chatBtnText.Text = '说'
$chatBtnText.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
$chatBtnText.FontSize = 11
$chatBtnText.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(80, 160, 228))
$chatBtnText.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
$chatBtnText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
$chatBtn.Child = $chatBtnText
$grid.Children.Add($chatBtn) | Out-Null

$win.Content = $grid

# 位置
$wa = [System.Windows.SystemParameters]::WorkArea
$left = $wa.Right - $Width - 28
$top = $wa.Bottom - $Height - 6
if (Test-Path $script:PosFile) {
  try {
    $p = Get-Content $script:PosFile -Raw | ConvertFrom-Json
    if ($null -ne $p.left -and $null -ne $p.top) { $left = [double]$p.left; $top = [double]$p.top }
  } catch { }
}
# 夹回工作区：位置文件里可能是旧版本留下的越界坐标
if ($left -lt ($wa.Left - 4) -or $left -gt ($wa.Right - $Width + 4)) { $left = $wa.Right - $Width - 28 }
if ($top -lt ($wa.Top - 4) -or $top -gt ($wa.Bottom - $Height + 4)) { $top = $wa.Bottom - $Height - 6 }
$win.Left = $left
$win.Top = $top

function Save-Pos {
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path $script:PosFile) | Out-Null
    @{ left = [math]::Round([math]::Min([math]::Max($win.Left, $wa.Left), $wa.Right - $win.Width)); top = [math]::Round([math]::Min([math]::Max($win.Top, $wa.Top), $wa.Bottom - $win.Height)) } | ConvertTo-Json | Set-Content -Path $script:PosFile -Encoding UTF8
  } catch { }
}

function Save-Size {
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path $script:SizeFile) | Out-Null
    @{ width = [math]::Round($win.Width) } | ConvertTo-Json | Set-Content -Path $script:SizeFile -Encoding UTF8
  } catch { }
}

# 滚轮调大小：往上变大、往下变小，范围 $script:MinW ~ $script:MaxW，自动记住
$win.Add_MouseWheel({
  param($sender, $e)
  try {
  $step = 1.1
  if ($e.Delta -lt 0) { $step = 1 / 1.1 }
  $w = [math]::Round($win.Width * $step)
  if ($w -lt $script:MinW) { $w = $script:MinW }
  if ($w -gt $script:MaxW) { $w = $script:MaxW }
  $win.Width = $w
  $win.Height = [math]::Round($w * $script:Aspect)
  } catch { }
  Save-Size
  $e.Handled = $true
})

# ---------- 贴图 ----------
$script:Cache = @{}
function Get-Sprite([string]$name) {
  if (-not $script:Cache.ContainsKey($name)) {
    $path = Join-Path $script:Assets "$name.png"
    if (-not (Test-Path $path)) { $path = Join-Path $script:Assets 'idle.png' }
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.UriSource = New-Object System.Uri($path)
    $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.EndInit()
    $bmp.Freeze()
    $script:Cache[$name] = $bmp
  }
  return $script:Cache[$name]
}

function Set-Frame([string]$name) {
  $s = Get-Sprite $name
  if (-not [object]::ReferenceEquals($img.Source, $s)) { $img.Source = $s }
}

# ---------- 动画 ----------
function Start-Breathe {
  $breathe = New-Object System.Windows.Media.Animation.DoubleAnimation
  $breathe.From = 0
  $breathe.To = -4
  $breathe.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(2.6))
  $breathe.AutoReverse = $true
  $breathe.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $breathe.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
  $move.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $breathe)
}
Start-Breathe

function Hop {
  $y = New-Object System.Windows.Media.Animation.DoubleAnimation
  $y.From = 0; $y.To = -20
  $y.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(200))
  $y.AutoReverse = $true
  $y.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
  $move.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $y)
}

function Squash {
  $sx = New-Object System.Windows.Media.Animation.DoubleAnimation
  $sx.From = 1; $sx.To = 1.06
  $sx.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(130))
  $sx.AutoReverse = $true
  $sx.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
  $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $sx)
  $sy = New-Object System.Windows.Media.Animation.DoubleAnimation
  $sy.From = 1; $sy.To = 0.94
  $sy.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(130))
  $sy.AutoReverse = $true
  $sy.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
  $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $sy)
}

# ---------- 提示条 ----------
$toast = New-Object System.Windows.Window
$toast.WindowStyle = [System.Windows.WindowStyle]::None
$toast.AllowsTransparency = $true
$toast.Background = [System.Windows.Media.Brushes]::Transparent
$toast.Topmost = $true
$toast.ShowInTaskbar = $false
$toast.ResizeMode = [System.Windows.ResizeMode]::NoResize
$toast.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight
$toast.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')

# 说话气泡：白底圆角 + 下面一个小尖角，尖角指着桌宠
$bubbleRoot = New-Object System.Windows.Controls.StackPanel
$bubbleRoot.Orientation = [System.Windows.Controls.Orientation]::Vertical
$bubbleRoot.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center

$border = New-Object System.Windows.Controls.Border
$border.CornerRadius = New-Object System.Windows.CornerRadius(16)
$border.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(252, 255, 255, 255))
$border.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(40, 14, 23, 41))
$border.BorderThickness = New-Object System.Windows.Thickness(1)
$border.Padding = New-Object System.Windows.Thickness(15, 11, 15, 11)
try {
  $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
  $shadow.BlurRadius = 18
  $shadow.ShadowDepth = 3
  $shadow.Direction = 270
  $shadow.Opacity = 0.16
  $shadow.Color = [System.Windows.Media.Color]::FromRgb(14, 23, 41)
  $border.Effect = $shadow
} catch { }

$stack = New-Object System.Windows.Controls.StackPanel
$stack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
$tbTitle = New-Object System.Windows.Controls.TextBlock
$tbTitle.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
$tbTitle.FontSize = 13.5
$tbTitle.FontWeight = [System.Windows.FontWeights]::SemiBold
$tbTitle.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(27, 42, 74))
$tbTitle.Text = '任务好了'
$tbTitle.TextWrapping = [System.Windows.TextWrapping]::Wrap
$tbTitle.MaxWidth = 248
$tbTitle.LineHeight = 19
$tbSub = New-Object System.Windows.Controls.TextBlock
$tbSub.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
$tbSub.FontSize = 11.5
$tbSub.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(107, 122, 147))
$tbSub.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
$tbSub.TextWrapping = [System.Windows.TextWrapping]::Wrap
$tbSub.MaxWidth = 248
$tbSub.Text = '点这里回去看看'
$stack.Children.Add($tbTitle) | Out-Null
$stack.Children.Add($tbSub) | Out-Null
$border.Child = $stack
$bubbleRoot.Children.Add($border) | Out-Null

$tailCanvas = New-Object System.Windows.Controls.Canvas
$tailCanvas.Width = 18
$tailCanvas.Height = 9
$tail = New-Object System.Windows.Shapes.Polygon
$ptTail = New-Object System.Windows.Media.PointCollection
$ptTail.Add((New-Object System.Windows.Point(0, 0))) | Out-Null
$ptTail.Add((New-Object System.Windows.Point(18, 0))) | Out-Null
$ptTail.Add((New-Object System.Windows.Point(9, 9))) | Out-Null
$tail.Points = $ptTail
$tail.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(252, 255, 255, 255))
$tail.Stroke = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(40, 14, 23, 41))
$tail.StrokeThickness = 1
$tailCanvas.Children.Add($tail) | Out-Null
$bubbleRoot.Children.Add($tailCanvas) | Out-Null
$toast.Content = $bubbleRoot

function Show-Toast([string]$title, [string]$sub, [int]$seconds = 6) {
  $tbTitle.Text = $title
  if ([string]::IsNullOrWhiteSpace($sub)) {
    $tbSub.Visibility = [System.Windows.Visibility]::Collapsed
  } else {
    $tbSub.Text = $sub
    $tbSub.Visibility = [System.Windows.Visibility]::Visible
  }
  if (-not $toast.IsVisible) { $toast.Show() }
  $toast.UpdateLayout()
  $tw = $toast.ActualWidth
  if ($tw -le 0) { $tw = 260 }
  $th = $toast.ActualHeight
  if ($th -le 0) { $th = 64 }
  # 气泡贴在脑袋上方、水平居中；顶到屏幕上沿就翻到脚下
  $left = $win.Left + ($win.Width - $tw) / 2
  $top = $win.Top - $th + 6
  if ($top -lt 4) { $top = $win.Top + $win.Height - 10 }
  if ($left -lt 4) { $left = 4 }
  $toast.Left = $left
  $toast.Top = $top
  $script:ToastUntil = [DateTime]::Now.AddSeconds($seconds)
}

$script:doneLines = @(
  '这一轮做完了。',
  '好了，收工。',
  '做完了。你回来看一眼。',
  '完事。别让我等太久。'
)
$script:errLines = @(
  '出了点岔子。',
  '卡住了，你来看一下。',
  '这一步没过去。'
)
function Show-Bubble-TaskDone {
  Show-Toast ($script:doneLines | Get-Random) '' 7
}
function Show-Bubble-TaskError {
  Show-Toast ($script:errLines | Get-Random) '' 8
}

function Focus-Dsh {
  try {
    $p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'DeepSeek' -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($p) {
      if (-not ('Win32Focus' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Focus {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
}
"@
      }
      [Win32Focus]::ShowWindow($p.MainWindowHandle, 9) | Out-Null
      [Win32Focus]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
    }
  } catch { }
}

# ---------- 说话框 ----------
Add-Type -AssemblyName System.Net.Http | Out-Null
$script:http = New-Object System.Net.Http.HttpClient
$script:http.Timeout = [TimeSpan]::FromSeconds(60)
$script:chatTask = $null

$chatWin = New-Object System.Windows.Window
$chatWin.WindowStyle = [System.Windows.WindowStyle]::None
$chatWin.AllowsTransparency = $true
$chatWin.Background = [System.Windows.Media.Brushes]::Transparent
$chatWin.Topmost = $true
$chatWin.ShowInTaskbar = $false
$chatWin.ResizeMode = [System.Windows.ResizeMode]::NoResize
$chatWin.Width = 300
$chatWin.Height = 112
$chatWin.Visibility = [System.Windows.Visibility]::Collapsed

$chatBorder = New-Object System.Windows.Controls.Border
$chatBorder.CornerRadius = New-Object System.Windows.CornerRadius 14
$chatBorder.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(252, 255, 255, 255))
$chatBorder.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(34, 14, 23, 41))
$chatBorder.BorderThickness = New-Object System.Windows.Thickness 1
$chatBorder.Padding = New-Object System.Windows.Thickness 12, 10, 12, 10
$chatBorder.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{ BlurRadius = 18; ShadowDepth = 2; Direction = 270; Opacity = 0.18; Color = [System.Windows.Media.Color]::FromRgb(14, 23, 41) }

$chatHint = New-Object System.Windows.Controls.TextBlock
$chatHint.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
$chatHint.FontSize = 10.5
$chatHint.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(150, 162, 184))
$chatHint.Text = '跟我说点什么，回车发送'
$chatHint.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)

$chatBox = New-Object System.Windows.Controls.TextBox
$chatBox.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
$chatBox.FontSize = 13
$chatBox.BorderThickness = New-Object System.Windows.Thickness 0
$chatBox.Background = [System.Windows.Media.Brushes]::Transparent
$chatBox.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(27, 42, 74))
$chatBox.CaretBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(80, 160, 228))
$chatBox.AcceptsReturn = $false

$chatTitle = New-Object System.Windows.Controls.TextBlock
$chatTitle.Text = '跟 Ivan 说'
$chatTitle.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
$chatTitle.FontSize = 11
$chatTitle.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(80, 160, 228))
$chatTitle.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

$chatClose = New-Object System.Windows.Controls.Button
$chatClose.Content = '×'
$chatClose.Width = 20
$chatClose.Height = 20
$chatClose.FontSize = 13
$chatClose.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
$chatClose.Padding = New-Object System.Windows.Thickness 0
$chatClose.BorderThickness = New-Object System.Windows.Thickness 0
$chatClose.Background = [System.Windows.Media.Brushes]::Transparent
$chatClose.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(140, 152, 176))
$chatClose.Cursor = [System.Windows.Input.Cursors]::Hand
$chatClose.ToolTip = '关掉'
$chatClose.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

$chatHead = New-Object System.Windows.Controls.DockPanel
$chatHead.LastChildFill = $true
[System.Windows.Controls.DockPanel]::SetDock($chatClose, [System.Windows.Controls.Dock]::Right)
$chatHead.Children.Add($chatClose) | Out-Null
$chatHead.Children.Add($chatTitle) | Out-Null
$chatHead.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)

$chatStack = New-Object System.Windows.Controls.StackPanel
$chatStack.Children.Add($chatHead) | Out-Null
$chatStack.Children.Add($chatHint) | Out-Null
$chatStack.Children.Add($chatBox) | Out-Null
$chatBorder.Child = $chatStack
$chatWin.Content = $chatBorder

function Open-Chat {
  try {
    $left = $win.Left - $chatWin.Width + $win.Width
    if ($left -lt 8) { $left = 8 }
    if ($left + $chatWin.Width -gt ([System.Windows.SystemParameters]::WorkArea.Right - 8)) {
      $left = [System.Windows.SystemParameters]::WorkArea.Right - $chatWin.Width - 8
    }
    $top = $win.Top - $chatWin.Height + 30
    if ($top -lt 8) { $top = $win.Top + $win.Height - 40 }
    $chatWin.Left = $left
    $chatWin.Top = $top
    $chatWin.Visibility = [System.Windows.Visibility]::Visible
    $chatBox.Text = ''
    $chatBox.Focus() | Out-Null
  } catch { }
}

function Close-Chat { $chatWin.Visibility = [System.Windows.Visibility]::Collapsed }

$chatClose.Add_Click({ Close-Chat })

function Send-Chat {
  $text = ($chatBox.Text).Trim()
  Close-Chat
  if (-not $text) { return }
  if (-not $script:Base) { Show-Toast '还没连上' 'DSH 那边没回应，等会儿再说' 4; return }
  $url = "$($script:Base)/ivan-pet/chat?text=" + [Uri]::EscapeDataString($text)
  Show-Toast '……' '' 60
  try { $script:chatTask = $script:http.GetStringAsync($url) } catch { Show-Toast '说不出来' '请求没发出去' 4; $script:chatTask = $null }
}

$chatBox.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Enter) { Send-Chat; $e.Handled = $true }
    elseif ($e.Key -eq [System.Windows.Input.Key]::Escape) { Close-Chat; $e.Handled = $true }
  })

# ---------- 交互 ----------
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class PetWin {
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
$script:petHwnd = [IntPtr]::Zero
$script:SWP_NOSIZE = 0x0001
$script:SWP_NOZORDER = 0x0004
$script:SWP_NOACTIVATE = 0x0010
$script:dragging = $false
$script:dragMoved = $false
$script:dragStartX = 0.0
$script:dragStartY = 0.0
$script:dragOriginLeft = 0.0
$script:dragOriginTop = 0.0
$script:dpi = 1.0
$script:dragWinX = 0
$script:dragWinY = 0

# 用 15ms 计时器读光标位置来移动窗口：比在每个 MouseMove 里改 Left/Top 跟手得多
Add-Type @'
using System;
using System.Threading;
using System.Runtime.InteropServices;
public class PetDrag {
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
  struct POINT { public int X, Y; }
  static Thread t;
  static volatile bool running;
  public static volatile bool Moved;
  static int sx, sy, wx, wy;
  static IntPtr hw;
  public static void Start(IntPtr hwnd, int cx, int cy, int winx, int winy) {
    Stop();
    hw = hwnd; sx = cx; sy = cy; wx = winx; wy = winy; Moved = false;
    running = true;
    t = new Thread(Loop);
    t.IsBackground = true;
    t.Priority = ThreadPriority.Highest;
    t.Start();
  }
  static void Loop() {
    while (running) {
      // 左键松开就自己收工：MouseUp 事件丢了也不会一直粘着光标
      if ((GetAsyncKeyState(0x01) & 0x8000) == 0) { running = false; break; }
      POINT p;
      if (GetCursorPos(out p)) {
        int dx = p.X - sx, dy = p.Y - sy;
        if (!Moved && (Math.Abs(dx) > 2 || Math.Abs(dy) > 2)) Moved = true;
        if (Moved) SetWindowPos(hw, IntPtr.Zero, wx + dx, wy + dy, 0, 0, 0x0001 | 0x0004 | 0x0010);
      }
      Thread.Sleep(8);
    }
  }
  public static bool IsRunning { get { return running; } }
  public static void Stop() {
    running = false;
    if (t != null) { try { t.Join(60); } catch { } t = null; }
  }
}
'@
# 窗口移动由 [PetDrag] 的独立线程负责（8ms 一轮，不经过 PowerShell）

$img.Add_MouseLeftButtonDown({
    try {
      $script:dragging = $true
      $script:dragMoved = $false
      $c = [System.Windows.Forms.Cursor]::Position
      $script:dragStartX = $c.X
      $script:dragStartY = $c.Y
      $script:dragOriginLeft = $win.Left
      $script:dragOriginTop = $win.Top
      try {
        $src = [System.Windows.PresentationSource]::FromVisual($win)
        if ($src -and $src.CompositionTarget) { $script:dpi = $src.CompositionTarget.TransformToDevice.M11 }
      } catch { }
      if ($script:dpi -le 0) { $script:dpi = 1.0 }
      # 拖的时候别再让呼吸动画占渲染，窗口移动改用 SetWindowPos
      try { $move.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null) } catch { }
      try {
        $script:petHwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        $rc = New-Object PetWin+RECT
        if ([PetWin]::GetWindowRect($script:petHwnd, [ref]$rc)) {
          $script:dragWinX = $rc.Left
          $script:dragWinY = $rc.Top
        } else {
          $script:dragWinX = [int]($win.Left * $script:dpi)
          $script:dragWinY = [int]($win.Top * $script:dpi)
        }
      } catch { }
      [void]$img.CaptureMouse()
      if ($script:petHwnd -ne [IntPtr]::Zero) {
        [PetDrag]::Start($script:petHwnd, $script:dragStartX, $script:dragStartY, $script:dragWinX, $script:dragWinY)
      }
    } catch { }
  })

# 移动窗口的工作交给 [PetDrag] 的独立线程，这里不再逐帧改 Left/Top

$img.Add_MouseLeftButtonUp({
    try {
      $script:dragging = $false
      try { $script:dragMoved = [PetDrag]::Moved } catch { }
      try { [PetDrag]::Stop() } catch { }
      [void]$img.ReleaseMouseCapture()
      if ($script:petHwnd -ne [IntPtr]::Zero) {
        try {
          $rc = New-Object PetWin+RECT
          if ([PetWin]::GetWindowRect($script:petHwnd, [ref]$rc)) {
            $win.Left = $rc.Left / $script:dpi
            $win.Top = $rc.Top / $script:dpi
          }
        } catch { }
      }
      try { Start-Breathe } catch { }
      if ($script:dragMoved) {
        Save-Pos
      } else {
        # 单击：只把位置定住（存盘），不弹对话框；双击同理
        $script:PatUntil = [DateTime]::Now.AddMilliseconds(600)
        Squash
        Save-Pos
      }
    } catch { }
  })

$win.Add_MouseRightButtonUp({ Focus-Dsh })

$toast.Add_MouseLeftButtonUp({ Focus-Dsh; $toast.Hide(); $script:ToastUntil = [DateTime]::MinValue })

# ---------- 状态轮询（UI 线程，localhost 够快） ----------
$poll = New-Object System.Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromMilliseconds(900)
$poll.Add_Tick({
    if (-not $script:Base) {
      # 宿主启动时会把 origin 写进 base.txt（端口每次重启都可能变，靠进程名找端口不可靠）
      $cand = $null
      try {
        if (Test-Path $script:BaseFile) {
          $cand = (Get-Content $script:BaseFile -Raw -ErrorAction SilentlyContinue)
          if ($cand) { $cand = $cand.Trim() }
        }
      } catch { }
      if (-not $cand) { $cand = Find-Base }
      if (-not $cand) { return }
      $script:Base = $cand.TrimEnd('/')
      Write-Log "base=$($script:Base)"
    }
    try {
      $r = Invoke-RestMethod -Uri "$($script:Base)/ivan-pet/state" -TimeoutSec 1
      if ($r -and $r.state) {
        $script:LatestState = [string]$r.state
        $script:PollFails = 0
      }
    } catch {
      # 单次超时（宿主正忙）就把 base 清掉会漏掉 done 那一帧，所以连续失败才重连
      $script:PollFails = $script:PollFails + 1
      if ($script:PollFails -ge 4) {
        $script:PollFails = 0
        $script:Base = $null
      }
    }
  })

# ---------- 画面刷新 ----------
$ui = New-Object System.Windows.Threading.DispatcherTimer
$ui.Interval = [TimeSpan]::FromMilliseconds(120)
$ui.Add_Tick({
    # 兜底：拖动线程已自行结束（左键松开）但 MouseUp 没进来 → 在这里收尾定住
    if ($script:dragging) {
      $alive = $true
      try { $alive = [PetDrag]::IsRunning } catch { }
      if (-not $alive) {
        $script:dragging = $false
        try { [PetDrag]::Stop() } catch { }
        if ($script:petHwnd -ne [IntPtr]::Zero) {
          try {
            $rc2 = New-Object PetWin+RECT
            if ([PetWin]::GetWindowRect($script:petHwnd, [ref]$rc2)) {
              $win.Left = $rc2.Left / $script:dpi
              $win.Top = $rc2.Top / $script:dpi
            }
          } catch { }
        }
        try { Start-Breathe } catch { }
        try { Save-Pos } catch { }
        Write-Log "drag finished (auto)"
      }
    }

    $st = $script:LatestState

    if ($st -ne $script:LastState) {
      $prev = $script:LastState
      $script:LastState = $st
      Write-Log "state $prev -> $st"
      if ($st -eq 'done') {
        Show-Bubble-TaskDone
        [System.Media.SystemSounds]::Asterisk.Play()
        Hop
      } elseif ($st -eq 'error') {
        Show-Bubble-TaskError
        [System.Media.SystemSounds]::Hand.Play()
      } elseif ($st -eq 'pat') {
        Squash
      }
    }

    $show = $st
    if (($st -eq 'idle' -or $st -eq 'speaking') -and [DateTime]::Now -lt $script:PatUntil) { $show = 'pat' }
    if (($st -eq 'idle' -or $st -eq 'speaking') -and [DateTime]::Now -ge $script:PatUntil) {
      if ([DateTime]::Now -ge $script:NextBlink) {
        $script:BlinkUntil = [DateTime]::Now.AddMilliseconds(110)
        $script:NextBlink = [DateTime]::Now.AddSeconds(3 + (Get-Random -Minimum 0 -Maximum 35) / 10)
      }
      if ([DateTime]::Now -lt $script:BlinkUntil) { $show = 'blink' }
    }
    Set-Frame $show

    if ($script:ToastUntil -ne [DateTime]::MinValue -and [DateTime]::Now -gt $script:ToastUntil) {
      $toast.Hide()
      $script:ToastUntil = [DateTime]::MinValue
    }

    # 说话：等模型回话
    if ($script:chatTask -ne $null -and $script:chatTask.IsCompleted) {
      $task = $script:chatTask
      $script:chatTask = $null
      try {
        $raw = $task.Result
        $obj = $raw | ConvertFrom-Json
        if ($obj.ok) {
          Show-Toast ([string]$obj.reply) '' 20
        } else {
          Show-Toast '说不出来' ([string]$obj.error) 5
        }
      } catch {
        Show-Toast '说不出来' '线路不通，等会儿再试' 5
      }
    }
  })

# ---------- 托盘图标 ----------
Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null

$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Text = 'Ivan · 桌宠'
$icoPath = Join-Path $Assets 'ivan.ico'
if (Test-Path $icoPath) {
  try { $script:tray.Icon = New-Object System.Drawing.Icon($icoPath) } catch { }
}
if (-not $script:tray.Icon) { $script:tray.Icon = [System.Drawing.SystemIcons]::Application }

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayMenu.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9)

$miChat = New-Object System.Windows.Forms.ToolStripMenuItem
$miChat.Text = '跟我说话'
$trayMenu.Items.Add($miChat) | Out-Null

$miDsh = New-Object System.Windows.Forms.ToolStripMenuItem
$miDsh.Text = '回 DSH 看看'
$trayMenu.Items.Add($miDsh) | Out-Null

$miToggle = New-Object System.Windows.Forms.ToolStripMenuItem
$miToggle.Text = '收起桌宠'
$trayMenu.Items.Add($miToggle) | Out-Null

$sep = New-Object System.Windows.Forms.ToolStripSeparator
$trayMenu.Items.Add($sep) | Out-Null

$miQuit = New-Object System.Windows.Forms.ToolStripMenuItem
$miQuit.Text = '退出'
$trayMenu.Items.Add($miQuit) | Out-Null

$script:tray.ContextMenuStrip = $trayMenu

$miChat.Add_Click({ try { $win.Visibility = [System.Windows.Visibility]::Visible; $win.Activate() | Out-Null; Open-Chat } catch { } })
$miDsh.Add_Click({ Focus-Dsh })
$miToggle.Add_Click({
    try {
      if ($win.Visibility -eq [System.Windows.Visibility]::Visible) {
        $win.Visibility = [System.Windows.Visibility]::Hidden
        $miToggle.Text = '放出桌宠'
      } else {
        $win.Visibility = [System.Windows.Visibility]::Visible
        $miToggle.Text = '收起桌宠'
      }
    } catch { }
  })
$miQuit.Add_Click({
    try { $script:tray.Visible = $false; $script:tray.Dispose() } catch { }
    try { $poll.Stop(); $ui.Stop() } catch { }
    try { $chatWin.Close() } catch { }
    try { $win.Close() } catch { }
    [System.Windows.Application]::Current.Shutdown()
  })

$script:tray.Add_MouseDoubleClick({ try { $win.Visibility = [System.Windows.Visibility]::Visible; Open-Chat } catch { } })
$script:tray.Visible = $true
Write-Log 'tray icon on'

$win.Add_Closed({
    $poll.Stop(); $ui.Stop()
    try { $script:tray.Visible = $false; $script:tray.Dispose() } catch { }
    try { $chatWin.Close() } catch { }
    [System.Windows.Application]::Current.Shutdown()
  })

Write-Log 'window creating'
$win.Show()
Write-Log 'window shown'
$poll.Start()
$ui.Start()

if ($DemoToast) { Show-Bubble-TaskDone }

$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$app.add_DispatcherUnhandledException({
  param($sender, $e)
  Write-Log ("UI error: " + $e.Exception.Message)
  $e.Handled = $true
})
$app.Run($win) | Out-Null
