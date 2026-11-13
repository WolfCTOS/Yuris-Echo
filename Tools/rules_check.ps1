<#
    rules_check.ps1 - consistency check for the Yuri's Echo rules file.

    Catches the class of bugs that rules editing produces by hand:
    an index list entry whose section was renamed, a weapon pointing at a
    warhead that was never registered, a unit no lobby country can build,
    a RequiredHouses list that the Owner list does not contain, a prerequisite
    that names nothing, and encoding / line-ending damage.

    The lobby is the rules' own country table: the countries of [Countries]
    whose house section is marked Multiplay=yes. The launcher offers exactly
    those countries and the spawner writes their indexes into spawn.ini, so a
    unit whose RequiredHouses keep it away from every lobby country can never
    be built by anyone.

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

# --- house sections: the keys the ownership rules need ----------------------
$houseInfo = @{}
$cur = ''
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*\[([^\]]+)\]') { $cur = $Matches[1].Trim(); continue }
    if (-not $cur) { continue }
    $v = (Strip-Comment $lines[$i]).Trim()
    if ($v -notmatch '^([^=]+)=(.*)$') { continue }
    $k = $Matches[1].Trim(); $val = $Matches[2].Trim()
    if ($k -notin @('Owner', 'RequiredHouses', 'ForbiddenHouses', 'Multiplay', 'Prerequisite')) { continue }
    if (-not $houseInfo.ContainsKey($cur)) { $houseInfo[$cur] = @{} }
    if (-not $houseInfo[$cur].ContainsKey($k)) { $houseInfo[$cur][$k] = $val }
}

# --- the lobby: countries of [Countries] whose house is Multiplay=yes -------
$passive = @('GDI', 'Nod', 'Neutral', 'Special', 'Observer')
$countryHouses = @()
$inCountries = $false
for ($i = 0; $i -lt $lines.Count; $i++) {
    $t = $lines[$i].Trim()
    if ($t -match '^\[') { $inCountries = ($t -eq '[Countries]'); continue }
    if (-not $inCountries) { continue }
    $v = (Strip-Comment $lines[$i]).Trim()
    if ($v -match '^\d+\s*=\s*(.+)$') {
        $h = $Matches[1].Trim()
        if ($passive -notcontains $h) { $countryHouses += $h }
    }
}
$lobby = @($countryHouses | Where-Object {
    $houseInfo.ContainsKey($_) -and $houseInfo[$_].ContainsKey('Multiplay') -and
    $houseInfo[$_]['Multiplay'] -match '^(?i)yes$'
})
Write-Output ("lobby countries: " + ($lobby -join ', '))

function Test-Buildable([string]$section, [string]$house) {
    if (-not $houseInfo.ContainsKey($section)) { return $true }
    $info = $houseInfo[$section]
    $owner = @()
    if ($info.ContainsKey('Owner')) { $owner = @($info['Owner'] -split ',' | ForEach-Object { $_.Trim() }) }
    if ($owner.Count -eq 0) { return $true }
    if ($owner -notcontains $house) { return $false }
    if ($info.ContainsKey('RequiredHouses')) {
        $req = @($info['RequiredHouses'] -split ',' | ForEach-Object { $_.Trim() })
        if ($req.Count -gt 0 -and $req -notcontains $house) { return $false }
    }
    if ($info.ContainsKey('ForbiddenHouses')) {
        $forb = @($info['ForbiddenHouses'] -split ',' | ForEach-Object { $_.Trim() })
        if ($forb -contains $house) { return $false }
    }
    return $true
}

# --- ownership: a lobby country must be able to build every unit -------------
$orphans = @(); $badreq = @()
foreach ($sec in $sections.Keys) {
    if (-not $houseInfo.ContainsKey($sec)) { continue }
    if (-not $houseInfo[$sec].ContainsKey('Owner')) { continue }
    $any = $false
    foreach ($h in $lobby) {
        if (Test-Buildable $sec $h) { $any = $true; break }
    }
    if (-not $any) { $orphans += $sec }
    if ($houseInfo[$sec].ContainsKey('RequiredHouses')) {
        $owner = @($houseInfo[$sec]['Owner'] -split ',' | ForEach-Object { $_.Trim() })
        $req = @($houseInfo[$sec]['RequiredHouses'] -split ',' | ForEach-Object { $_.Trim() })
        foreach ($r in $req) {
            if ($r.Length -eq 0) { continue }
            if ($owner -notcontains $r) { $badreq += ($sec + ' Req=[' + $houseInfo[$sec]['RequiredHouses'] + '] Owner=[' + $houseInfo[$sec]['Owner'] + ']') }
        }
    }
}
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

# --- the factions of [Factions] must name houses that exist -----------------
# The launcher offers these factions and gives the player the first house of
# the chosen one, so a typo in the section would hand out the wrong country.
$badfaction = @()
$inFactions = $false
foreach ($line in $lines) {
    $t = $line.Trim()
    if ($t -match '^\[') { $inFactions = ($t -eq '[Factions]'); continue }
    if (-not $inFactions) { continue }
    $v = (Strip-Comment $line).Trim()
    if ($v -notmatch '^([^=]+)=(.*)$') { continue }
    $fname = $Matches[1].Trim()
    $houses = @($Matches[2] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
    if ($houses.Count -eq 0) { $badfaction += ($fname + ' (no houses)'); continue }
    foreach ($h in $houses) {
        if ($countryHouses -notcontains $h) { $badfaction += ($fname + ' -> ' + $h) }
    }
}
if ($badfaction.Count -gt 0) {
    Write-Output ("[FAIL] factions that name no country: " + ($badfaction -join ', '))
    $problems++
} else {
    Write-Output '[ OK ] every faction names countries of the table'
}

# --- prerequisites must name a building or a retail generic group -----------
# The retail engine resolves six generic groups (POWER, FACTORY, BARRACKS,
# RADAR, TECH, PROC) before it looks at the building list, so BARRACKS is a
# valid prerequisite even though no [BARRACKS] section exists.
$generic = @('POWER', 'FACTORY', 'BARRACKS', 'RADAR', 'TECH', 'PROC')
$badprereq = @()
foreach ($sec in $sections.Keys) {
    if (-not $houseInfo.ContainsKey($sec)) { continue }
    if (-not $houseInfo[$sec].ContainsKey('Prerequisite')) { continue }
    foreach ($tok in @($houseInfo[$sec]['Prerequisite'] -split ',' | ForEach-Object { $_.Trim() })) {
        if ($tok.Length -eq 0) { continue }
        if ($sections.ContainsKey($tok)) { continue }
        if ($generic -contains $tok.ToUpperInvariant()) { continue }
        $badprereq += ($sec + ' -> ' + $tok)
    }
}
if ($badprereq.Count -gt 0) {
    Write-Output ("[FAIL] prerequisites that name nothing: " + ($badprereq -join ', '))
    $problems++
} else {
    Write-Output '[ OK ] every prerequisite names a building or a retail group'
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
