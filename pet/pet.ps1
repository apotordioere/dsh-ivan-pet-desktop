param(
  [string]$Assets = (Join-Path $PSScriptRoot 'assets'),
  [int]$Width = 150,
  [int]$Height = 282,
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
$script:Base = $null
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
$win.Left = $left
$win.Top = $top

function Save-Pos {
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path $script:PosFile) | Out-Null
    @{ left = [math]::Round($win.Left); top = [math]::Round($win.Top) } | ConvertTo-Json | Set-Content -Path $script:PosFile -Encoding UTF8
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
$breathe = New-Object System.Windows.Media.Animation.DoubleAnimation
$breathe.From = 0
$breathe.To = -4
$breathe.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(2.6))
$breathe.AutoReverse = $true
$breathe.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
$breathe.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
$move.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $breathe)

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
$toast.Width = 300
$toast.Height = 96

$border = New-Object System.Windows.Controls.Border
$border.CornerRadius = New-Object System.Windows.CornerRadius(14)
$border.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(250, 255, 255, 255))
$border.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(34, 14, 23, 41))
$border.BorderThickness = New-Object System.Windows.Thickness(1)
$border.Padding = New-Object System.Windows.Thickness(14, 12, 14, 12)
try {
  $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
  $shadow.BlurRadius = 20
  $shadow.ShadowDepth = 2
  $shadow.Direction = 270
  $shadow.Opacity = 0.20
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
$tbSub = New-Object System.Windows.Controls.TextBlock
$tbSub.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
$tbSub.FontSize = 11
$tbSub.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(107, 122, 147))
$tbSub.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
$tbSub.Text = '点这里回去看看'
$stack.Children.Add($tbTitle) | Out-Null
$stack.Children.Add($tbSub) | Out-Null
$border.Child = $stack
$toast.Content = $border

function Show-Toast([string]$title, [string]$sub, [int]$seconds = 6) {
  $tbTitle.Text = $title
  $tbSub.Text = $sub
  # 贴在桌宠左侧，别挡住人
  $left = $win.Left - $toast.Width - 14
  if ($left -lt 10) { $left = $win.Left + $win.Width + 14 }
  $toast.Left = $left
  $toast.Top = $win.Top + 26
  if (-not $toast.IsVisible) { $toast.Show() }
  $script:ToastUntil = [DateTime]::Now.AddSeconds($seconds)
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

# ---------- 交互 ----------
$script:pressPoint = $null
$img.Add_MouseLeftButtonDown({
    $script:pressPoint = [System.Windows.Forms.Cursor]::Position
    try { $win.DragMove() } catch { }
    $now = [System.Windows.Forms.Cursor]::Position
    $dx = [math]::Abs($now.X - $script:pressPoint.X)
    $dy = [math]::Abs($now.Y - $script:pressPoint.Y)
    if ($dx -lt 5 -and $dy -lt 5) {
      $script:PatUntil = [DateTime]::Now.AddMilliseconds(900)
      Squash
    }
    Save-Pos
  })

$win.Add_MouseRightButtonUp({ Focus-Dsh })

$toast.Add_MouseLeftButtonUp({ Focus-Dsh; $toast.Hide(); $script:ToastUntil = [DateTime]::MinValue })

# ---------- 状态轮询（UI 线程，localhost 够快） ----------
$poll = New-Object System.Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromMilliseconds(900)
$poll.Add_Tick({
    if (-not $script:Base) {
      $script:Base = Find-Base
      if (-not $script:Base) { return }
      Write-Log "base=$($script:Base)"
    }
    try {
      $r = Invoke-RestMethod -Uri "$($script:Base)/ivan-pet/state" -TimeoutSec 1
      if ($r -and $r.state) { $script:LatestState = [string]$r.state }
    } catch {
      $script:Base = $null
    }
  })

# ---------- 画面刷新 ----------
$ui = New-Object System.Windows.Threading.DispatcherTimer
$ui.Interval = [TimeSpan]::FromMilliseconds(120)
$ui.Add_Tick({
    $st = $script:LatestState

    if ($st -ne $script:LastState) {
      $prev = $script:LastState
      $script:LastState = $st
      Write-Log "state $prev -> $st"
      if ($st -eq 'done') {
        Show-Toast '任务好了' '点这里回去看看'
        [System.Media.SystemSounds]::Asterisk.Play()
        Hop
      } elseif ($st -eq 'error') {
        Show-Toast '出错了' '点这里回去看看'
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
  })

$win.Add_Closed({
    $poll.Stop(); $ui.Stop()
    [System.Windows.Application]::Current.Shutdown()
  })

Write-Log 'window creating'
$win.Show()
Write-Log 'window shown'
$poll.Start()
$ui.Start()

if ($DemoToast) { Show-Toast '任务好了' '点这里回去看看' }

$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$app.add_DispatcherUnhandledException({
  param($sender, $e)
  Write-Log ("UI error: " + $e.Exception.Message)
  $e.Handled = $true
})
$app.Run($win) | Out-Null
