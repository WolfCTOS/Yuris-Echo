<#
    rules_check.ps1 - consistency check for the Yuri's Echo rules file.

    Catches the class of bugs that rules editing produces by hand:
    an index list entry whose section was renamed, a weapon pointing at a
    warhead that was never registered, a unit no lobby country can build,
    a RequiredHouses list that the Owner list does not contain, and
    encoding / line-ending damage.

    Usage:
        .\Tools\rules_check.ps1                      # checks .\rulesmd.ini
        .\Tools\rules_check.ps1 -Path D:\...\rulesmd.ini
#>
param(
    [string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'rulesmd.ini')
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "rules file not found: $Path"
    exit 2
}

function Strip-Comment([string]$line) {
    $i = $line.IndexOf(';')
    if ($i -ge 0) { return $line.Substring(0, $i) }
    return $line
}

$lines = Get-Content -LiteralPath $Path -Encoding UTF8
$problems = 0

# --- sections ---------------------------------------------------------------
$sections = @{}
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*\[([^\]]+)\]') {
        $n = $Matches[1].Trim()
        if (-not $sections.ContainsKey($n)) { $sections[$n] = @() }
        $sections[$n] += $i
    }
}
Write-Output ("sections: " + $sections.Count + "   lines: " + $lines.Count)

# --- index lists must resolve to an existing section ------------------------
# Known holes that are already in the base rules file and are deliberate:
# a list entry whose section was removed upstream (YDUM), a section that is
# commented out on purpose (APACHE, the Harpy), campaign-only buildings that
# the mod does not use, and the cliff/tree overlays that live in the mix.
$known = @{
    'VehicleTypes'   = @('YDUM')
    'AircraftTypes'  = @('APACHE')
    'BuildingTypes'  = @('CASYDN01', 'CATIME', 'CALA02', 'CALOND02')
    'OverlayTypes'   = @('CYCL', 'BARB', 'WOOD', 'DUMMY', 'DUMMY2', 'DUMMY3',
                         'DUMMY4', 'DUMMY5', 'DUMMY6', 'DUMMY7', 'DUMMY8',
                         'DUMMY9', 'DUMMY10', 'DUMMY11', 'DUMMY12', 'V16',
                         'V17', 'V18', 'DUMMY13', 'DUMMY14', 'FENC', 'DUMMY15',
                         'DUMMYOLD', 'USELESS', 'GAWRONG')
}
$lists = @('InfantryTypes', 'VehicleTypes', 'Warheads', 'AircraftTypes',
           'BuildingTypes', 'SuperWeaponTypes', 'TerrainTypes', 'SmudgeTypes',
           'OverlayTypes', 'AttachEffectTypes')
foreach ($l in $lists) {
    if (-not $sections.ContainsKey($l)) { continue }
    $start = $sections[$l][0]
    $missing = @(); $knownHit = @()
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[') { break }
        $v = (Strip-Comment $lines[$i]).Trim()
        if ($v -match '^\d+\s*=\s*(.+)$') {
            $nm = $Matches[1].Trim()
            if (-not $sections.ContainsKey($nm)) {
                if ($known.ContainsKey($l) -and $known[$l] -contains $nm) { $knownHit += $nm }
                else { $missing += $nm }
            }
        }
    }
    if ($missing.Count -gt 0) {
        Write-Output ("[FAIL] [$l] -> no section for: " + ($missing -join ', '))
        $problems++
    } else {
        Write-Output ("[ OK ] [$l] all names resolve" +
            $(if ($knownHit.Count -gt 0) { " (" + $knownHit.Count + " known hole(s))" } else { "" }))
    }
}

# --- every weapon warhead must be registered --------------------------------
$reg = @{}
$start = $sections['Warheads'][0]
for ($i = $start + 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*\[') { break }
    $v = (Strip-Comment $lines[$i]).Trim()
    if ($v -match '^\d+\s*=\s*(.+)$') { $reg[$Matches[1].Trim()] = $true }
}
$used = @{}
for ($i = 0; $i -lt $lines.Count; $i++) {
    $v = (Strip-Comment $lines[$i]).Trim()
    if ($v -match '^Warhead\s*=\s*(.+)$') { $used[$Matches[1].Trim()] = $true }
}
$unreg = @($used.Keys | Where-Object { -not $reg.ContainsKey($_) })
if ($unreg.Count -gt 0) {
    Write-Output ("[FAIL] warheads used but not registered: " + ($unreg -join ', '))
    $problems++
} else {
    Write-Output ("[ OK ] warheads: " + $used.Count + " used, all registered")
}

# --- ownership: a lobby country must be able to build every unit -------------
$lobby = @('Americans', 'Russians', 'Confederation', 'Arabs', 'YuriCountry')
$cur = ''; $owner = ''; $req = ''
$orphans = @(); $badreq = @()
function Flush($c, $o, $r) {
    if ($c -eq '' -or $o -eq '') { return }
    $oh = @($o -split ',' | ForEach-Object { $_.Trim() })
    if ($r -eq '') {
        $hit = $false
        foreach ($h in $oh) { if ($lobby -contains $h) { $hit = $true } }
        if (-not $hit) { $script:orphans += $c }
    } else {
        $rh = @($r -split ',' | ForEach-Object { $_.Trim() })
        $hit = $false
        foreach ($h in $rh) { if ($oh -contains $h) { $hit = $true } }
        if (-not $hit) { $script:badreq += ($c + ' Req=[' + $r + '] Owner=[' + $o + ']') }
    }
}
for ($i = 0; $i -lt $lines.Count; $i++) {
    $v = (Strip-Comment $lines[$i]).Trim()
    if ($lines[$i] -match '^\s*\[([^\]]+)\]') {
        Flush $cur $owner $req
        $cur = $Matches[1].Trim(); $owner = ''; $req = ''
    } elseif ($v -match '^Owner\s*=\s*(.+)$') { $owner = $Matches[1].Trim() }
    elseif ($v -match '^RequiredHouses\s*=\s*(.+)$') { $req = $Matches[1].Trim() }
}
Flush $cur $owner $req
if ($orphans.Count -gt 0) {
    Write-Output ("[FAIL] no lobby country can build: " + ($orphans -join ', '))
    $problems++
} else {
    Write-Output '[ OK ] every unit is reachable by a lobby country'
}
if ($badreq.Count -gt 0) {
    Write-Output ("[FAIL] RequiredHouses not inside Owner: " + ($badreq -join ' | '))
    $problems++
} else {
    Write-Output '[ OK ] RequiredHouses is a subset of Owner'
}

# --- encoding / line endings -------------------------------------------------
$b = [IO.File]::ReadAllBytes($Path)
$crlf = 0; $lf = 0
for ($i = 0; $i -lt $b.Length; $i++) {
    if ($b[$i] -eq 10) { if ($i -gt 0 -and $b[$i-1] -eq 13) { $crlf++ } else { $lf++ } }
}
$strict = New-Object Text.UTF8Encoding($false, $true)
$utf = 'OK'
try { $null = $strict.GetString($b) } catch { $utf = 'FAIL' }
if ($lf -gt 0 -or $utf -eq 'FAIL' -or ($b.Length -ge 3 -and $b[0] -eq 0xEF)) {
    Write-Output ("[FAIL] encoding: utf8=$utf bareLF=$lf bom=" + ($b[0] -eq 0xEF))
    $problems++
} else {
    Write-Output ("[ OK ] encoding: UTF-8 without BOM, CRLF only (" + $crlf + " lines)")
}

if ($problems -eq 0) {
    Write-Output 'result: OK'
    exit 0
}
Write-Output ("result: " + $problems + " problem(s)")
exit 1
