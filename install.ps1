# install.ps1 - 把 wx-send 安装成本机全局技能
# 用法: pwsh -NoProfile -File .\install.ps1 [-Force]

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$SkillRoot = (Join-Path $env:USERPROFILE '.dsh\skills')
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $SkillRoot 'wx-send'

Write-Host "wx-send 安装器" -ForegroundColor Cyan
Write-Host "  源目录: $here"
Write-Host "  目标  : $target"

foreach ($f in @('SKILL.md', 'scripts\wx-send.ps1', 'scripts\wx-ocr.ps1')) {
    if (-not (Test-Path (Join-Path $here $f))) {
        throw "缺少文件: $f（请在仓库根目录运行本脚本）"
    }
}

if ((Test-Path $target) -and -not $Force) {
    Write-Host "目标已存在。加 -Force 覆盖安装，或手动删除后重跑。" -ForegroundColor Yellow
    Write-Host "  已存在: $target"
    exit 3
}

New-Item -ItemType Directory -Force -Path (Join-Path $target 'scripts') | Out-Null
Copy-Item (Join-Path $here 'SKILL.md') (Join-Path $target 'SKILL.md') -Force
Copy-Item (Join-Path $here 'scripts\wx-send.ps1') (Join-Path $target 'scripts\wx-send.ps1') -Force
Copy-Item (Join-Path $here 'scripts\wx-ocr.ps1') (Join-Path $target 'scripts\wx-ocr.ps1') -Force

# Windows PowerShell 5.1 会把无 BOM 的 UTF-8 当成 ANSI，中文注释连带 param 块一起读坏。
# 统一转成 UTF-8 with BOM。
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
foreach ($p in @((Join-Path $target 'scripts\wx-send.ps1'), (Join-Path $target 'scripts\wx-ocr.ps1'))) {
    $text = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($p, $text, $utf8Bom)
}
Write-Host "  已修正 BOM" -ForegroundColor DarkGray

# 自检：只放进输入框，不发送
$probe = Join-Path $env:TEMP 'wx-send-selftest.txt'
"wx-send selftest $(Get-Date -Format o)" | Set-Content -LiteralPath $probe -Encoding UTF8

Write-Host "自检中（只放输入框，不发送）……" -ForegroundColor Cyan
$out = & pwsh -NoProfile -File (Join-Path $target 'scripts\wx-send.ps1') -Path $probe -NoSend 2>&1 | Out-String
Write-Host $out.Trim()

if ($out -match '"ok":true') {
    Write-Host "`n安装成功。以后任意会话可直接调用：" -ForegroundColor Green
    Write-Host "  & `"$target\scripts\wx-send.ps1`" -Path `"<文件路径>`""
} else {
    Write-Host "`n脚本已复制，但自检未通过。请检查微信是否已登录并保持运行。" -ForegroundColor Yellow
    Write-Host "排查：README.md 的「常见问题」一节。"
    exit 1
}
