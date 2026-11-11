#requires -Version 5.1
<#
  wx-send.ps1 —— 用微信桌面版把文件/图片发给指定会话（默认「文件传输助手」）

  用法:
    pwsh -NoProfile -File wx-send.ps1 -Path "C:\a\b.png"
    pwsh -NoProfile -File wx-send.ps1 -Path "a.png","b.pdf" -To "文件传输助手"
    pwsh -NoProfile -File wx-send.ps1 -Path "a.png" -NoSend       只放进输入框，不发送
    pwsh -NoProfile -File wx-send.ps1 -Path "a.png" -Force        跳过会话标题校验（有发错风险）

  输出: 一行 JSON {ok, chat, verified, sent, files, ms, error}，退出码 0 成功 / 1 失败。
  所有校验在本地完成（像素差 + 系统 OCR），不把截图丢给模型，token 消耗 ≈ 0。

  流程:
    1) 找微信主窗（必要时按快捷方式/注册表定位 exe 启动、点「进入微信」）
    2) OCR 聊天标题，判断是否已是目标会话
    3) 不是则 Ctrl+F 唤出搜索框 → 粘贴会话名 → Enter → 再次 OCR 校验
    4) 点输入框 → 剪贴板放 CF_HDROP → Ctrl+V → 像素差确认附件已进输入框
    5) Enter 发送 → 像素差确认输入框已清空

  坐标假设: 微信 4.x 在这台机器上按 1:1 物理像素渲染（120DPI 系统下实测），
  所以版面常量直接用物理像素，不做 DPI 缩放。换机器若缩放不同，见 README 的校准说明。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string[]]$Path,
    [string]$To = '文件传输助手',
    [switch]$NoSend,
    [switch]$NoVerify,
    [switch]$Force,
    [int]$TimeoutSec = 30
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$Ocr = Join-Path $PSScriptRoot 'wx-ocr.ps1'

function Finish([bool]$ok, [hashtable]$f) {
    $o = [ordered]@{ ok = $ok; chat = $null; verified = $false; sent = $false; files = @(); ms = 0; error = $null }
    foreach ($k in $f.Keys) { $o[$k] = $f[$k] }
    $o.ms = $sw.ElapsedMilliseconds
    ($o | ConvertTo-Json -Compress -Depth 5)
    if ($ok) { exit 0 } else { exit 1 }
}

# ---------------- 入参 ----------------
$files = @()
foreach ($p in $Path) {
    if (-not (Test-Path -LiteralPath $p)) { Finish $false @{ error = "文件不存在: $p" } }
    $it = Get-Item -LiteralPath $p
    if ($it.PSIsContainer) { Finish $false @{ error = "是目录不是文件: $p" } }
    $files += $it.FullName
}
if ($files.Count -eq 0) { Finish $false @{ error = '没有可发送的文件' } }

# ---------------- 互操作 ----------------
if (-not ('Wx32' -as [type])) {
    Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class Wx32 {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public static List<IntPtr> All() { var l = new List<IntPtr>(); EnumWindows((h, x) => { l.Add(h); return true; }, IntPtr.Zero); return l; }
    public static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
    public static void Click(int x, int y) {
        SetCursorPos(x, y); System.Threading.Thread.Sleep(90);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero); System.Threading.Thread.Sleep(50);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }
    public static void Key(byte vk) {
        keybd_event(vk, 0, 0, UIntPtr.Zero); System.Threading.Thread.Sleep(45);
        keybd_event(vk, 0, 2, UIntPtr.Zero);
    }
    public static void Ctrl(byte vk) {
        keybd_event(0x11, 0, 0, UIntPtr.Zero); System.Threading.Thread.Sleep(45);
        keybd_event(vk, 0, 0, UIntPtr.Zero); System.Threading.Thread.Sleep(45);
        keybd_event(vk, 0, 2, UIntPtr.Zero); System.Threading.Thread.Sleep(45);
        keybd_event(0x11, 0, 2, UIntPtr.Zero);
    }
    public static void Force(IntPtr h) {
        if (IsIconic(h)) { ShowWindow(h, 9); System.Threading.Thread.Sleep(350); }
        uint pid; uint tid = GetWindowThreadProcessId(h, out pid); uint me = GetCurrentThreadId();
        AttachThreadInput(me, tid, true); BringWindowToTop(h); SetForegroundWindow(h);
        System.Threading.Thread.Sleep(260); AttachThreadInput(me, tid, false);
    }
}
"@
}
[void][Wx32]::SetProcessDPIAware()
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# ---------------- 找微信 ----------------
function Get-WeChatExe {
    $c = New-Object System.Collections.Generic.List[string]
    $ws = $null
    try { $ws = New-Object -ComObject WScript.Shell } catch { }
    $dirs = @([Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'))
    foreach ($d in $dirs) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        Get-ChildItem -LiteralPath $d -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '微信|WeChat|Weixin' } | ForEach-Object {
            if ($ws) {
                try {
                    $t = $ws.CreateShortcut($_.FullName).TargetPath
                    if ($t -and $t -match 'Weixin\.exe|WeChat\.exe' -and (Test-Path -LiteralPath $t)) { $c.Add($t) }
                } catch { }
            }
        }
    }
    foreach ($g in @('D:\微信\Weixin\Weixin.exe', 'C:\Program Files\Tencent\Weixin\Weixin.exe',
                     'C:\Program Files (x86)\Tencent\Weixin\Weixin.exe', 'D:\Program Files\Tencent\Weixin\Weixin.exe',
                     'C:\Program Files\Tencent\WeChat\WeChat.exe', 'C:\Program Files (x86)\Tencent\WeChat\WeChat.exe')) {
        if (Test-Path -LiteralPath $g) { $c.Add($g) }
    }
    foreach ($root in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        try {
            Get-ItemProperty $root -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayIcon -and ($_.DisplayName -match '微信|WeChat|Weixin') } | ForEach-Object {
                $ic = ($_.DisplayIcon -split ',')[0].Trim('"')
                if ($ic -match '\.exe$' -and (Test-Path -LiteralPath $ic)) { $c.Add($ic) }
            }
        } catch { }
    }
    foreach ($p in $c) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

function Find-MainWindow([int]$ms) {
    $stop = $sw.ElapsedMilliseconds + $ms
    do {
        $best = $null; $bestArea = 0
        foreach ($h in [Wx32]::All()) {
            if (-not [Wx32]::IsWindowVisible($h)) { continue }
            if ([Wx32]::Cls($h) -notmatch '^Qt') { continue }
            $r = New-Object Wx32+RECT
            if (-not [Wx32]::GetWindowRect($h, [ref]$r)) { continue }
            $w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
            if ($w -lt 700 -or $hh -lt 500) { continue }
            $a = $w * $hh
            if ($a -gt $bestArea) { $bestArea = $a; $best = @{ Hwnd = $h; Rect = $r } }
        }
        if ($best) { return $best }
        Start-Sleep -Milliseconds 300
    } while ($sw.ElapsedMilliseconds -lt $stop)
    return $null
}

$win = Find-MainWindow 800
if (-not $win) {
    $exe = Get-WeChatExe
    if (-not $exe) { Finish $false @{ error = '未找到微信进程，也未定位到微信安装路径' } }
    Start-Process -FilePath $exe -ArgumentList '--scene=desktop' -WorkingDirectory (Split-Path $exe)
    Start-Sleep -Seconds 4
    $win = Find-MainWindow 12000
    if (-not $win) {
        foreach ($h in [Wx32]::All()) {
            if (-not [Wx32]::IsWindowVisible($h)) { continue }
            if ([Wx32]::Cls($h) -notmatch '^Qt') { continue }
            $r = New-Object Wx32+RECT
            if (-not [Wx32]::GetWindowRect($h, [ref]$r)) { continue }
            $w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
            if ($w -lt 200 -or $hh -lt 200 -or $w -gt 700) { continue }
            [Wx32]::Force($h)
            [Wx32]::Click([int](($r.Left + $r.Right) / 2), [int]($r.Top + $hh * 0.78))
            Start-Sleep -Seconds 5
        }
        $win = Find-MainWindow 12000
    }
    if (-not $win) { Finish $false @{ error = '微信窗口未出现（可能未登录，请手动登录后重试）' } }
}

$hwnd = $win.Hwnd; $R = $win.Rect
$L = $R.Left; $T = $R.Top; $W = $R.Right - $R.Left; $H = $R.Bottom - $R.Top

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wxsend-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function Snap([int]$x, [int]$y, [int]$w, [int]$h) {
    if ($w -lt 8) { $w = 8 }; if ($h -lt 8) { $h = 8 }
    $b = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($b)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $g.Dispose()
    return $b
}
function DiffRatio($a, $b, [int]$thr = 36) {
    if (-not $a -or -not $b) { return 1.0 }
    if ($a.Width -ne $b.Width -or $a.Height -ne $b.Height) { return 1.0 }
    $tot = 0; $dif = 0
    $sx = [math]::Max(1, [int]($a.Width / 60)); $sy = [math]::Max(1, [int]($a.Height / 30))
    for ($y = 0; $y -lt $a.Height; $y += $sy) {
        for ($x = 0; $x -lt $a.Width; $x += $sx) {
            $p = $a.GetPixel($x, $y); $q = $b.GetPixel($x, $y)
            $d = [math]::Abs($p.R - $q.R) + [math]::Abs($p.G - $q.G) + [math]::Abs($p.B - $q.B)
            $tot++
            if ($d -gt $thr) { $dif++ }
        }
    }
    if ($tot -eq 0) { return 0.0 }
    return $dif / $tot
}
function Scale-Bitmap($bmp, [double]$factor) {
    $w2 = [int]($bmp.Width * $factor); $h2 = [int]($bmp.Height * $factor)
    $big = New-Object System.Drawing.Bitmap $w2, $h2
    $g = [System.Drawing.Graphics]::FromImage($big)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($bmp, 0, 0, $w2, $h2)
    $g.Dispose()
    return $big
}
function Ocr-Bitmap($bmp, [double]$factor = 4.0) {
    if (-not (Test-Path -LiteralPath $Ocr)) { return '' }
    $big = Scale-Bitmap $bmp $factor
    $f = Join-Path $tmp ([guid]::NewGuid().ToString('N') + '.png')
    $big.Save($f, [System.Drawing.Imaging.ImageFormat]::Png)
    $big.Dispose()
    $txt = ''
    try { $txt = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Ocr $f 2>$null | Out-String) } catch { $txt = '' }
    return ($txt -replace '[\s\p{P}\p{S}]', '')
}
function Norm([string]$s) { return ($s -replace '[\s\p{P}\p{S}]', '') }
function CharScore([string]$hay, [string]$needle) {
    if (-not $hay -or -not $needle) { return 0.0 }
    $pool = @{}
    foreach ($ch in $hay.ToCharArray()) { if ($pool.ContainsKey($ch)) { $pool[$ch]++ } else { $pool[$ch] = 1 } }
    $hit = 0
    foreach ($ch in $needle.ToCharArray()) {
        if ($pool.ContainsKey($ch) -and $pool[$ch] -gt 0) { $pool[$ch]--; $hit++ }
    }
    return $hit / $needle.Length
}

# ---------------- 版面坐标（物理像素） ----------------
$headerX = $L + 380; $headerY = $T + 38; $headerW = [math]::Min(360, $W - 400); $headerH = 48
$listX = $L + 70; $listY = $T + 100; $listW = 195; $listH = 220          # 左侧会话列表顶部（搜索浮层所在区域）
$inputCropX = [int]($L + 0.36 * $W); $inputCropY = [int]($T + 0.72 * $H)
$inputCropW = [int](0.58 * $W); $inputCropH = [int](0.20 * $H)
$clickCands = @(
    @([int]($L + 0.70 * $W), [int]($T + 0.82 * $H)),
    @([int]($L + 0.62 * $W), [int]($T + 0.79 * $H)),
    @([int]($L + 0.55 * $W), [int]($T + 0.86 * $H))
)

$target = Norm $To
$scoreMin = if ($target.Length -le 3) { 1.0 } elseif ($target.Length -le 4) { 0.75 } else { 0.5 }

function Read-HeaderScore {
    $b = Snap $headerX $headerY $headerW $headerH
    try {
        $best = 0.0; $seen = ''
        foreach ($f in 4.0, 5.0, 3.0) {
            $txt = Ocr-Bitmap $b $f
            if (-not $txt) { continue }
            $s = CharScore $txt $target
            if ($s -gt $best) { $best = $s; $seen = $txt }
            if ($best -ge $scoreMin) { break }
        }
        return @{ score = $best; text = $seen }
    } finally { $b.Dispose() }
}

[Wx32]::Force($hwnd) | Out-Null
Start-Sleep -Milliseconds 350

# ---------------- 1. 是否已在目标会话 ----------------
$verified = $false; $ocrText = ''
if ($NoVerify) {
    $verified = $true
} else {
    $r = Read-HeaderScore
    $ocrText = $r.text
    if ($r.score -ge $scoreMin) { $verified = $true }
}

# ---------------- 2. Ctrl+F 搜索并打开 ----------------
if (-not $verified) {
    [Wx32]::Force($hwnd) | Out-Null
    Start-Sleep -Milliseconds 200
    $before = Snap $listX $listY $listW $listH
    [Wx32]::Ctrl(0x46)                       # Ctrl+F：唤出搜索框（不依赖鼠标坐标）
    Start-Sleep -Milliseconds 700
    Set-Clipboard -Value $To
    Start-Sleep -Milliseconds 200
    [Wx32]::Ctrl(0x41)
    Start-Sleep -Milliseconds 100
    [Wx32]::Ctrl(0x56)
    Start-Sleep -Milliseconds 1000
    $after = Snap $listX $listY $listW $listH
    $popupDiff = DiffRatio $before $after 24
    $before.Dispose(); $after.Dispose()
    if ($popupDiff -lt 0.03 -and -not $Force -and -not $NoVerify) {
        @([Wx32]::Key(0x1B)) | Out-Null        # Esc 收起搜索，别把文字留在聊天输入框里
        Finish $false @{ chat = $To; error = 'Ctrl+F 没有唤出微信搜索框（焦点可能不在微信窗口），已中止以免发错会话' }
    }
    Start-Sleep -Milliseconds 300
    [Wx32]::Key(0x0D)                        # Enter 打开第一个结果
    Start-Sleep -Milliseconds 1600
    if (-not $NoVerify) {
        $r = Read-HeaderScore
        $ocrText = $r.text
        if ($r.score -ge $scoreMin) { $verified = $true }
        if (-not $verified -and -not $Force) {
            Finish $false @{ chat = $To; ocr = $ocrText; error = "无法确认已打开会话「$To」（标题 OCR 不匹配）" }
        }
    } else { $verified = $true }
}

[Wx32]::Force($hwnd) | Out-Null
Start-Sleep -Milliseconds 250

# ---------------- 3. 剪贴板放文件 ----------------
$sc = New-Object System.Collections.Specialized.StringCollection
foreach ($f in $files) { [void]$sc.Add($f) }
try { [System.Windows.Forms.Clipboard]::SetFileDropList($sc) }
catch { Finish $false @{ chat = $To; verified = $verified; error = "写剪贴板失败: $($_.Exception.Message)" } }
Start-Sleep -Milliseconds 200
$back = [System.Windows.Forms.Clipboard]::GetFileDropList()
if ($back.Count -ne $files.Count) {
    Finish $false @{ chat = $To; verified = $verified; error = "剪贴板文件列表异常（期望 $($files.Count)，实际 $($back.Count)）" }
}

# ---------------- 4. 点输入框 + 粘贴 ----------------
$attached = $false; $refShot = $null
foreach ($c in $clickCands) {
    [Wx32]::Force($hwnd) | Out-Null
    Start-Sleep -Milliseconds 200
    [Wx32]::Click($c[0], $c[1])
    Start-Sleep -Milliseconds 500
    $before = Snap $inputCropX $inputCropY $inputCropW $inputCropH
    [Wx32]::Ctrl(0x56)
    Start-Sleep -Milliseconds 1600
    $after = Snap $inputCropX $inputCropY $inputCropW $inputCropH
    $d = DiffRatio $before $after
    $before.Dispose()
    if ($d -gt 0.015) { $attached = $true; $refShot = $after; break }
    $after.Dispose()
}
if (-not $attached) {
    Finish $false @{ chat = $To; verified = $verified; ocr = $ocrText; error = 'Ctrl+V 后输入框未出现附件（焦点没落在输入框）' }
}

if ($NoSend) {
    $refShot.Dispose()
    Finish $true @{ chat = $To; verified = $verified; sent = $false; files = $files }
}

# ---------------- 5. Enter 发送 ----------------
[Wx32]::Force($hwnd) | Out-Null
Start-Sleep -Milliseconds 200
[Wx32]::Key(0x0D)
Start-Sleep -Milliseconds 2200
$sent = $false
for ($i = 0; $i -lt 10; $i++) {
    $now = Snap $inputCropX $inputCropY $inputCropW $inputCropH
    $d = DiffRatio $refShot $now
    $now.Dispose()
    if ($d -gt 0.015) { $sent = $true; break }
    Start-Sleep -Milliseconds 300
}
$refShot.Dispose()

Finish $sent @{
    chat = $To; verified = $verified; sent = $sent; files = $files
    error = $(if ($sent) { $null } else { '按 Enter 后输入框未清空，可能没发出去' })
}
