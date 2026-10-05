#Requires -Version 5.1
<#
  一键安装 / 卸载 —— 离线 DLSS5 采集端（改版 OptiScaler + CET mod）

  本脚本不负责解压。请先把两个 CI 产物各自解压成文件夹，再把文件夹路径传进来
  （解压工具随意：7-Zip / Windows 自带解压 / 在 Ubuntu 上解好再拷过来）：

    -ScalerDir = 解压 OptiScaler-Capture-Release 后、含 OptiScaler.dll 的那一层
                 （里面应有 OptiScaler.dll / OptiScaler.ini / setup_windows.bat / Licenses\ / OptiScaler\）
    -CetDir    = 解压 CET-optiscaler_capture 后、含 optiscaler_capture\init.lua 的那一层

  install 会：
    1. 把 OptiScaler 运行时复制进 bin\x64\（镜像官方布局：OptiScaler.dll 改名成代理名，如 dxgi.dll）
    2. 把 CET mod 复制进 mods\optiscaler_capture\
    3. 改 OptiScaler.ini： [Capture] Enabled=true ... ；[Hotfix] 两个 barrier = 64
    4. 把所有「新增 / 被覆盖」的文件记进 <bin\x64>\.opti-capture-install\manifest.json
       （被覆盖的文件原样备份到 .opti-capture-install\backup\）

  uninstall 会：
    · 按 manifest 删除新增文件、还原被覆盖文件、清理空目录、删掉状态目录

  用法：
    install  -ScalerDir [目录] -CetDir [目录] [-GamePath [游戏目录]]
    uninstall [游戏目录]
    status   [游戏目录]

  示例：
    .\opti-capture-install.ps1 install -ScalerDir "D:\testdlss5\OptiScaler-Capture-Release" -CetDir "D:\testdlss5\CET-optiscaler_capture" -GamePath "D:\steam\steamapps\common\Cyberpunk 2077"
    .\opti-capture-install.ps1 uninstall "D:\steam\steamapps\common\Cyberpunk 2077"

  说明：
    · 默认代理名 dxgi.dll（CP2077 推荐，setup_windows.bat 的默认项）。可用 -Proxy 换。
    · 不指定游戏目录时自动探测 Steam / GOG / Epic 常见路径。
    · 若目标 dxgi.dll 已被别的程序（如 ReShade）占用，会中止；确要覆盖请加 -Force。
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'uninstall', 'status')]
    [string]$Command = 'install',

    [Parameter(Position = 1)]
    [string]$ScalerDir,

    [Parameter(Position = 2)]
    [string]$CetDir,

    [Parameter(Position = 3)]
    [string]$GamePath,

    [ValidateSet('dxgi', 'winmm', 'version', 'dbghelp', 'd3d12', 'wininet', 'winhttp', 'OptiScaler.asi')]
    [string]$Proxy = 'dxgi',

    [int]$FrameStride = 2,
    [switch]$CaptureDepth,
    [switch]$CaptureExposure,
    [switch]$NoIni,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$STATE_DIR_NAME = '.opti-capture-install'
$MOD_REL = 'plugins\cyber_engine_tweaks\mods\optiscaler_capture'

# 复制进 bin\x64 时需要跳过的文件（代理源单独处理；其余是无关杂物）
$SCALER_SKIP = @(
    'OptiScaler.dll',
    'setup_linux.sh',
    '!! EXTRACT ALL FILES TO GAME FOLDER !!',
    '!! README_EXTRACT ALL FILES TO GAME FOLDER !!.txt'
)

# 卸载后尝试清理的空目录（自底向上）
$CLEAN_DIRS = @(
    $MOD_REL,
    'plugins\cyber_engine_tweaks\mods',
    'plugins\cyber_engine_tweaks',
    'plugins',
    'OptiScaler\plugins',
    'OptiScaler\D3D12_OptiScaler',
    'OptiScaler\Streamline',
    'OptiScaler\streamline',
    'OptiScaler',
    'Licenses'
)

# ---------------------------------------------------------------- 工具函数

function Write-Info($m) { Write-Host "[i] $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn2($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err($m)  { Write-Host "[x] $m" -ForegroundColor Red }

function Resolve-BinX64 {
    param([string]$Path)
    $probeList = New-Object System.Collections.Generic.List[string]
    if ($Path) {
        $probeList.Add($Path)
        $probeList.Add((Join-Path $Path 'bin\x64'))
        $probeList.Add((Join-Path $Path 'bin'))
    }
    foreach ($c in $probeList) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            $rp = (Resolve-Path -LiteralPath $c).Path
            if (Test-Path -LiteralPath (Join-Path $rp 'Cyberpunk2077.exe')) { return $rp }
        }
    }
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        $p = (Resolve-Path -LiteralPath $Path).Path
        for ($i = 0; $i -lt 5; $i++) {
            $bx = Join-Path $p 'bin\x64'
            if (Test-Path -LiteralPath (Join-Path $bx 'Cyberpunk2077.exe')) {
                return (Resolve-Path -LiteralPath $bx).Path
            }
            $parent = Split-Path -Path $p -Parent
            if (-not $parent -or $parent -eq $p) { break }
            $p = $parent
        }
    }
    return $null
}

function Get-AutoGamePath {
    $candidates = New-Object System.Collections.Generic.List[string]

    # Steam
    $steam = $null
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            if ($p.SteamPath) { $steam = $p.SteamPath }
            elseif ($p.InstallPath) { $steam = $p.InstallPath }
        } catch { }
        if ($steam) { break }
    }
    if ($steam) {
        $candidates.Add($steam)
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            $raw = Get-Content -LiteralPath $vdf -Raw
            foreach ($m in [regex]::Matches($raw, '"path"\s+"([^"]+)"')) {
                $candidates.Add(($m.Groups[1].Value -replace '\\\\', '\'))
            }
        }
    }

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($c in $candidates) { $roots.Add((Join-Path $c 'steamapps\common\Cyberpunk 2077')) }
    $roots.Add('C:\Program Files (x86)\GOG Galaxy\Games\Cyberpunk 2077')
    $roots.Add('C:\GOG Games\Cyberpunk 2077')
    $roots.Add('C:\Program Files\Epic Games\Cyberpunk2077')
    $roots.Add('C:\Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077')

    foreach ($r in $roots) {
        if ($r -and (Test-Path -LiteralPath (Join-Path $r 'bin\x64\Cyberpunk2077.exe'))) {
            return $r
        }
    }
    return $null
}

function Get-ContentRoot {
    param([string]$Dir)
    $d = $Dir
    while ($true) {
        $items = Get-ChildItem -LiteralPath $d -Force
        $files = @($items | Where-Object { -not $_.PSIsContainer })
        $dirs = @($items | Where-Object { $_.PSIsContainer })
        if ($files.Count -eq 0 -and $dirs.Count -eq 1) { $d = $dirs[0].FullName; continue }
        break
    }
    return $d
}

function Read-IniFile {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($ln in ($text -split "`r?`n")) { [void]$lines.Add($ln) }
    return @{ HasBom = $hasBom; Lines = $lines }
}

function Write-IniFile {
    param([string]$Path, [System.Collections.Generic.List[string]]$Lines, [bool]$HasBom)
    $text = ($Lines -join "`r`n")
    $enc = New-Object System.Text.UTF8Encoding($HasBom)
    [System.IO.File]::WriteAllText($Path, $text, $enc)
}

function Set-IniValue {
    param([System.Collections.Generic.List[string]]$Lines, [string]$Section, [string]$Key, [string]$Value)
    $secRe = '^\s*\[' + [regex]::Escape($Section) + '\]\s*$'
    $keyRe = '^\s*' + [regex]::Escape($Key) + '\s*='

    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $secRe) { $start = $i; break }
    }
    if ($start -lt 0) { throw "OptiScaler.ini 缺少 [$Section] 段，无法写入 $Key" }

    $end = $Lines.Count
    for ($j = $start + 1; $j -lt $Lines.Count; $j++) {
        if ($Lines[$j] -match '^\s*\[') { $end = $j; break }
    }

    for ($i = $start + 1; $i -lt $end; $i++) {
        if ($Lines[$i] -match $keyRe) {
            $semi = $Lines[$i].IndexOf(';')
            $tail = if ($semi -ge 0) { $Lines[$i].Substring($semi) } else { '' }
            $Lines[$i] = if ($tail) { "$Key=$Value $tail" } else { "$Key=$Value" }
            return
        }
    }
    $Lines.Insert($start + 1, "$Key=$Value")
}

function Remove-EmptyDir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $items = @(Get-ChildItem -LiteralPath $Path -Force -Recurse)
    if ($items.Count -eq 0) { Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue }
}

function Get-ForeignDll {
    param([string]$Path)
    try {
        $v = (Get-Item -LiteralPath $Path).VersionInfo
        if ($v -and $v.OriginalFilename) { return $v.OriginalFilename }
    } catch { }
    return $null
}

# ---------------------------------------------------------------- install

function Invoke-Install {
    param([string]$BinX64, [string]$SDir, [string]$CDir, [string]$ProxyName)

    if (-not $SDir) { throw "未指定 OptiScaler 目录（-ScalerDir）" }
    if (-not $CDir) { throw "未指定 CET 目录（-CetDir）" }
    if (-not (Test-Path -LiteralPath $SDir)) { throw "找不到 OptiScaler 目录：$SDir" }
    if (-not (Test-Path -LiteralPath $CDir)) { throw "找不到 CET 目录：$CDir" }
    $SDir = (Resolve-Path -LiteralPath $SDir).Path
    $CDir = (Resolve-Path -LiteralPath $CDir).Path

    $stateDir = Join-Path $BinX64 $STATE_DIR_NAME
    $mfPath = Join-Path $stateDir 'manifest.json'
    if ((Test-Path -LiteralPath $mfPath) -and -not $Force) {
        throw "已存在安装记录：$mfPath`n请先运行 uninstall，或加 -Force 覆盖（会丢弃旧备份）。"
    }
    if ((Test-Path -LiteralPath $mfPath) -and $Force) {
        Write-Warn2 "-Force：丢弃已有安装记录与备份"
        Remove-Item -LiteralPath $stateDir -Recurse -Force
    }

    $proxyFile = if ($ProxyName -like '*.*') { $ProxyName } else { "$ProxyName.dll" }

    Write-Info "读取 OptiScaler 目录…"
    $scalerRoot = Get-ContentRoot $SDir
    $proxySrc = Join-Path $scalerRoot 'OptiScaler.dll'
    if (-not (Test-Path -LiteralPath $proxySrc)) {
        throw "在 $scalerRoot 里没找到 OptiScaler.dll。`n请把 -ScalerDir 指向解压后含 OptiScaler.dll 的那一层（OptiScaler-Capture-Release 产物）。"
    }

    Write-Info "读取 CET mod 目录…"
    $lua = Get-ChildItem -LiteralPath $CDir -Recurse -File -Filter 'init.lua' | Select-Object -First 1
    if (-not $lua) {
        throw "在 $CDir 里没找到 init.lua。`n请把 -CetDir 指向解压后含 optiscaler_capture\init.lua 的那一层（CET-optiscaler_capture 产物）。"
    }
    $luaDir = Split-Path -Path $lua.FullName -Parent

    # ---- 构建复制计划（rel 一律相对 bin\x64）----
    $plan = New-Object System.Collections.Generic.List[object]

    foreach ($f in (Get-ChildItem -LiteralPath $scalerRoot -Recurse -File)) {
        $rel = $f.FullName.Substring($scalerRoot.Length).TrimStart('\', '/')
        if ($SCALER_SKIP -contains (Split-Path -Path $rel -Leaf)) { continue }
        $plan.Add([pscustomobject]@{ Src = $f.FullName; Rel = $rel })
    }
    foreach ($f in (Get-ChildItem -LiteralPath $luaDir -Recurse -File)) {
        $rel = $f.FullName.Substring($luaDir.Length).TrimStart('\', '/')
        $plan.Add([pscustomobject]@{ Src = $f.FullName; Rel = (Join-Path $MOD_REL $rel) })
    }
    # 代理 dll
    $plan.Add([pscustomobject]@{ Src = $proxySrc; Rel = $proxyFile })

    # ---- 预检冲突 ----
    $proxyDst = Join-Path $BinX64 $proxyFile
    if (Test-Path -LiteralPath $proxyDst) {
        $orig = Get-ForeignDll $proxyDst
        if ($orig -and $orig -ieq 'OptiScaler.dll') {
            Write-Info "$proxyFile 已是 OptiScaler，将覆盖（会先备份）"
        } elseif (-not $Force) {
            throw "$proxyFile 已存在，且不是 OptiScaler（OriginalFilename=$orig）。`n" +
                  "它很可能是 ReShade 或其他代理 mod。继续会顶掉它。`n" +
                  "确要覆盖请加 -Force，或改用 -Proxy winmm / version / dbghelp / d3d12。"
        } else {
            Write-Warn2 "-Force：覆盖非 OptiScaler 的 $proxyFile（原文件将备份）"
        }
    }

    $replaceList = @($plan | Where-Object { Test-Path -LiteralPath (Join-Path $BinX64 $_.Rel) })
    Write-Host ""
    Write-Host ("  将新增 " + ($plan.Count - $replaceList.Count) + " 个文件，覆盖 " + $replaceList.Count + " 个文件")
    if ($replaceList.Count -gt 0) {
        foreach ($r in $replaceList) { Write-Host ("    ~ " + $r.Rel) -ForegroundColor DarkYellow }
    }
    Write-Host ""

    # ---- 备份 + 复制 ----
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $backupDir = Join-Path $stateDir 'backup'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($item in $plan) {
        $dst = Join-Path $BinX64 $item.Rel
        $parent = Split-Path -Path $dst -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

        if (Test-Path -LiteralPath $dst) {
            $bpath = Join-Path $backupDir $item.Rel
            $bparent = Split-Path -Path $bpath -Parent
            if (-not (Test-Path -LiteralPath $bparent)) { New-Item -ItemType Directory -Path $bparent -Force | Out-Null }
            Copy-Item -LiteralPath $dst -Destination $bpath -Force
            $entries.Add([pscustomobject]@{ path = $item.Rel; action = 'replaced' })
        } else {
            $entries.Add([pscustomobject]@{ path = $item.Rel; action = 'added' })
        }
        Copy-Item -LiteralPath $item.Src -Destination $dst -Force
    }
    Write-Ok "文件复制完成"

    # ---- 改 ini ----
    $iniPath = Join-Path $BinX64 'OptiScaler.ini'
    if (-not $NoIni) {
        if (-not (Test-Path -LiteralPath $iniPath)) { throw "没找到 $iniPath，无法写入 [Capture] 配置。" }
        $ini = Read-IniFile $iniPath
        Set-IniValue $ini.Lines 'Capture' 'Enabled' 'true'
        Set-IniValue $ini.Lines 'Capture' 'FrameStride' "$FrameStride"
        Set-IniValue $ini.Lines 'Capture' 'MaxFrames' '0'
        Set-IniValue $ini.Lines 'Capture' 'CaptureColor' 'true'
        Set-IniValue $ini.Lines 'Capture' 'CaptureMotion' 'true'
        Set-IniValue $ini.Lines 'Capture' 'CaptureDepth' $(if ($CaptureDepth) { 'true' } else { 'false' })
        Set-IniValue $ini.Lines 'Capture' 'CaptureExposure' $(if ($CaptureExposure) { 'true' } else { 'false' })
        Set-IniValue $ini.Lines 'Hotfix' 'ColorResourceBarrier' '64'
        Set-IniValue $ini.Lines 'Hotfix' 'MotionVectorResourceBarrier' '64'
        Write-IniFile $iniPath $ini.Lines $ini.HasBom
        Write-Ok "OptiScaler.ini 已配置：[Capture] Enabled=true, FrameStride=$FrameStride；[Hotfix] barrier=64"
    }

    # ---- 写 manifest ----
    $manifest = [ordered]@{
        toolVersion = 2
        installedAt = (Get-Date).ToString('o')
        gameBinX64  = $BinX64
        proxy       = $proxyFile
        scalerDir   = $SDir
        cetDir      = $CDir
        entries     = $entries.ToArray()
    }
    $json = $manifest | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($mfPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "安装记录：$mfPath"

    Write-Host ""
    Write-Ok "安装完成。"
    Write-Host ""
    Write-Host "  代理 dll : " -NoNewline; Write-Host $proxyFile -ForegroundColor White
    Write-Host "  游戏目录 : " -NoNewline; Write-Host $BinX64 -ForegroundColor White
    Write-Host ""
    Write-Host "  进游戏后（~ 打开 CET 控制台）：" -ForegroundColor White
    Write-Host "    OptiCaptureStart    # 开始采集"
    Write-Host "    OptiCaptureStatus   # 查状态"
    Write-Host "    OptiCaptureStop     # 停止并收尾"
    Write-Host ""
    Write-Host "  采集输出：" -ForegroundColor White
    Write-Host ("    " + (Join-Path $BinX64 $MOD_REL) + "\session_[时间戳]\")
    Write-Host ""
    Write-Host "  卸载： .\uninstall.bat   （或 uninstall.ps1 uninstall `"$BinX64`"）" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- uninstall

function Invoke-Uninstall {
    param([string]$BinX64)

    $stateDir = Join-Path $BinX64 $STATE_DIR_NAME
    $mfPath = Join-Path $stateDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $mfPath)) {
        throw "没找到安装记录：$mfPath`n（可能从未安装，或游戏目录不对，或已被手工删掉）"
    }

    $mf = Get-Content -LiteralPath $mfPath -Raw | ConvertFrom-Json
    $backupDir = Join-Path $stateDir 'backup'

    $deleted = 0
    $restored = 0
    $missing = 0

    foreach ($e in $mf.entries) {
        $dst = Join-Path $BinX64 $e.path
        if ($e.action -eq 'added') {
            if (Test-Path -LiteralPath $dst) {
                Remove-Item -LiteralPath $dst -Force
                $deleted++
            }
        } else {
            $b = Join-Path $backupDir $e.path
            if (Test-Path -LiteralPath $b) {
                $parent = Split-Path -Path $dst -Parent
                if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                Copy-Item -LiteralPath $b -Destination $dst -Force
                $restored++
            } else {
                $missing++
            }
        }
    }

    foreach ($rel in $CLEAN_DIRS) {
        Remove-EmptyDir (Join-Path $BinX64 $rel)
    }

    if (Test-Path -LiteralPath $stateDir) { Remove-Item -LiteralPath $stateDir -Recurse -Force }

    Write-Host ""
    Write-Ok "卸载完成：删除 $deleted 个文件，还原 $restored 个文件"
    if ($missing -gt 0) { Write-Warn2 "$missing 个被覆盖文件没有备份（可能上次是 -Force 安装），未还原" }
    Write-Host ""
    Write-Host "  注意：OptiScaler.log / 采集出的 session_* 目录未删除，需要的话手工清。" -ForegroundColor DarkGray
    Write-Host "        如果装了 ReShade 等被顶掉的 dxgi.dll，本次已按备份还原。" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- status

function Invoke-Status {
    param([string]$BinX64)
    $stateDir = Join-Path $BinX64 $STATE_DIR_NAME
    $mfPath = Join-Path $stateDir 'manifest.json'
    Write-Host ""
    Write-Host "  游戏目录 : $BinX64"
    if (-not (Test-Path -LiteralPath $mfPath)) {
        Write-Warn2 "未安装（没有 $mfPath）"
        return
    }
    $mf = Get-Content -LiteralPath $mfPath -Raw | ConvertFrom-Json
    Write-Ok "已安装"
    Write-Host ("  安装时间 : " + $mf.installedAt)
    Write-Host ("  代理 dll : " + $mf.proxy)
    Write-Host ("  记录条目 : " + @($mf.entries).Count)
    $added = @($mf.entries | Where-Object { $_.action -eq 'added' }).Count
    $repl = @($mf.entries | Where-Object { $_.action -eq 'replaced' }).Count
    Write-Host ("           新增 $added / 覆盖 $repl")
    Write-Host ""
}

# ---------------------------------------------------------------- main

function Main {
    $bin = Resolve-BinX64 $GamePath
    if (-not $bin) {
        if (-not $GamePath) {
            $auto = Get-AutoGamePath
            if ($auto) { $bin = Resolve-BinX64 $auto }
        }
    }
    if (-not $bin) {
        Write-Err "找不到游戏目录（bin\x64 下应有 Cyberpunk2077.exe）。"
        Write-Host "  请显式指定，例如："
        Write-Host "    .\opti-capture-install.ps1 $Command -GamePath `"D:\Steam\steamapps\common\Cyberpunk 2077`""
        exit 2
    }

    Write-Host ""
    Write-Host "== 离线 DLSS5 采集端 · $Command ==" -ForegroundColor Magenta
    Write-Info "游戏 bin\x64: $bin"

    switch ($Command) {
        'install'   { Invoke-Install   -BinX64 $bin -SDir $ScalerDir -CDir $CetDir -ProxyName $Proxy }
        'uninstall' { Invoke-Uninstall -BinX64 $bin }
        'status'    { Invoke-Status    -BinX64 $bin }
    }
}

try {
    Main
    exit 0
} catch {
    Write-Host ""
    Write-Err $_.Exception.Message
    exit 1
}
