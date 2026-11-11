---
name: wx-send
description: 通过微信桌面版把文件/图片发送到指定会话（默认「文件传输助手」）。当用户说「把某个文件/图片用微信发给我」「发到微信」「通过文件传输助手发」时使用。调用 scripts/wx-send.ps1 一条命令完成：定位并激活微信 → OCR 校验会话 → 剪贴板投递文件 → 回车发送 → 像素校验，返回一行 JSON。
---

# wx-send —— 微信发文件/图片

一条 PowerShell 命令把本地文件（图片也算文件）发到任意微信会话。全程本地校验，不截图给模型看，**token 消耗 ≈ 0**，典型耗时 8–15 秒。

## 怎么用

```powershell
# 发一个文件/图片（默认发给「文件传输助手」）
& "$env:USERPROFILE\.dsh\skills\wx-send\scripts\wx-send.ps1" -Path "C:\Users\Administrator\Desktop\cat-test.png"

# 发多个
& "...\wx-send.ps1" -Path @("C:\a.png", "C:\b.pdf")

# 发给别的会话（写会话显示名，如「王泽安」「拼车5群」）
& "...\wx-send.ps1" -Path "C:\a.png" -To "王泽安"

# 只放进输入框，不发送（用于人工检查）
& "...\wx-send.ps1" -Path "C:\a.png" -NoSend
```

注意：`-Path` 是数组参数。**在 pwsh 里用 `-Path @('a','b')` 或逐个写**；用 `pwsh -File wx-send.ps1 -Path "a","b"` 从外部 shell 传参会把整串当成一个路径，别这么用。

解析返回值（最后一行 JSON）：

| 字段 | 含义 |
|---|---|
| `ok` | 整体成功 |
| `verified` | 会话标题经 OCR 校验与 `-To` 一致 |
| `sent` | 回车后输入框已清空（消息已发出） |
| `ms` | 耗时毫秒 |
| `error` | 失败原因（中文，可直接转述给用户） |

退出码 `0` 成功 / `1` 失败。**失败时不要把报错当成「大概成功了」**，要么按 error 修正（比如微信没登录），要么告诉用户。

## 它做了什么

1. 找微信主窗（`Qt*QWindowIcon` 类、面积最大的窗口）；没有就按桌面快捷方式 / 注册表定位 `Weixin.exe` 启动，必要时点「进入微信」。
2. 截图聊天标题区 → 系统 OCR（`Windows.Media.Ocr`，经 `wx-ocr.ps1`）→ 与目标会话名做**字符重合度**比对（OCR 会认错字，容忍到 50%，名字 ≤3 字要求全中）。
3. 不匹配则 `Ctrl+F` 唤出搜索框（**不用点坐标**）→ 粘贴会话名 → 回车打开 → 再 OCR 校验一次。
4. 点输入框 → 剪贴板写入 `CF_HDROP` 文件列表 → `Ctrl+V` → 像素差确认附件已出现在输入框。
5. 回车发送 → 像素差确认输入框已清空。

失败即中止，不会「先发出去再说」。

## 安全规则（重要）

- **不要用 `-Force` 去「碰运气」**。它跳过标题校验，等于放弃「不发错人」的唯一保障。只有用户明确说「我知道现在开的就是那个会话，直接发」时才用。
- 校验失败说明**当前微信不在目标会话且搜索也没打开成功**。正确做法是让用户手动点开目标会话，或确认会话显示名写对了（要完全一致：群名带不带 emoji、括号都要对）。
- 发送前脚本只动剪贴板，不发任何文本；中止时会按 Esc 收起搜索框，避免把会话名当文字发出去。
- 微信登录失效 / 弹广告窗口时脚本会报错退出，需要用户手动处理一次。

## 环境前提

- Windows 10/11，微信桌面版 4.x（Qt6）。微信需已登录，窗口可最小化。
- PowerShell 7（`pwsh`）优先，5.1 也能跑（脚本存为 UTF-8 BOM）。
- 系统装了中文 OCR 语言包（`Windows.Media.Ocr`，Win10/11 中文系统默认有）。

## 换电脑怎么装（给 AI 的指令）

1. 把整个 `wx-send` 目录复制到新机器的 `%USERPROFILE%\.dsh\skills\` 下。
2. 确认 `scripts\wx-send.ps1`、`scripts\wx-ocr.ps1` 存在，且 `.ps1` 是 UTF-8 **带 BOM**（否则 5.1 会把中文读成乱码）。修复：
   ```powershell
   $p = "$env:USERPROFILE\.dsh\skills\wx-send\scripts\wx-send.ps1"
   [System.IO.File]::WriteAllText($p, (Get-Content $p -Raw), (New-Object System.Text.UTF8Encoding($true)))
   ```
3. 自检：
   ```powershell
   & "$env:USERPROFILE\.dsh\skills\wx-send\scripts\wx-send.ps1" -Path "$env:TEMP\wxself.txt" -NoSend
   ```
   `"selftest" | Set-Content "$env:TEMP\wxself.txt"` 先建文件。返回 `ok:true` 即通。
4. **缩放校准**：脚本里的版面常量按「微信 UI 1:1 物理像素渲染」写死（本机 120 DPI 实测）。若新机器把系统缩放设成 150%/200%，微信可能被拉大，坐标会偏。表现为 `verified:false` 且报「Ctrl+F 没有唤出搜索框」或「输入框未出现附件」。修法：把脚本顶部 `$headerX/$headerY/$inputCrop*` 里的常量按 `缩放比例` 相乘，或直接把系统缩放设回 100%/125% 再试。
5. 若 `wx-ocr.ps1` 报错或无输出：`powershell.exe -NoProfile -File ...\wx-ocr.ps1 <任意png>` 单独跑一次看报错；缺语言包时去「设置 → 时间和语言 → 语言 → 中文 → 可选功能」加 OCR。

## 排错对照

| 现象 | 原因 / 处理 |
|---|---|
| `Ctrl+F 没有唤出微信搜索框` | 微信不是前台（被全屏程序盖住）或窗口卡死；点一下微信窗口再跑 |
| `无法确认已打开会话` | 会话名写错，或搜索结果第一项不是目标（先手动打开一次） |
| `输入框未出现附件` | 输入框没拿到焦点；重试一次通常就好 |
| `剪贴板文件列表异常` | 别的程序占着剪贴板；关掉剪贴板管理器再跑 |
| `微信窗口未出现` | 微信没登录；手动登录后重跑 |
