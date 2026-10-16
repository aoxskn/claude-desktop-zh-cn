# Windows 端补丁器的语法安全回归测试。
#
# 与 macOS/Linux 侧的前端补丁安全测试一一对应：那两条走
# scripts/patch_claude_zh_cn.py，Windows 走 install_windows.ps1 内嵌的 C# 补丁器，
# 两条路径必须给出同样的安全判定，否则等于只修好了一半。
#
# 运行： pwsh -File tests/test_windows_patcher.ps1

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$ps1Path = Join-Path $repoRoot 'scripts\install_windows.ps1'

$script:passed = 0
$script:failed = 0

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:passed++
        Write-Host "  ok   $Name" -ForegroundColor DarkGreen
    } else {
        $script:failed++
        Write-Host "  FAIL $Name $Detail" -ForegroundColor Red
    }
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    Assert-True $Name ($Expected -ceq $Actual) "expected=[$Expected] actual=[$Actual]"
}

# ---- 提取并编译 C# 补丁器（与安装脚本使用同一段源码）------------------------
$source = Get-Content $ps1Path -Raw -Encoding UTF8
$match = [regex]::Match($source, "(?s)\`$script:FrontendPatcherCSharp = @'\r?\n(?<code>.*?)\r?\n'@")
if (-not $match.Success) {
    Write-Host '未能从 install_windows.ps1 提取 C# 补丁器' -ForegroundColor Red
    exit 1
}
Add-Type -TypeDefinition $match.Groups['code'].Value -ErrorAction Stop
Write-Host 'C# FrontendPatcher 编译成功（含 StructuralContextRe 静态初始化）'

# ---- PS 5.1 兼容性 ---------------------------------------------------------
# Windows 自带的 powershell.exe（5.1）里 Add-Type 用的是 C# 5 编译器，出现 C# 6/7
# 语法（readonly struct、表达式体属性等）会整段编译失败。安装脚本把异常吞掉后退回
# 单线程 PowerShell 路径，而那条路径不执行本次的安全闸——功能看起来正常，只是保护
# 全没了。所以测试跑在 pwsh 7 上是发现不了这个问题的，必须显式拿 5.1 再编一次。
$winPs = Get-Command powershell.exe -ErrorAction SilentlyContinue
if ($winPs) {
    $tmpCs = Join-Path ([System.IO.Path]::GetTempPath()) ('zh-patcher-' + [Guid]::NewGuid().ToString('N') + '.cs')
    try {
        # 必须带 BOM：PS 5.1 读到没有 BOM 的文件会按 ANSI 解码，中文注释里的字节
        # 可能被拆成字符串字面量里的非法字符，编出与真机不同的结果。
        [System.IO.File]::WriteAllText(
            $tmpCs, $match.Groups['code'].Value, (New-Object System.Text.UTF8Encoding($true)))
        $out = & powershell.exe -NoProfile -NonInteractive -Command "Add-Type -Path '$tmpCs' -ErrorAction Stop; 'COMPILE_OK'" 2>&1
        $outText = $out -join "`n"
        Assert-True 'PS 5.1 也能编译（stock Windows 上补丁器不会静默失效）' (
            $LASTEXITCODE -eq 0 -and $outText -match 'COMPILE_OK') "out=[$outText]"
    } finally {
        Remove-Item -Force $tmpCs -ErrorAction SilentlyContinue
    }
} else {
    Write-Host '  skip PS 5.1 编译检查（powershell.exe 不可用）' -ForegroundColor Yellow
}

# ---- 规则级判定 ------------------------------------------------------------
Write-Host ''
Write-Host '规则级判定（IsTranslatable）:'

Assert-True 'minified 属性对可翻译' (
    [ClaudeZhPatch.FrontendPatcher]::IsTranslatable('Sa="Cloud"', 'Sa="云端"'))
Assert-True '默认文案对可翻译且不改 id' (
    [ClaudeZhPatch.FrontendPatcher]::IsTranslatable(
        'defaultMessage:"Later",id:"tzMNF3jWoU"', 'defaultMessage:"稍后",id:"tzMNF3jWoU"'))
Assert-True '注入新属性的规则被拒' (
    -not [ClaudeZhPatch.FrontendPatcher]::IsTranslatable('x={a:"1"}', 'x={a:"1",b:"2"}'))
Assert-True '译文带裸引号被拒' (
    -not [ClaudeZhPatch.FrontendPatcher]::IsTranslatable('x="Appearance"', 'x="外观" Said "no"'))
Assert-True '译文带反斜杠被拒' (
    -not [ClaudeZhPatch.FrontendPatcher]::IsTranslatable('x="Appearance"', 'x="外观\"'))
Assert-True '译文引入模板插值被拒' (
    -not [ClaudeZhPatch.FrontendPatcher]::IsTranslatable('x="Cloud"', 'x="`${a}`"'))
Assert-True '图标名形状仍需结构上下文守卫' (
    [ClaudeZhPatch.FrontendPatcher]::IsTranslatable('icon:"Add"', 'icon:"添加"'))
Assert-True '字面量内的无引号文案规则可翻译' (
    [ClaudeZhPatch.FrontendPatcher]::IsTranslatable(
        'Blank = 72-hour default.', '留空 = 72 小时默认值。'))
Assert-True '转义种类没变即可翻译' (
    [ClaudeZhPatch.FrontendPatcher]::IsTranslatable(
        'help:{body:"a\nb\n', 'help:{body:"中\n文\n'))
Assert-True '译文新增转义序列被拒' (
    -not [ClaudeZhPatch.FrontendPatcher]::IsTranslatable('t("a")', 't("他说\"好\"")'))

# ---- 字面量扫描（LiteralSpans）---------------------------------------------
# Python 侧 frontend_literal_spans 的镜像。字面量边界算错的后果有两层：
# 文件级闸把整包误判成不安全（白翻），命中级闸把代码当成字面量内容（会写坏）。
Write-Host ''
Write-Host '字面量扫描（LiteralSpans）:'

function Get-SpanTexts([string]$Text) {
    return @([ClaudeZhPatch.FrontendPatcher]::LiteralSpans($Text) |
        ForEach-Object { $Text.Substring($_.Start, $_.End - $_.Start) })
}

Assert-Equal '值后面的斜杠是除法，运算符后面是正则' '"s"' (
    (Get-SpanTexts 'var q=a/b/2;var re=/"/g;var t="s";') -join ',')
# return/typeof/case 这类关键字后面是值位置，紧跟的 / 是正则起点；漏判会让正则的
# 结束斜杠被当成下一个正则的起点，后面所有字面量边界从这里整段错位。
Assert-Equal '关键字后面的斜杠是正则' '"/mnt/","\\"' (
    (Get-SpanTexts 'return/%[0-9a-f]{2}/i.test(t)?t.startsWith("/mnt/"):t.includes("\\")?1:2') -join ',')
Assert-Equal '关键字规则不影响除法' '"s"' (
    (Get-SpanTexts 'var a=in/x;return a+"s";') -join ',')

# ---- 文件级闸 --------------------------------------------------------------
function Invoke-Patcher {
    param([string]$Text, [object[][]]$Rules)

    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("zh-test-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
        $path = Join-Path $dir 'chunk.js'
        [System.IO.File]::WriteAllText($path, $Text, (New-Object System.Text.UTF8Encoding($false)))
        $outputs = [string[]]::new(1)
        $counts = [ClaudeZhPatch.FrontendPatcher]::PatchFiles([string[]]@($path), $Rules, 1, $outputs)
        $result = [pscustomobject]@{
            Changed = $null -ne $outputs[0]
            Count = $counts[0]
            # 未写盘时 PatchFiles 返回 null，磁盘上仍是原文，这里返回原文便于断言
            Text = if ($null -ne $outputs[0]) { $outputs[0] } else { $Text }
        }
        return $result
    } finally {
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    }
}

function New-QuotedRule([string]$Source, [string]$Target) {
    $pattern = '(?<quote>["''`])' + [System.Text.RegularExpressions.Regex]::Escape($Source) + '\k<quote>'
    return [object[]]@([System.Text.RegularExpressions.Regex]::new($pattern), $Source, $Target)
}

Write-Host ''
Write-Host '文件级闸（PatchFiles）:'

$r = Invoke-Patcher 'x={label:"Appearance"};' @(, (New-QuotedRule 'Appearance' '外观'))
Assert-True '安全替换会写盘' ($r.Changed -and $r.Count -eq 1)
Assert-Equal '译文正确' 'x={label:"外观"};' $r.Text

$r = Invoke-Patcher 'var s="Please click Later";' @(
    , [object[]]@($null, 'Please click Later', '稍后"')
)
Assert-True '译文撑破字符串时文件保持原样' (-not $r.Changed)
Assert-Equal '原文件未被改动' 'var s="Please click Later";' $r.Text

$r = Invoke-Patcher 'var a="Hello";var b="Later";' @(
    , [object[]]@($null, '";var b="', '";var c="')
)
Assert-True '跨字面量边界的命中被拒' (-not $r.Changed)

$r = Invoke-Patcher 'const a={icon:"Add"};var t="Add";' @(, (New-QuotedRule 'Add' '添加'))
Assert-Equal 'icon 名保持英文、普通字符串照翻' 'const a={icon:"Add"};var t="添加";' $r.Text

$r = Invoke-Patcher 'x="Hello";y="Later";' @(
    , [object[]]@($null, '";y="', '";y="z="')
    , (New-QuotedRule 'Later' '稍后')
)
Assert-True '坏规则降级后仍保留安全翻译' ($r.Changed -and $r.Count -eq 1)
Assert-Equal '降级结果正确' 'x="Hello";y="稍后";' $r.Text

$r = Invoke-Patcher "var s='`";var b=`" x';var a=`"X`";var b=`"Y`";" @(
    , [object[]]@($null, '";var b="', '";var c="')
)
Assert-True '只改被放行的命中（String.Replace 会连被拒的一起改）' ($r.Changed -and $r.Count -eq 1)
Assert-Equal '跨边界的命中保持原样' "var s='`";var c=`" x';var a=`"X`";var b=`"Y`";" $r.Text

$r = Invoke-Patcher 'var tip="Blank = 72-hour default.";' @(
    , [object[]]@($null, 'Blank = 72-hour default.', '留空 = 72 小时默认值。')
)
Assert-True '字面量内的无引号文案照翻' ($r.Changed -and $r.Count -eq 1)
Assert-Equal '无引号文案译文正确' 'var tip="留空 = 72 小时默认值。";' $r.Text

# ---- 真解析器兜底 ----------------------------------------------------------
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    $snippet = 'var _jsx=()=>{const Sa="Cloud";return{icon:"Add",title:"Appearance",' +
        'msg:{defaultMessage:"Later",id:"tzMNF3jWoU"},tpl:`x${Sa}y`}};'
    $rules = @(
        , [object[]]@($null, 'Sa="Cloud"', 'Sa="云端"')
        , (New-QuotedRule 'Appearance' '外观')
        , [object[]]@($null, 'defaultMessage:"Later"', 'defaultMessage:"稍后"')
    )
    $r = Invoke-Patcher $snippet $rules
    $tmpJs = Join-Path ([System.IO.Path]::GetTempPath()) ("zh-check-" + [Guid]::NewGuid().ToString('N') + '.mjs')
    try {
        [System.IO.File]::WriteAllText($tmpJs, $r.Text, (New-Object System.Text.UTF8Encoding($false)))
        & node --check $tmpJs | Out-Null
        Assert-True 'node --check 通过' ($LASTEXITCODE -eq 0)
    } finally {
        Remove-Item -Force $tmpJs -ErrorAction SilentlyContinue
    }
} else {
    Write-Host '  skip node --check（node 不可用）' -ForegroundColor Yellow
}

Write-Host ''
Write-Host "通过 $script:passed，失败 $script:failed"
if ($script:failed -gt 0) { exit 1 }
exit 0
