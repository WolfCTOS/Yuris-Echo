param(
    [switch]$FailOnGaps
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$proj = Join-Path $root 'LuaApiLauncher'

function Get-EnKeys {
    $loc = Join-Path $proj 'Localization.cs'
    $text = Get-Content $loc -Raw -Encoding UTF8
    $keys = New-Object 'System.Collections.Generic.HashSet[string]'
    $vals = @{}
    $pattern = '\[\s*"((?:[^"\\]|\\.)*)"\s*\]\s*=\s*"((?:[^"\\]|\\.)*)"'
    foreach ($m in [regex]::Matches($text, $pattern)) {
        $k = [regex]::Unescape($m.Groups[1].Value)
        $v = [regex]::Unescape($m.Groups[2].Value)
        [void]$keys.Add($k)
        $vals[$k] = $v
    }
    return @{ Keys = $keys; Values = $vals }
}

function Has-Cyrillic([string]$s) { return $s -match '[\p{IsCyrillic}]' }

$en = Get-EnKeys
$rows = New-Object 'System.Collections.Generic.List[object]'
$seen = New-Object 'System.Collections.Generic.HashSet[string]'

function Add-Row($file,$line,$text,$reason) {
    $key = "$file|$line|$text|$reason"
    if ($seen.Add($key)) {
        $rows.Add([pscustomobject]@{ File=$file; Line=$line; Text=$text; Issue=$reason })
    }
}

function Check-Key($file,$line,$text) {
    if (-not (Has-Cyrillic $text)) { return }
    if (-not $en.Keys.Contains($text)) {
        Add-Row $file $line $text 'нет EN-ключа'
        return
    }
    $v = $en.Values[$text]
    if ($v -match '[\p{IsCyrillic}]') {
        Add-Row $file $line $text 'значение EN содержит кириллицу'
    }
}

# .cs files
Get-ChildItem $proj -Recurse -Include *.cs | Where-Object { $_.FullName -notmatch '\\obj\\|\\bin\\' } | ForEach-Object {
    $file = $_.Name
    $content = Get-Content $_.FullName -Raw -Encoding UTF8
    $lines = Get-Content $_.FullName -Encoding UTF8
    # L10n.T / L10n.F calls
    foreach ($m in [regex]::Matches($content, 'L10n\.(T|F)\(\s*"((?:[^"\\]|\\.)*)"')) {
        $txt = [regex]::Unescape($m.Groups[2].Value)
        $ln = ($content.Substring(0,$m.Index) -split "`n").Count
        Check-Key $file $ln $txt
    }
    # assignments Content/Text/ToolTip/Title/Header/Placeholder = "..."
    foreach ($m in [regex]::Matches($content, '(Content|Text|ToolTip|Title|Header|Placeholder)\s*=\s*"((?:[^"\\]|\\.)*)"')) {
        $txt = [regex]::Unescape($m.Groups[2].Value)
        $ln = ($content.Substring(0,$m.Index) -split "`n").Count
        Check-Key $file $ln $txt
    }
}

# .xaml files
Get-ChildItem $proj -Recurse -Include *.xaml | Where-Object { $_.FullName -notmatch '\\obj\\|\\bin\\' } | ForEach-Object {
    $file = $_.Name
    $content = Get-Content $_.FullName -Raw -Encoding UTF8
    foreach ($m in [regex]::Matches($content, '(Content|Text|ToolTip|Title|Header)\s*=\s*"([^"]*)"')) {
        $txt = $m.Groups[2].Value
        $ln = ($content.Substring(0,$m.Index) -split "`n").Count
        Check-Key $file $ln $txt
    }
}

if ($rows.Count -eq 0) {
    Write-Output "OK: пропусков не найдено (0)."
    exit 0
}

$total = $rows.Count
$show = $rows
if ($total -gt 30) { $show = $rows | Select-Object -First 30 }
Write-Output "Файл | Строка | Текст | Проблема"
Write-Output "---|---:|---|---"
foreach ($r in $show) {
    $t = ($r.Text -replace '\|','/' -replace "`r|`n",' ')
    Write-Output ("{0} | {1} | {2} | {3}" -f $r.File,$r.Line,$t,$r.Issue)
}
if ($total -gt 30) { Write-Output "(показаны первые 30 из $total)" }
Write-Output "Всего: $total"

if ($FailOnGaps) { exit 1 } else { exit 0 }
