param(
  [string]$Assets = (Join-Path $PSScriptRoot 'assets'),
  [int]$Width = 150,
  [int]$Height = 282,
  [string]$Base = '',
  [switch]$DemoToast,
  [string]$DemoTitle = '',
  [switch]$DemoChatter
)

# 桌面常驻版 Ivan：独立置顶透明窗口，DSH 最小化也看得见；轮询宿主状态换动作；任务完成弹提示。
$ErrorActionPreference = 'Stop'

# ── 单实例守卫 ──────────────────────────────────────────────────────────────
# 必须在 Add-Type 加载大程序集（3-5 秒）之前！否则并发进程都能越过这段。
# 策略：独占式打开同一个锁文件；第二个进程打不开就立刻退出（仅更新 base.txt）。
$script:_lockPath = Join-Path $env:APPDATA 'ivan-pet-desktop\pet.lock'
New-Item -ItemType Directory -Force -Path (Split-Path $script:_lockPath) | Out-Null
try {
    $script:_lockStream = [IO.File]::Open(
        $script:_lockPath,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None)
} catch {
    # 锁被另一个实例持有 → 仅写 base.txt 让窗口重连，然后退出
    $baseFile = Join-Path $env:APPDATA 'ivan-pet-desktop\base.txt'
    if ($Base) {
        try { [IO.File]::WriteAllText($baseFile, $Base.TrimEnd('/'), [Text.Encoding]::UTF8) } catch {}
    }
    exit 0
}
# 锁拿到后才登记真实桌宠 PID，避免宿主把“启动器 powershell”误写进共享 pid 文件。
$script:_pidPath = Join-Path $env:APPDATA 'ivan-pet-desktop\pet.pid'
try {
    [IO.File]::WriteAllText($script:_pidPath, [string]$PID, [Text.Encoding]::UTF8)
} catch { }
# ─────────────────────────────────────────────────────────────────────────────

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
$script:Outfit = 'default'
$script:OutfitFile = Join-Path $env:APPDATA 'ivan-pet\outfit.json'
$script:BlinkUntil = [DateTime]::MinValue
$script:NextBlink = [DateTime]::Now.AddSeconds(4)
$script:ExprUntil = [DateTime]::MinValue
$script:ExprName = 'laugh'
$script:NextExpr = [DateTime]::Now.AddSeconds(10)
$script:PoseUntil = [DateTime]::MinValue
$script:PoseName = 'stretch'
$script:NextPose = [DateTime]::Now.AddSeconds(25)
$script:MotionKey = ''
$script:MotionGeneration = 0
$script:CurrentFrame = 'idle'
$script:SpecialKind = ''
$script:SpecialUntil = [DateTime]::MinValue
$script:SpecialStarted = $false
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
$tilt = New-Object System.Windows.Media.RotateTransform(0)
$tg = New-Object System.Windows.Media.TransformGroup
$tg.Children.Add($scale) | Out-Null
$tg.Children.Add($tilt) | Out-Null
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
# 特殊动作没有专属 PNG 时，先在同一套衣服里找最接近的基础动作，绝不把默认衣服贴到其它服装上。
$script:OutfitActionAliases = @{
  pajama = @{ pose_stretch = 'thinking'; pose_wave = 'pat'; pose_lookback = 'thinking'; pose_play_tail = 'pat'; expr_laugh = 'done'; expr_shy = 'thinking'; expr_sleepy = 'idle' }
  winter = @{ pose_stretch = 'thinking'; pose_wave = 'pat'; pose_lookback = 'thinking'; pose_play_tail = 'pat'; expr_laugh = 'done'; expr_shy = 'thinking'; expr_sleepy = 'idle' }
  sailor = @{ pose_stretch = 'idle'; pose_wave = 'idle'; pose_lookback = 'idle'; pose_play_tail = 'idle'; expr_laugh = 'idle'; expr_shy = 'idle'; expr_sleepy = 'idle' }
  yukata = @{ pose_stretch = 'idle'; pose_wave = 'idle'; pose_lookback = 'idle'; pose_play_tail = 'idle'; expr_laugh = 'idle'; expr_shy = 'idle'; expr_sleepy = 'idle' }
  street = @{ pose_stretch = 'idle'; pose_wave = 'idle'; pose_lookback = 'idle'; pose_play_tail = 'idle'; expr_laugh = 'idle'; expr_shy = 'idle'; expr_sleepy = 'idle' }
  suit = @{ pose_stretch = 'idle'; pose_wave = 'idle'; pose_lookback = 'idle'; pose_play_tail = 'idle'; expr_laugh = 'idle'; expr_shy = 'idle'; expr_sleepy = 'idle' }
  uniform = @{ pose_stretch = 'idle'; pose_wave = 'idle'; pose_lookback = 'idle'; pose_play_tail = 'idle'; expr_laugh = 'idle'; expr_shy = 'idle'; expr_sleepy = 'idle' }
}
function Get-ActionAlias([string]$name) {
  try {
    if ($script:OutfitActionAliases.ContainsKey($script:Outfit) -and $script:OutfitActionAliases[$script:Outfit].ContainsKey($name)) {
      return [string]$script:OutfitActionAliases[$script:Outfit][$name]
    }
  } catch { }
  return $name
}
function Get-Sprite([string]$name) {
  $key = "$($script:Outfit)/$name"
  if (-not $script:Cache.ContainsKey($key)) {
    $path = $null
    if ($script:Outfit -eq 'default') {
      $path = Join-Path $script:Assets "$name.png"
    } else {
      $outfitDir = Join-Path $script:Assets (Join-Path 'outfits' $script:Outfit)
      $path = Join-Path $outfitDir "$name.png"
      if (-not (Test-Path $path)) {
        $alias = Get-ActionAlias $name
        if ($alias -ne $name) { $path = Join-Path $outfitDir "$alias.png" }
      }
      # 普通状态优先回落到该服装自己的 idle，保持衣服一致；只有缺整套服装时才用默认 idle。
      if (-not (Test-Path $path)) { $path = Join-Path $outfitDir 'idle.png' }
      if (-not (Test-Path $path)) { $path = Join-Path $script:Assets "$name.png" }
    }
    if (-not (Test-Path $path)) { $path = Join-Path $script:Assets 'idle.png' }
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.UriSource = New-Object System.Uri($path)
    $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.EndInit()
    $bmp.Freeze()
    $script:Cache[$key] = $bmp
  }
  return $script:Cache[$key]
}

function Save-Outfit {
  try {
    $dir = Split-Path $script:OutfitFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $obj = @{ name = $script:Outfit } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($script:OutfitFile, $obj, [Text.UTF8Encoding]::new($false))
  } catch { }
}

function Set-Outfit([string]$name) {
  if (-not $name) { $name = 'default' }
  $allowed = @('default','pajama','winter','uniform','sailor','yukata','street','suit')
  if ($allowed -notcontains $name) {
    Write-Log "unknown outfit '$name', fallback=default"
    $name = 'default'
  }
  $script:Outfit = $name
  $script:Cache = @{}
  try { Set-Frame $script:CurrentFrame } catch { try { Set-Frame $script:LatestState } catch { } }
  Save-Outfit
  Write-Log "outfit=$name"
}

# ---------- 界面背景主题 & 桌面壁纸 ----------
$script:UIThemeFile = Join-Path $env:APPDATA 'ivan-pet-desktop\ui-theme.json'
$script:WallpaperThemeFile = Join-Path $env:APPDATA 'ivan-pet-desktop\theme.json'
$script:ThemeDir = Join-Path $Assets 'theme'
$script:UIThemeName = ''
$script:WallpaperThemeName = ''

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class PetWall {
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern bool SystemParametersInfo(int action, int param, string value, int winIni);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern bool SystemParametersInfo(int action, int param, StringBuilder value, int winIni);
}
"@ -ErrorAction SilentlyContinue

function Get-CurrentWallpaper {
  try {
    $sb = New-Object System.Text.StringBuilder 1024
    if ([PetWall]::SystemParametersInfo(0x0073, 1024, $sb, 0)) { return $sb.ToString() }
  } catch { }
  return ''
}

function Read-WallpaperState {
  try {
    if (Test-Path $script:WallpaperThemeFile) {
      return (Get-Content $script:WallpaperThemeFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
  } catch { }
  return $null
}

function Save-WallpaperState($name, $previous) {
  try {
    $obj = @{ name = $name; previous = $previous; at = (Get-Date).ToString('s') }
    [IO.File]::WriteAllText($script:WallpaperThemeFile, ($obj | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
  } catch { }
}

function Read-UIThemeState {
  try {
    if (Test-Path $script:UIThemeFile) {
      return (Get-Content $script:UIThemeFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
  } catch { }
  return $null
}

function Save-UIThemeState($name) {
  try {
    $obj = @{ name = $name; at = (Get-Date).ToString('s') }
    $dir = Split-Path $script:UIThemeFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($script:UIThemeFile, ($obj | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
  } catch { }
}

function Set-UITheme([string]$name) {
  $img = Join-Path $script:ThemeDir ($name + '.jpg')
  if (-not (Test-Path $img)) { Write-Log "ui theme missing: $name"; return $false }
  $script:UIThemeName = $name
  Save-UIThemeState $name
  Write-Log "ui theme -> $name"
  Show-Toast '界面背景已切换' '刷新页面（F5）才看得到' 6
  return $true
}

function Set-WallpaperTheme([string]$name, [switch]$Quiet) {
  $img = Join-Path $script:ThemeDir ($name + '.jpg')
  if (-not (Test-Path $img)) { if (-not $Quiet) { Write-Log "wallpaper theme missing: $name" }; return $false }
  $state = Read-WallpaperState
  $prev = ''
  if ($state -and $state.previous) { $prev = $state.previous } else { $prev = Get-CurrentWallpaper }
  $ok = $false
  try { $ok = [PetWall]::SystemParametersInfo(0x0014, 0, $img, 0x01 -bor 0x02) } catch { }
  if ($ok) {
    $script:WallpaperThemeName = $name
    Save-WallpaperState $name $prev
    Write-Log "wallpaper -> $name"
  }
  return $ok
}

function Restore-Wallpaper {
  $state = Read-WallpaperState
  if (-not $state -or -not $state.previous) { Write-Log 'no previous wallpaper'; return }
  $prev = [string]$state.previous
  if ($prev -and (Test-Path $prev)) {
    try { [void][PetWall]::SystemParametersInfo(0x0014, 0, $prev, 0x01 -bor 0x02) } catch { }
    Write-Log "wallpaper restored"
  } else {
    Write-Log "previous wallpaper gone: $prev"
  }
  $script:WallpaperThemeName = ''
  Save-WallpaperState '' ''
}

function Sync-UIThemeMenu {
  try {
    foreach ($k in $script:UIThemeItems.Keys) { $script:UIThemeItems[$k].Checked = ($script:UIThemeName -eq $k) }
  } catch { }
}

function Sync-WallpaperThemeMenu {
  try {
    foreach ($k in $script:WallpaperThemeItems.Keys) { $script:WallpaperThemeItems[$k].Checked = ($script:WallpaperThemeName -eq $k) }
  } catch { }
}

function Load-UITheme {
  $state = Read-UIThemeState
  if ($state -and $state.name) {
    $script:UIThemeName = [string]$state.name
  }
}

function Load-WallpaperTheme {
  $state = Read-WallpaperState
  if ($state -and $state.name) {
    $script:WallpaperThemeName = [string]$state.name
    Set-WallpaperTheme $script:WallpaperThemeName -Quiet | Out-Null
  }
}

function Load-Outfit {
  try {
    Write-Log "outfit file: $($script:OutfitFile) exists=$(Test-Path $script:OutfitFile)"
    if (Test-Path $script:OutfitFile) {
      $obj = Get-Content $script:OutfitFile -Raw | ConvertFrom-Json
      if ($obj.name) { $script:Outfit = [string]$obj.name }
    }
    $allowed = @('default','pajama','winter','uniform','sailor','yukata','street','suit')
    if ($allowed -notcontains $script:Outfit) { $script:Outfit = 'default' }
    Write-Log "outfit loaded: $($script:Outfit)"
  } catch {
    Write-Log "outfit load failed: $($_.Exception.Message)"
  }
}

function Set-Frame([string]$name) {
  if (-not $name) { $name = 'idle' }
  $script:CurrentFrame = $name
  $s = Get-Sprite $name
  if (-not [object]::ReferenceEquals($img.Source, $s)) { $img.Source = $s }
}

# ---------- 动画 ----------
function Start-Breathe([switch]$KeepKey) {
  $script:MotionGeneration++
  $script:SpecialKind = ''
  $script:SpecialUntil = [DateTime]::MinValue
  $script:SpecialStarted = $false
  if (-not $KeepKey) { $script:MotionKey = 'base' }
  $breathe = New-Object System.Windows.Media.Animation.DoubleAnimation
  $breathe.From = 0
  $breathe.To = -4
  $breathe.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(2.6))
  $breathe.AutoReverse = $true
  $breathe.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $breathe.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
  $move.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $breathe)
  $sway = New-Object System.Windows.Media.Animation.DoubleAnimation
  $sway.From = -1.6
  $sway.To = 1.6
  $sway.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(3.8))
  $sway.AutoReverse = $true
  $sway.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $sway.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
  $move.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $sway)
  $rock = New-Object System.Windows.Media.Animation.DoubleAnimation
  $rock.From = -1.1
  $rock.To = 1.1
  $rock.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(4.8))
  $rock.AutoReverse = $true
  $rock.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $rock.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
  $tilt.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $rock)
  # 很轻的缩放呼吸：让站立帧不是一张静态纸片
  $sx = New-Object System.Windows.Media.Animation.DoubleAnimation
  $sx.From = 0.996; $sx.To = 1.004
  $sx.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(3.2))
  $sx.AutoReverse = $true
  $sx.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $sx.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
  $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $sx)
  $sy = New-Object System.Windows.Media.Animation.DoubleAnimation
  $sy.From = 1.0; $sy.To = 1.008
  $sy.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(3.2))
  $sy.AutoReverse = $true
  $sy.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $sy.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
  $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $sy)
}

function Start-ActionMotion([string]$name) {
  if (-not $name) { $name = 'idle' }
  if ($script:MotionKey -eq $name) { return }
  $script:MotionKey = $name
  if ($name -eq 'idle' -or $name -eq 'speaking' -or $name -eq 'coding' -or $name -eq 'thinking' -or $name -eq 'done' -or $name -eq 'error' -or $name -eq 'pat' -or $name -eq 'blink') {
    Start-Breathe -KeepKey
    return
  }
  $xTo = 0.0; $angleTo = 0.0; $dur = 0.9
  switch -Regex ($name) {
    'pose_wave'      { $xTo = 4.0;  $angleTo = 2.6; $dur = 0.55; break }
    'pose_play_tail' { $xTo = -3.0; $angleTo = -2.2; $dur = 0.7; break }
    'pose_lookback'  { $xTo = 2.0;  $angleTo = 4.0; $dur = 0.8; break }
    'pose_stretch'   { $xTo = 0.0;  $angleTo = -1.8; $dur = 1.0; break }
    'expr_laugh'     { $xTo = 1.5;  $angleTo = 1.5; $dur = 0.45; break }
    'expr_shy'       { $xTo = -1.2; $angleTo = -2.0; $dur = 0.8; break }
    'expr_sleepy'    { $xTo = 0.5;  $angleTo = -3.0; $dur = 1.2; break }
    default          { Start-Breathe -KeepKey; return }
  }
  $sway = New-Object System.Windows.Media.Animation.DoubleAnimation
  $sway.From = -$xTo; $sway.To = $xTo
  $sway.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds($dur))
  $sway.AutoReverse = $true
  $sway.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $sway.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
  $move.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $sway)
  $rock = New-Object System.Windows.Media.Animation.DoubleAnimation
  $rock.From = -$angleTo; $rock.To = $angleTo
  $rock.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds($dur * 1.35))
  $rock.AutoReverse = $true
  $rock.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $rock.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
  $tilt.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $rock)
}
Start-Breathe

function Hop {
  $script:SpecialKind = 'hop'
  $script:SpecialUntil = [DateTime]::Now.AddMilliseconds(420)
  $script:SpecialStarted = $true
  $y = New-Object System.Windows.Media.Animation.DoubleAnimation
  $y.From = 0; $y.To = -20
  $y.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(200))
  $y.AutoReverse = $true
  $y.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
  $move.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $y)
}

function Squash {
  $script:SpecialKind = 'squash'
  $script:SpecialUntil = [DateTime]::Now.AddMilliseconds(280)
  $script:SpecialStarted = $true
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

function Shake {
  # 出错时给一个短促的左右晃动，比静态红气泡更有反馈
  $script:SpecialKind = 'shake'
  $script:SpecialUntil = [DateTime]::Now.AddMilliseconds(380)
  $script:SpecialStarted = $true
  $j = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
  $j.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(360))
  $j.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
  foreach ($pair in @(@(-2,0), @(2,60), @(-2,120), @(2,180), @(0,360))) {
    $kf = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame
    $kf.Value = [double]$pair[0]
    $kf.KeyTime = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds([double]$pair[1]))
    $kf.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
    [void]$j.KeyFrames.Add($kf)
  }
  $move.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $j)
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
  # 靠屏幕右边时把气泡整体推回工作区，避免长标题被裁掉
  $wa = [System.Windows.SystemParameters]::WorkArea
  $toast.MaxWidth = 380
  if ($left + $tw -gt ($wa.Right - 8)) { $left = $wa.Right - $tw - 8 }
  if ($left -lt ($wa.Left + 8)) { $left = $wa.Left + 8 }
  if ($top + $th -gt ($wa.Bottom - 8)) { $top = $wa.Bottom - $th - 8 }
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
# 完成气泡：第一行是这一轮的任务名（宿主 /ivan-pet/last-done），第二行一句短台词；接口不通就只给台词
function Get-LastDoneTitle {
  if ($DemoTitle) { return $DemoTitle }
  if (-not $script:Base) { return $null }
  try {
    $r = Invoke-RestMethod -Uri "$($script:Base)/ivan-pet/last-done" -TimeoutSec 1 -ErrorAction Stop
    if ($r -and $r.ok -and $r.title) { return [string]$r.title }
  } catch { }
  return $null
}
function Show-Bubble-TaskDone {
  $line = $script:doneLines | Get-Random
  $name = Get-LastDoneTitle
  if ($name) { Show-Toast $name $line 8 } else { Show-Toast $line '' 7 }
}
# 回到最近的会话：这一代 DSH 没有会话级深链（dsh:// 只认 dsh://open），只能把主窗口拉到前台
function Open-LastSession { Focus-Dsh }
function Show-Bubble-TaskError {
  Show-Toast ($script:errLines | Get-Random) '' 8
}

# ---------- 人设联动：从 whale-persona 配置里读称呼 ----------
$script:PersonaFile = Join-Path $env:APPDATA 'ivan-pet-desktop\persona.json'
$script:PersonaFileFallback = Join-Path $env:USERPROFILE '.dsh\whale-persona\config.json'
$script:PersonaStamp = ''
$script:UserName = '哥'
$script:SelfName = '我'
function Update-PersonaNames {
  try {
    # 先读新路径
    if (Test-Path $script:PersonaFile) {
      $st = Get-Item $script:PersonaFile -ErrorAction Stop
      $key = "$($st.LastWriteTimeUtc.Ticks)/$($st.Length)"
      if ($key -ne $script:PersonaStamp) {
        $cfg = [IO.File]::ReadAllText($script:PersonaFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($cfg.userName) { $script:UserName = [string]$cfg.userName }
        if ($cfg.selfName) { $script:SelfName = [string]$cfg.selfName }
        $script:PersonaStamp = $key
      }
      return
    }
    
    # 回落到旧路径
    if (Test-Path $script:PersonaFileFallback) {
      $st = Get-Item $script:PersonaFileFallback -ErrorAction Stop
      $key = "$($st.LastWriteTimeUtc.Ticks)/$($st.Length)"
      if ($key -ne $script:PersonaStamp) {
        $cfg = [IO.File]::ReadAllText($script:PersonaFileFallback, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($cfg.persona.userName) { $script:UserName = [string]$cfg.persona.userName }
        if ($cfg.persona.selfNameFlash) { $script:SelfName = [string]$cfg.persona.selfNameFlash }
        $script:PersonaStamp = $key
      }
    }
  } catch { }
}

# ---------- 碎碎念 ----------
$script:chatterLines = @(
  '{u}，水喝了没有。',
  '屏幕这么亮，眼睛不酸吗。',
  '别老坐着。',
  '尾巴压麻了。',
  '窗外那只鸟又来了，站半天了。',
  '你这键盘声，比你说话还密。',
  '……有事就叫我。',
  '刚才那步其实还能再快点。',
  '我在这儿。',
  '别熬太晚。',
  '这块屏看久了会花。',
  '杯子快碰着我了。',
  '今天还剩多少事，你心里有数吧。',
  '冷气开太低了。',
  '腰挺直。',
  '我不困，是你在打哈欠。'
)
$script:chatBroke = @(
  '余额见底了{u}，别乱花。',
  '再这么下去要停机了。',
  '钱不够了，你看着办。'
)
$script:ChatterOn = $true
$script:ChatterBroke = $false
$script:NextChatter = [DateTime]::Now.AddSeconds(45 + (Get-Random -Minimum 0 -Maximum 60))

function Show-Chatter {
  Update-PersonaNames
  $pool = $script:chatterLines
  if ($script:ChatterBroke) { $pool = $script:chatBroke }
  $line = ($pool | Get-Random)
  $line = $line.Replace('{u}', $script:UserName)
  Show-Toast $line '' 5
  Write-Log "chatter: $line"
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

# ---------- 余额牌（DeepSeek 官方 + 中转站已用） ----------
Add-Type -AssemblyName System.Net.Http | Out-Null
$script:http = New-Object System.Net.Http.HttpClient
$script:http.Timeout = [TimeSpan]::FromSeconds(20)
$script:balTask = $null
$script:balAt = [DateTime]::MinValue

$balPanel = New-Object System.Windows.Controls.Border
$balPanel.CornerRadius = New-Object System.Windows.CornerRadius 8
$balPanel.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(216, 255, 255, 255))
$balPanel.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(44, 27, 42, 74))
$balPanel.BorderThickness = New-Object System.Windows.Thickness 1
$balPanel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
$balPanel.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
$balPanel.Margin = New-Object System.Windows.Thickness(0, 0, 0, 3)
$balPanel.Padding = New-Object System.Windows.Thickness(8, 2, 8, 3)
$balPanel.IsHitTestVisible = $false

$balStack = New-Object System.Windows.Controls.StackPanel
$balStack.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center

$balLine1 = New-Object System.Windows.Controls.TextBlock
$balLine1.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
$balLine1.FontSize = 9.5
$balLine1.TextAlignment = [System.Windows.TextAlignment]::Center
$balLine1.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(27, 42, 74))
$balLine1.Text = 'DeepSeek —'

$balLine2 = New-Object System.Windows.Controls.TextBlock
$balLine2.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei')
$balLine2.FontSize = 8.5
$balLine2.TextAlignment = [System.Windows.TextAlignment]::Center
$balLine2.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(124, 136, 160))
$balLine2.Text = '中转 —'
$balLine2.Margin = New-Object System.Windows.Thickness(0, 1, 0, 0)

$balStack.Children.Add($balLine1) | Out-Null
$balStack.Children.Add($balLine2) | Out-Null
$balPanel.Child = $balStack
$grid.Children.Add($balPanel) | Out-Null

function Show-Balance($obj) {
  try {
    if ($obj.deepseek -and $obj.deepseek.ok) {
      $cur = if ($obj.deepseek.currency -eq 'CNY') { '¥' } else { [string]$obj.deepseek.currency }
      $money = [double]$obj.deepseek.balance
      $balLine1.Text = ('DeepSeek {0}{1:N2}' -f $cur, $money)
      if ($money -lt 10) {
        $balLine1.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(163, 42, 34))
      } else {
        $balLine1.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(27, 42, 74))
      }
    } elseif ($obj.deepseek) {
      $balLine1.Text = 'DeepSeek 读不到'
    }
    if ($obj.relay) {
      if ($obj.relay.balance) {
        $balLine2.Text = ('中转余额 ${0:N2}' -f [double]$obj.relay.balance.balanceUsd)
      } elseif ($obj.relay.hasToken) {
        $balLine2.Text = '中转余额 读不到'
      } else {
        $balLine2.Text = '中转余额 未配置'
      }
      $used = [double]$obj.relay.totalUsed
      $balPanel.ToolTip = ('中转已用 ${0:N2}' -f $used)
    }
    if ($script:tray) {
      try { $script:tray.Text = "Ivan · " + $balLine1.Text + " · " + $balLine2.Text } catch { }
    }
  } catch { }
}

function Update-Balance([bool]$force) {
  if (-not $script:Base) { return }
  if ($script:balTask -ne $null) { return }
  $url = "$($script:Base)/ivan-pet/balance"
  if ($force) { $url += '?force=1' }
  try {
    $script:balTask = $script:http.GetStringAsync($url)
    $script:balAt = [DateTime]::Now
  } catch { $script:balTask = $null }
}
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

$toast.Add_MouseLeftButtonUp({ Open-LastSession; $toast.Hide(); $script:ToastUntil = [DateTime]::MinValue })

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
      try { Update-Balance $false } catch { }
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

# ---------- 余额轮询：每分钟拉一次 ----------
$bal = New-Object System.Windows.Threading.DispatcherTimer
$bal.Interval = [TimeSpan]::FromSeconds(60)
$bal.Add_Tick({ try { Update-Balance $false } catch { } })

# ---------- 碎碎念定时器：闲着的时候隔一会儿嘟囔一句 ----------
$chatter = New-Object System.Windows.Threading.DispatcherTimer
$chatter.Interval = [TimeSpan]::FromSeconds(20)
$chatter.Add_Tick({
    try {
      if (-not $script:ChatterOn) { return }
      if ([DateTime]::Now -lt $script:NextChatter) { return }
      if ($toast.IsVisible) { $script:NextChatter = [DateTime]::Now.AddSeconds(15); return }
      $st2 = $script:LatestState
      if ($st2 -ne 'idle' -and $st2 -ne 'speaking') { $script:NextChatter = [DateTime]::Now.AddSeconds(20); return }
      if ($win.Visibility -ne [System.Windows.Visibility]::Visible) { $script:NextChatter = [DateTime]::Now.AddSeconds(60); return }
      Show-Chatter
      $script:NextChatter = [DateTime]::Now.AddSeconds(75 + (Get-Random -Minimum 0 -Maximum 120))
    } catch { }
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

    $specialMotion = ''
    if ($st -ne $script:LastState) {
      $prev = $script:LastState
      $script:LastState = $st
      Write-Log "state $prev -> $st"
      if ($st -eq 'done') {
        Show-Bubble-TaskDone
        [System.Media.SystemSounds]::Asterisk.Play()
        $specialMotion = 'hop'
      } elseif ($st -eq 'error') {
        Show-Bubble-TaskError
        [System.Media.SystemSounds]::Hand.Play()
        $specialMotion = 'shake'
      } elseif ($st -eq 'pat') {
        $specialMotion = 'squash'
      }
    }

    $show = $st
    if (($st -eq 'idle' -or $st -eq 'speaking') -and [DateTime]::Now -lt $script:PatUntil) { $show = 'pat' }
    if (($st -eq 'idle' -or $st -eq 'speaking') -and [DateTime]::Now -ge $script:PatUntil) {
      $poseActive = ([DateTime]::Now -lt $script:PoseUntil)
      $exprActive = ([DateTime]::Now -lt $script:ExprUntil)
      $toastUp = ($script:ToastUntil -ne [DateTime]::MinValue)
      if (-not $poseActive -and -not $exprActive -and [DateTime]::Now -ge $script:NextExpr) {
        $script:ExprName = Get-Random -InputObject @('laugh', 'shy', 'sleepy')
        $script:ExprUntil = [DateTime]::Now.AddMilliseconds(1900)
        $script:NextExpr = [DateTime]::Now.AddSeconds(18 + (Get-Random -Minimum 0 -Maximum 32))
        $exprActive = $true
      }
      if (-not $toastUp -and -not $exprActive -and [DateTime]::Now -ge $script:NextPose) {
        $script:PoseName = Get-Random -InputObject @('stretch', 'wave', 'lookback', 'play_tail')
        $script:PoseUntil = [DateTime]::Now.AddMilliseconds(2600 + (Get-Random -Minimum 0 -Maximum 1000))
        $script:NextPose = [DateTime]::Now.AddSeconds(28 + (Get-Random -Minimum 0 -Maximum 45))
      }
      # 动作优先级：姿势 > 表情 > 眨眼；动作期间不让眨眼贴图把动作帧盖掉。
      $poseActive = ([DateTime]::Now -lt $script:PoseUntil)
      $exprActive = ([DateTime]::Now -lt $script:ExprUntil)
      if (-not $poseActive -and -not $exprActive -and [DateTime]::Now -ge $script:NextBlink) {
        $script:BlinkUntil = [DateTime]::Now.AddMilliseconds(110)
        $script:NextBlink = [DateTime]::Now.AddSeconds(3 + (Get-Random -Minimum 0 -Maximum 35) / 10)
      }
      if ($poseActive) {
        $show = 'pose_' + $script:PoseName
      } elseif ($exprActive) {
        $show = 'expr_' + $script:ExprName
      } elseif ([DateTime]::Now -lt $script:BlinkUntil) {
        $show = 'blink'
      }
    }
    # 贴图之外再给窗口一层低成本程序动作。特殊动作期间不重写同一变换通道，避免下一 tick 截断跳跃/抖动/压缩。
    $specialActive = ($script:SpecialStarted -and [DateTime]::Now -lt $script:SpecialUntil)
    if (-not $specialActive) {
      if ($script:SpecialStarted) {
        $script:SpecialStarted = $false
        $script:SpecialKind = ''
        try { Start-Breathe } catch { }
      }
      try { Start-ActionMotion $show } catch { }
    }
    if ($specialMotion -eq 'hop') { try { Hop } catch { } }
    elseif ($specialMotion -eq 'shake') { try { Shake } catch { } }
    elseif ($specialMotion -eq 'squash') { try { Squash } catch { } }
    Set-Frame $show

    if ($script:ToastUntil -ne [DateTime]::MinValue -and [DateTime]::Now -gt $script:ToastUntil) {
      $toast.Hide()
      $script:ToastUntil = [DateTime]::MinValue
    }

    # 余额：等上一次请求回来
    if ($script:balTask -ne $null -and $script:balTask.IsCompleted) {
      $task = $script:balTask
      $script:balTask = $null
      try {
        $obj = $task.Result | ConvertFrom-Json
        Show-Balance $obj
      } catch { }
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

$miRefresh = New-Object System.Windows.Forms.ToolStripMenuItem
$miRefresh.Text = '刷新余额'
$trayMenu.Items.Add($miRefresh) | Out-Null

$miOutfit = New-Object System.Windows.Forms.ToolStripMenuItem
$miOutfit.Text = '换衣服'
$script:OutfitTable = @(
  @{ id = 'default'; label = '日常（默认）' },
  @{ id = 'pajama';  label = '睡衣' },
  @{ id = 'winter';  label = '冬装' },
  @{ id = 'uniform'; label = '学院' },
  @{ id = 'sailor';  label = '水手' },
  @{ id = 'yukata';  label = '浴衣' },
  @{ id = 'street';  label = '街头' },
  @{ id = 'suit';    label = '西装' }
)
$script:OutfitItems = @{}
foreach ($entry in $script:OutfitTable) {
  $miOne = New-Object System.Windows.Forms.ToolStripMenuItem
  $miOne.Text = [string]$entry.label
  $miOne.Tag = [string]$entry.id
  $miOne.Add_Click({ param($sender, $e) try { Set-Outfit ([string]$sender.Tag); Sync-OutfitMenu } catch { } })
  $miOutfit.DropDownItems.Add($miOne) | Out-Null
  $script:OutfitItems[[string]$entry.id] = $miOne
}
$trayMenu.Items.Add($miOutfit) | Out-Null

$miSay = New-Object System.Windows.Forms.ToolStripMenuItem
$miSay.Text = '让他说句话'
$trayMenu.Items.Add($miSay) | Out-Null

$miChatter = New-Object System.Windows.Forms.ToolStripMenuItem
$miChatter.Text = '碎碎念：开'
$trayMenu.Items.Add($miChatter) | Out-Null

$miUITheme = New-Object System.Windows.Forms.ToolStripMenuItem
$miUITheme.Text = '界面背景'
$script:UIThemeItems = @{}
foreach ($t in @(
    @{ name = 'night';  text = '夜（屏幕冷光）' },
    @{ name = 'window'; text = '窗（下午逆光）' },
    @{ name = 'water';  text = '水（下沉的蓝）' },
    @{ name = 'rain';   text = '雨（隔窗）' }
  )) {
  $item = New-Object System.Windows.Forms.ToolStripMenuItem
  $item.Text = $t.text
  $item.Tag = $t.name
  $item.Add_Click({ param($sender, $e) try { Set-UITheme $sender.Tag; Sync-UIThemeMenu } catch { } })
  $miUITheme.DropDownItems.Add($item) | Out-Null
  $script:UIThemeItems[$t.name] = $item
}
$trayMenu.Items.Add($miUITheme) | Out-Null

$miWallpaper = New-Object System.Windows.Forms.ToolStripMenuItem
$miWallpaper.Text = '桌面壁纸'
$script:WallpaperThemeItems = @{}
foreach ($t in @(
    @{ name = 'night';  text = '夜（屏幕冷光）' },
    @{ name = 'window'; text = '窗（下午逆光）' },
    @{ name = 'water';  text = '水（下沉的蓝）' },
    @{ name = 'rain';   text = '雨（隔窗）' }
  )) {
  $item = New-Object System.Windows.Forms.ToolStripMenuItem
  $item.Text = $t.text
  $item.Tag = $t.name
  $item.Add_Click({ param($sender, $e) try { Set-WallpaperTheme $sender.Tag; Sync-WallpaperThemeMenu } catch { } })
  $miWallpaper.DropDownItems.Add($item) | Out-Null
  $script:WallpaperThemeItems[$t.name] = $item
}
$miWallpaperRestore = New-Object System.Windows.Forms.ToolStripMenuItem
$miWallpaperRestore.Text = '恢复原壁纸'
$miWallpaperRestore.Add_Click({ try { Restore-Wallpaper; Sync-WallpaperThemeMenu } catch { } })
$miWallpaper.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miWallpaper.DropDownItems.Add($miWallpaperRestore) | Out-Null
$trayMenu.Items.Add($miWallpaper) | Out-Null

$miDsh = New-Object System.Windows.Forms.ToolStripMenuItem
$miDsh.Text = '回 DSH 看看'
$trayMenu.Items.Add($miDsh) | Out-Null

$miLastSession = New-Object System.Windows.Forms.ToolStripMenuItem
$miLastSession.Text = '回到最近的会话'
$trayMenu.Items.Add($miLastSession) | Out-Null

$miToggle = New-Object System.Windows.Forms.ToolStripMenuItem
$miToggle.Text = '收起桌宠'
$trayMenu.Items.Add($miToggle) | Out-Null

$sep = New-Object System.Windows.Forms.ToolStripSeparator
$trayMenu.Items.Add($sep) | Out-Null

$miQuit = New-Object System.Windows.Forms.ToolStripMenuItem
$miQuit.Text = '退出'
$trayMenu.Items.Add($miQuit) | Out-Null

$script:tray.ContextMenuStrip = $trayMenu

$miRefresh.Add_Click({ try { Update-Balance $true } catch { } })

function Sync-OutfitMenu {
  try {
    foreach ($k in $script:OutfitItems.Keys) {
      $script:OutfitItems[$k].Checked = ($script:Outfit -eq $k)
    }
  } catch { }
}

$miSay.Add_Click({ try { Show-Chatter } catch { } })
$miChatter.Add_Click({
    try {
      $script:ChatterOn = -not $script:ChatterOn
      if ($script:ChatterOn) { $miChatter.Text = '碎碎念：开'; $script:NextChatter = [DateTime]::Now.AddSeconds(20) }
      else { $miChatter.Text = '碎碎念：关' }
    } catch { }
  })
$miDsh.Add_Click({ Focus-Dsh })
$miLastSession.Add_Click({ Open-LastSession })
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
    try { $poll.Stop(); $ui.Stop(); $bal.Stop() } catch { }
    try { $script:http.CancelPendingRequests() } catch { }
    $script:balTask = $null
    try { $win.Close() } catch { }
    [System.Windows.Application]::Current.Shutdown()
  })

$script:tray.Add_MouseDoubleClick({ try { $win.Visibility = [System.Windows.Visibility]::Visible; $win.Activate() | Out-Null; Focus-Dsh } catch { } })
$script:tray.Visible = $true
Write-Log 'tray icon on'

$win.Add_Closed({
    $poll.Stop(); $ui.Stop(); $bal.Stop()
    try { $script:http.CancelPendingRequests() } catch { }
    $script:balTask = $null
    try { $script:tray.Visible = $false; $script:tray.Dispose() } catch { }
    [System.Windows.Application]::Current.Shutdown()
  })

Load-Outfit
Load-UITheme
Load-WallpaperTheme
Sync-UIThemeMenu
Sync-WallpaperThemeMenu
try { Sync-OutfitMenu } catch { }
Write-Log 'window creating'
$win.Show()
Write-Log 'window shown'
$poll.Start()
$ui.Start()
$bal.Start()

if ($DemoToast) { Show-Bubble-TaskDone }
if ($DemoChatter) { Show-Chatter }

$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$app.add_DispatcherUnhandledException({
  param($sender, $e)
  Write-Log ("UI error: " + $e.Exception.Message)
  $e.Handled = $true
})
$app.Run($win) | Out-Null
