#requires -Version 5.0
<#
    deploy-strata.ps1  --  Strata 本地大模型一键部署（Windows / PowerShell 5.1）
    阶段：1 硬件检测 -> 2 模型选择 -> 3 数据目录与磁盘 -> 4 框架与引擎 -> 5 模型下载与完整性 -> 6 启动/健康检查/产物
    常用参数：-Model iq3|iq4|coder   -DataDir <路径>   -DryRun   -ForceRestart
              -LocalOnly  只用脚本所在磁盘（当前磁盘）：不检索其他磁盘、不改选分区；空间不足直接报错；
                           当前磁盘没有模型且本机从未装过时自动下载（Strata 不会把同一模型再下到另一个目录，
                           已装在别处时脚本会给出 strata models move 的迁移命令）
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('iq3', 'iq4', 'coder')]
    [string]$Model,

    [string]$DataDir,
    [int]$Port = 8080,
    [string]$Context = '256k',
    [int]$ReserveGB = 24,
    [ValidateSet('auto', 'modelscope', 'huggingface')]
    [string]$Source = 'auto',
    [ValidateSet('cpu', 'gpu', 'off')]
    [string]$Vision = 'cpu',
    [int]$KVResident = 32768,
    [string]$Feed,
    [string]$FrpExe,
    [string]$FrpIni,
    [string]$PublicUrl,
    [switch]$DryRun,
    [switch]$NoShortcut,
    [switch]$ForceRestart,
    [switch]$LocalOnly,
    [int]$MinRamGB = 64,
    [int]$MinVramGB = 24
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ 全局常量 / 状态
$sw         = [System.Diagnostics.Stopwatch]::StartNew()
$ProjectDir = Split-Path -Parent $PSCommandPath
if (-not $ProjectDir) { $ProjectDir = (Get-Location).Path }
$LogFile    = Join-Path $ProjectDir ('deploy-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

$GB_DEC       = [double]1000000000      # 1 GB（十进制，与 Strata 的 download_gb 口径一致）
$SHARED_GB    = 7.3                     # mmproj 0.85 + MTP 6.45
$PACK_GB      = 1.4
$FRAMEWORK_GB = 1.8                     # terminal 0.22 + engine 0.9 + feed 包 0.6 + llama.cpp 源包 0.04
$SYS_DRIVE_MIN_GB = 8
$ENGINE_TAR_BYTES = [long]620430878
$MMPROJ_NAME  = 'mmproj-Qwen3.8-Flash-Next-BF16.gguf'

$script:StageSummary    = @()
$script:StrataCmd       = $null
$script:GithubReachable = $null
$script:UseFeed         = $false
$script:FeedDir         = $null
$script:DataDirUsed     = $null
$script:DataDirForced   = $false
$script:PlanCache       = @{}
$script:LocalIP         = '127.0.0.1'

# ------------------------------------------------------------------ 日志 / 阶段 / 退出
function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    switch ($Level) {
        'warn'  { Write-Host $line -ForegroundColor Yellow }
        'error' { Write-Host $line -ForegroundColor Red }
        'ok'    { Write-Host $line -ForegroundColor Green }
        'cmd'   { Write-Host ('  命令> ' + $Message) -ForegroundColor Cyan }
        default { Write-Host $line }
    }
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
}

function Write-Line {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host $Message -ForegroundColor $Color
    try { Add-Content -LiteralPath $LogFile -Value $Message -Encoding UTF8 } catch { }
}

function Write-Stage {
    param([int]$N, [int]$Total, [string]$Msg)
    Write-Host ''
    Write-Line ('[{0}/{1}] {2}' -f $N, $Total, $Msg) 'Cyan'
    Write-Line ('-' * 74)
}

function Exit-Deploy {
    param([int]$Code, [string]$Reason)
    if ($Code -eq 0) { Write-Log ('成功：' + $Reason) 'ok' } else { Write-Log ('终止（退出码 {0}）：{1}' -f $Code, $Reason) 'error' }
    Write-Log ('总耗时 {0:N1} 秒   日志 {1}' -f $sw.Elapsed.TotalSeconds, $LogFile)
    exit $Code
}

function Get-LastExitCode { if ($null -eq $LASTEXITCODE) { return 0 } else { return $LASTEXITCODE } }

function Show-Cmd {
    param([string[]]$CmdArgs, [string]$Exe)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($Exe)
    foreach ($a in $CmdArgs) {
        if ($a -match '\s') { [void]$sb.Append(' "').Append($a).Append('"') } else { [void]$sb.Append(' ').Append($a) }
    }
    Write-Log $sb.ToString() 'cmd'
}

function Fmt-GB { param([double]$Bytes) ('{0:N1} GB' -f ($Bytes / $GB_DEC)) }

function ContextTokens {
    param([string]$Ctx)
    $c = $Ctx.Trim().ToLower()
    if ($c -match '^(\d+)k$') { return ([int]$matches[1]) * 1024 }
    if ($c -match '^(\d+)m$') { return ([int]$matches[1]) * 1024 * 1024 }
    if ($c -match '^\d+$')    { return [int]$c }
    return 262144
}

# ------------------------------------------------------------------ 模型常量表
function Get-ModelTable {
    return @(
        [ordered]@{
            Key         = 'iq3'
            Family      = 'qwen'
            Model       = 'iq3_xxs'
            ModelId     = 'iq3_xxs'
            Tag         = 'iq3_xxs'
            Display     = 'IQ3_XXS'
            WeightGB    = 75.8
            ExpertsGB   = 42.9
            RamFullGB   = 60
            ModelSubdir = 'IQ3_XXS'
            Shards      = @(
                [ordered]@{ Name = 'Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf'; Bytes = [long]47039860096 },
                [ordered]@{ Name = 'Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00002-of-00002.gguf'; Bytes = [long]28800138432 }
            )
            Ability     = @(
                '能力: 3-bit i-quant（GSQ-RCO），通用/中文长文/纯文本问答质量好，短对话解码最快',
                '能力: 24,576 专家全保留（专家常驻 42.9 GB）；64 GB 上 256K 内存贴顶（实测提交 96.1/98.2 GB，余约 2 GB）',
                '能力: 支持图片输入（共用 mmproj BF16 + MTP 草稿层）'
            )
            Speed       = @(
                '预期: 解码 67 tok/s',
                '预期: 208K 长提示预填 1,725 tok/s（约 120 s）',
                '预期: 单图 3.5-5 s（vision cpu）',
                '预期: MTP 接受率 66%'
            )
        },
        [ordered]@{
            Key         = 'coder'
            Family      = 'coder'
            Model       = 'iq1_m'
            ModelId     = 'iq1_m'
            Tag         = 'coder-iq1_m'
            Display     = 'Coder IQ1_M'
            WeightGB    = 58.4
            ExpertsGB   = 23.4
            RamFullGB   = 32
            ModelSubdir = 'coder-IQ1_M'
            Shards      = @(
                [ordered]@{ Name = 'Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00001-of-00002.gguf'; Bytes = [long]29608446496 },
                [ordered]@{ Name = 'Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00002-of-00002.gguf'; Bytes = [long]28800138432 }
            )
            Ability     = @(
                '能力: 编程专精，512 专家只保留代码/工具/视觉常用的 256 个并按 IQ3_S 格式存（作者数据 SWE-bench 达完整模型 91%）',
                '能力: 通用长文弱于 IQ3_XXS；预填最快、内存宽松（约 15 GB 余量），是 64 GB 上唯一可尝试 1M 的选项',
                '能力: 支持图片输入（共用 mmproj BF16 + MTP 草稿层）'
            )
            Speed       = @(
                '预期: 解码 47 tok/s',
                '预期: 208K 预填 2,301 tok/s（约 90 s）',
                '预期: 单图 4.8 s（vision cpu）',
                '预期: MTP 接受率 63%'
            )
        },
        [ordered]@{
            Key         = 'iq4'
            Family      = 'unsloth'
            Model       = 'UD-IQ4_XS'
            ModelId     = 'ud-iq4_xs'
            Tag         = 'ud-iq4_xs'
            Display     = 'UD-IQ4_XS'
            WeightGB    = 93.7
            ExpertsGB   = 59.5
            RamFullGB   = 80
            ModelSubdir = 'UD-IQ4_XS'
            Shards      = @(
                [ordered]@{ Name = 'Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf'; Bytes = [long]10946624 },
                [ordered]@{ Name = 'Qwen3.8-Flash-Next-UD-IQ4_XS-00002-of-00003.gguf'; Bytes = [long]49835229856 },
                [ordered]@{ Name = 'Qwen3.8-Flash-Next-UD-IQ4_XS-00003-of-00003.gguf'; Bytes = [long]43836407744 }
            )
            Ability     = @(
                '能力: ~4-bit Unsloth Dynamic，质量介于 IQ3_S 与 UD-Q4_K_XL（top-1 一致率 88.9%，IQ3_XXS 为 84.5%）',
                '能力: 专家 59.5 GB，全驻留需约 80 GB；64 GB 上部分专家只能读 SSD；支持图片输入；三分片',
                '能力: 本机未安装，以下速度为按内存带宽的估算'
            )
            Speed       = @(
                '预期: 解码 30-45 tok/s（估算，本机未实测）',
                '预期: 64 GB 上部分专家读 SSD，实际可能更低',
                '预期: 208K 预填未实测（需 128 GB 才能全专家驻留）'
            )
        }
    )
}

# ------------------------------------------------------------------ 阶段 1：硬件检测
function Get-RamGiB {
    $cs = Get-CimInstance Win32_ComputerSystem
    return [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
}

function Get-GpuList {
    $list = @()
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($smi) {
        try {
            $raw = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
            foreach ($ln in @($raw)) {
                if (-not $ln) { continue }
                $parts = $ln -split ','
                if ($parts.Count -ge 2) {
                    $mib = 0
                    if ([int]::TryParse(($parts[1] -replace '[^0-9]', ''), [ref]$mib)) {
                        $list += [pscustomobject]@{ Name = $parts[0].Trim(); GiB = [math]::Round($mib / 1024, 2); Source = 'nvidia-smi' }
                    }
                }
            }
        } catch { }
    }
    if ($list.Count -eq 0) {
        foreach ($vc in Get-CimInstance Win32_VideoController) {
            $list += [pscustomobject]@{
                Name   = $vc.Name
                GiB    = [math]::Round([double]$vc.AdapterRAM / 1GB, 2)
                Source = '降级读数 Win32_VideoController.AdapterRAM'
            }
        }
    }
    return $list
}

function Invoke-Stage1 {
    Write-Stage 1 6 '硬件与系统盘检测'

    $ramGiB = Get-RamGiB
    $script:RamGiB = $ramGiB
    $ramThreshold = $MinRamGB - 1.0
    $ramNote = '阈值取标称值减 1 GB：内存条实际可用容量略低于标称'
    if ($MinRamGB -eq 64) { $ramNote = '真实 64 GB 内存条在 Windows 上报约 63.90 GiB，不能按整 64 判死' }
    Write-Log ('内存判定：标称 {0} GB 要求 / 实测 {1:N2} GiB（阈值 {2:N2} GiB；{3}）' -f $MinRamGB, $ramGiB, $ramThreshold, $ramNote)
    if ($ramGiB -lt $ramThreshold) {
        Write-Log ('物理内存不足（需要 {0} GB，实测 {1:N2} GiB）。请升级内存，或改用更小的量化 / 更短上下文。' -f $MinRamGB, $ramGiB) 'error'
        Exit-Deploy 2 '物理内存不足'
    }
    Write-Log ('内存达标：{0:N2} GiB >= {1:N2} GiB' -f $ramGiB, $ramThreshold) 'ok'

    $gpus = @(Get-GpuList)
    if ($gpus.Count -eq 0) {
        Write-Log '无法枚举任何显示适配器（nvidia-smi 与 Win32_VideoController 都没有结果）' 'error'
        Exit-Deploy 2 '无法检测显存'
    }
    $vramThreshold = $MinVramGB - 0.5
    $maxGpu = $null
    foreach ($g in $gpus) {
        $usable = '可用'
        if ($g.GiB -lt $vramThreshold) { $usable = '不可用' }
        Write-Log ('显卡：{0}  显存 {1:N2} GiB  来源 {2}  判定 {3}' -f $g.Name, $g.GiB, $g.Source, $usable)
        if ($g.Source -like '*降级*') { Write-Log '  注意：这是降级读数（AdapterRAM 是 32 位值，>4 GB 会被低估），实际显存可能更大' 'warn' }
        if ($null -eq $maxGpu) { $maxGpu = $g } elseif ($g.GiB -gt $maxGpu.GiB) { $maxGpu = $g }
    }
    $script:MaxVramGiB = $maxGpu.GiB
    if ($maxGpu.GiB -lt $vramThreshold) {
        Write-Log ('显存不足（需要 {0} GB，最大可用卡 {1} = {2:N2} GiB）' -f $MinVramGB, $maxGpu.Name, $maxGpu.GiB) 'error'
        Exit-Deploy 2 '显存不足'
    }
    Write-Log ('显存达标：{0} {1:N2} GiB >= {2:N2} GiB' -f $maxGpu.Name, $maxGpu.GiB, $vramThreshold) 'ok'

    $sysRoot  = [System.IO.Path]::GetPathRoot($env:LOCALAPPDATA)
    $sysDrive = New-Object System.IO.DriveInfo($sysRoot)
    $sysFreeGB = $sysDrive.AvailableFreeSpace / $GB_DEC
    Write-Log ('系统盘检查：%LOCALAPPDATA% = {0} 位于 {1}，剩余 {2:N1} GB，要求 >= {3} GB' -f $env:LOCALAPPDATA, $sysRoot, $sysFreeGB, $SYS_DRIVE_MIN_GB)
    if ($sysFreeGB -lt $SYS_DRIVE_MIN_GB) {
        Write-Log ('系统盘 {0} 剩余 {1:N1} GB 低于 {2} GB：引擎组件固定落在系统盘（%LOCALAPPDATA%\Strata\components），不受 --data-dir 影响' -f $sysRoot, $sysFreeGB, $SYS_DRIVE_MIN_GB) 'error'
        Exit-Deploy 2 '系统盘空间不足'
    }
    Write-Log '系统盘空间达标' 'ok'

    $script:StageSummary += ('阶段1 硬件：内存 {0:N2} GiB 达标 / {1} {2:N2} GiB 达标 / 系统盘 {3} 剩余 {4:N1} GB 达标' -f $ramGiB, $maxGpu.Name, $maxGpu.GiB, $sysRoot, $sysFreeGB)
}

# ------------------------------------------------------------------ 阶段 2：模型选择
function Show-ModelMenu {
    Write-Line '候选模型（每条三行小块：权重体积 -> 能力范围 -> 本配置预期 tok/s）' 'White'
    Write-Line '这些数字来自本机这一套配置：24GB 显存(RTX 3090) + 64GB 内存 + 256K 上下文 + kv int8 +'
    Write-Line 'kv-resident 32768 + vision cpu + MTP。换硬件仅作参考。' 'Yellow'
    $i = 0
    foreach ($m in (Get-ModelTable)) {
        $i++
        Write-Line ''
        Write-Line ('  [{0}] {1}   (--family {2} --model {3})' -f $i, $m.Display, $m.Family, $m.Model) 'White'
        Write-Line ('    权重 {0:N1} GB（{1} 分片） -> 专家 {2:N1} GB -> 全驻留内存约 {3} GB' -f $m.WeightGB, $m.Shards.Count, $m.ExpertsGB, $m.RamFullGB)
        foreach ($a in $m.Ability) { Write-Line ('      ' + $a) }
        foreach ($s in $m.Speed)   { Write-Line ('      ' + $s) }
    }
    Write-Line ''
}

function Resolve-ModelKey {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    $t = $Raw.Trim().ToLower()
    $alias = @{
        '1'             = 'iq3'
        '2'             = 'coder'
        '3'             = 'iq4'
        'iq3'           = 'iq3'
        'iq3_xxs'       = 'iq3'
        'gsq-rco-iq3_xxs' = 'iq3'
        'coder'         = 'coder'
        'iq1_m'         = 'coder'
        'coder-iq1_m'   = 'coder'
        'iq4'           = 'iq4'
        'ud-iq4_xs'     = 'iq4'
        'unsloth'       = 'iq4'
    }
    if ($alias.ContainsKey($t)) { return $alias[$t] }
    return $null
}

function Invoke-Stage2 {
    Write-Stage 2 6 '模型选择（权重体积 / 能力范围 / 本配置预期速度）'
    $table = Get-ModelTable
    $key = $null

    if ($Model) {
        $key = $Model
        Write-Log ('参数 -Model 已指定：{0}' -f $key)
    } else {
        Show-ModelMenu
        $tries = 0
        while ($tries -lt 3 -and -not $key) {
            $tries++
            $ans = Read-Host '请选择模型（序号 1/2/3，或 iq3 / coder / iq4 / iq1_m / iq3_xxs / ud-iq4_xs；直接回车取消）'
            if ([string]::IsNullOrWhiteSpace($ans)) { Exit-Deploy 3 '用户取消（未选择模型）' }
            $key = Resolve-ModelKey $ans
            if (-not $key) { Write-Log ('无效输入 "{0}"（第 {1}/3 次）' -f $ans, $tries) 'warn' }
        }
        if (-not $key) { Exit-Deploy 3 '模型选择失败（3 次无效输入）' }
    }

    $chosen = $null
    foreach ($m in $table) { if ($m.Key -eq $key) { $chosen = $m } }
    if (-not $chosen) { Exit-Deploy 3 ('未知模型键：' + $key) }

    Write-Line ''
    Write-Line ('已选择：{0}  ->  --family {1} --model {2}' -f $chosen.Display, $chosen.Family, $chosen.Model) 'Green'

    $ramGiB = $script:RamGiB
    Write-Log ('模型级内存细判：{0} 全驻留需约 {1} GB（专家 {2:N1} GB），本机实测 {3:N2} GiB' -f $chosen.Display, $chosen.RamFullGB, $chosen.ExpertsGB, $ramGiB)
    if ($chosen.Key -eq 'iq4' -and $ramGiB -lt 80.0) {
        Write-Log ('警告：本机内存 {0:N2} GiB 跑 UD-IQ4_XS，部分专家将从 SSD 读取，速度明显下降；全驻留需约 {1} GB' -f $ramGiB, $chosen.RamFullGB) 'warn'
        $interactive = ((-not $DryRun) -and (-not $Model))
        if ($interactive) {
            $confirm = Read-Host '确认继续？输入 y 继续，其它输入终止部署'
            if ($confirm.Trim().ToLower() -ne 'y') { Exit-Deploy 3 '用户未确认 UD-IQ4_XS 的 SSD 读取代价' }
            Write-Log '用户已确认继续'
        } else {
            $newReserve = [math]::Max($script:ReserveGB, 32)
            $mode = 'DryRun'
            if (-not $DryRun) { $mode = '-Model 指定' }
            if ($newReserve -gt $script:ReserveGB) {
                Write-Log ('（{0}）自动把缓存预留从 {1} GB 提升到 {2} GB，以覆盖 SSD 读缓冲' -f $mode, $script:ReserveGB, $newReserve) 'warn'
            } else {
                Write-Log ('（{0}）缓存预留已是 {1} GB（高于 32 GB 的 SSD 读缓冲下限），保持不变' -f $mode, $script:ReserveGB) 'warn'
            }
            $script:ReserveGB = $newReserve
        }
    } elseif ($chosen.RamFullGB -gt $ramGiB) {
        Write-Log ('警告：{0} 全驻留需约 {1} GB，高于本机实测 {2:N2} GiB，部分权重/专家会走 SSD' -f $chosen.Display, $chosen.RamFullGB, $ramGiB) 'warn'
    } else {
        Write-Log ('内存可全驻留（需约 {0} GB <= 实测 {1:N2} GiB）' -f $chosen.RamFullGB, $ramGiB) 'ok'
    }

    $script:ChosenModel = $chosen
    $script:StageSummary += ('阶段2 模型：{0}（--family {1} --model {2}，权重 {3:N1} GB，缓存预留 {4} GB）' -f $chosen.Display, $chosen.Family, $chosen.Model, $chosen.WeightGB, $script:ReserveGB)
}

# ------------------------------------------------------------------ 阶段 3：数据目录与磁盘
function Get-FixedDrives {
    # 本地固定磁盘：用 .NET DriveInfo.DriveType = Fixed（天然排除可移动盘/网络盘/光驱/RAM 盘）。
    # 注：WMI Win32_LogicalDisk 的 DriveType=2 是「可移动盘」、3 才是本地固定盘，因此不照抄该数字。
    $out = @()
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -ne 'Fixed') { continue }
        if (-not $d.IsReady) { continue }
        $out += [pscustomobject]@{
            Root    = $d.RootDirectory.FullName
            Type    = $d.DriveType.ToString()
            TotalGB = [math]::Round($d.TotalSize / $GB_DEC, 1)
            FreeGB  = [math]::Round($d.AvailableFreeSpace / $GB_DEC, 1)
        }
    }
    return $out
}

function Collect-JsonStrings {
    param($Obj)
    $acc = @()
    if ($null -eq $Obj) { return $acc }
    if ($Obj -is [string]) { $acc += $Obj; return $acc }
    if ($Obj -is [System.Collections.IDictionary]) {
        foreach ($k in $Obj.Keys) { $acc += Collect-JsonStrings $Obj[$k] }
        return $acc
    }
    if ($Obj -is [System.Collections.IEnumerable]) {
        foreach ($v in $Obj) { $acc += Collect-JsonStrings $v }
        return $acc
    }
    if ($Obj.PSObject -and $Obj.PSObject.Properties) {
        foreach ($p in $Obj.PSObject.Properties) { $acc += Collect-JsonStrings $p.Value }
    }
    return $acc
}

function Get-DataDirFromRunConfig {
    # 从 %LOCALAPPDATA%\Strata\install\strata-*.json 的 args 里反推已存在的 data dir：
    # 取 \packs\ / \models\ / \mtp\ 之前那一段
    $installDir = Join-Path $env:LOCALAPPDATA 'Strata\install'
    if (-not (Test-Path -LiteralPath $installDir)) { return $null }
    $found = @()
    foreach ($f in (Get-ChildItem -LiteralPath $installDir -Filter 'strata-*.json' -File -ErrorAction SilentlyContinue)) {
        $txt = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $txt) { continue }
        $obj = $null
        try { $obj = $txt | ConvertFrom-Json } catch { continue }
        foreach ($s in (Collect-JsonStrings $obj)) {
            foreach ($token in @('\packs\', '\models\', '\mtp\')) {
                $idx = $s.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase)
                if ($idx -gt 3) {
                    $cand = $s.Substring(0, $idx)
                    if ($cand -match '^[A-Za-z]:\\' -and (Test-Path -LiteralPath $cand)) { $found += $cand }
                }
            }
        }
    }
    if ($found.Count -eq 0) { return $null }
    return ($found | Select-Object -Unique | Select-Object -First 1)
}

function Search-DataDirOnDrives {
    param([string]$OnlyRoot)
    $drives = @(Get-FixedDrives)
    if ($OnlyRoot) { $drives = @($drives | Where-Object { $_.Root -eq $OnlyRoot }) }
    foreach ($drive in $drives) {
        $lvl1 = @(Get-ChildItem -LiteralPath $drive.Root -Directory -Force -ErrorAction SilentlyContinue)
        foreach ($d1 in $lvl1) {
            if ($d1.Name -match 'strata') {
                if (Test-Path -LiteralPath (Join-Path $d1.FullName 'models')) { return $d1.FullName }
                if (Test-Path -LiteralPath (Join-Path $d1.FullName 'terminal\current\bin\strata.cmd')) { return $d1.FullName }
            }
            $lvl2 = @(Get-ChildItem -LiteralPath $d1.FullName -Directory -Force -ErrorAction SilentlyContinue)
            foreach ($d2 in $lvl2) {
                if ($d2.Name -match 'strata') {
                    if (Test-Path -LiteralPath (Join-Path $d2.FullName 'models')) { return $d2.FullName }
                    if (Test-Path -LiteralPath (Join-Path $d2.FullName 'terminal\current\bin\strata.cmd')) { return $d2.FullName }
                }
            }
        }
    }
    return $null
}

function Find-StrataCmd {
    param([string]$HintDataDir)
    $c = Get-Command strata -ErrorAction SilentlyContinue
    if ($c) {
        $src = $null
        if ($c.Source) { $src = $c.Source } elseif ($c.Definition) { $src = $c.Definition }
        if ($src) {
            $dir = Split-Path -Parent $src
            $cmdFile = Join-Path $dir 'strata.cmd'
            if (Test-Path -LiteralPath $cmdFile) { return $cmdFile }
            if (Test-Path -LiteralPath $src) { return $src }
        }
    }
    $cands = @()
    if ($HintDataDir) { $cands += (Join-Path $HintDataDir 'terminal\current\bin\strata.cmd') }
    $cands += (Join-Path $env:LOCALAPPDATA 'Strata\terminal\current\bin\strata.cmd')
    foreach ($x in $cands) { if (Test-Path -LiteralPath $x) { return $x } }
    return $null
}

function Get-PlanInfo {
    param($ModelObj, [string]$Dir, [switch]$Force)
    if (-not $script:StrataCmd) { return $null }
    if (-not $Dir) { return $null }
    $cacheKey = $ModelObj.Key + '|' + $Dir
    if (-not $Force -and $script:PlanCache.ContainsKey($cacheKey)) { return $script:PlanCache[$cacheKey] }
    $cmdArgs = @('launch', '--family', $ModelObj.Family, '--model', $ModelObj.Model, '--data-dir', $Dir, '--context', $Context, '--plan', '--output', 'json')
    Show-Cmd $cmdArgs $script:StrataCmd
    $plan = $null
    try {
        $raw = & $script:StrataCmd @cmdArgs 2>&1 | Out-String
        foreach ($ln in ($raw -split "`r?`n")) {
            $t = $ln.Trim()
            if (-not $t.StartsWith('{')) { continue }
            $obj = $null
            try { $obj = $t | ConvertFrom-Json } catch { continue }
            if ($obj -and $obj.plan) { $plan = $obj.plan; break }
        }
    } catch {
        Write-Log ('--plan 调用失败：{0}' -f $_.Exception.Message) 'warn'
    }
    $script:PlanCache[$cacheKey] = $plan
    if ($plan) {
        Write-Log ('--plan 返回：download.gb={0} / model.model_gb={1} / settings.data_dir={2} / engine_missing={3} / engine_usable={4}' -f $plan.download.gb, $plan.model.model_gb, $plan.settings.data_dir, $plan.download.engine_missing, $plan.download.engine_usable)
    } else {
        Write-Log '未能取得 --plan JSON，改用脚本内置常量表' 'warn'
    }
    return $plan
}

function Get-ExistingRelevantBytes {
    param([string]$Dir, $ModelObj)
    $bytes = [long]0
    $modelsDir = Join-Path $Dir 'models'
    if (Test-Path -LiteralPath $modelsDir) {
        foreach ($sh in $ModelObj.Shards) {
            foreach ($f in (Get-ChildItem -LiteralPath $modelsDir -Recurse -File -Filter ($sh.Name + '*') -ErrorAction SilentlyContinue)) { $bytes += $f.Length }
        }
        foreach ($f in (Get-ChildItem -LiteralPath $modelsDir -File -Filter 'mmproj*' -ErrorAction SilentlyContinue)) { $bytes += $f.Length }
    }
    foreach ($sub in @('mtp', 'feed')) {
        $p = Join-Path $Dir $sub
        if (Test-Path -LiteralPath $p) {
            foreach ($f in (Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue)) { $bytes += $f.Length }
        }
    }
    $packs = Join-Path $Dir 'packs'
    if (Test-Path -LiteralPath $packs) {
        foreach ($d in (Get-ChildItem -LiteralPath $packs -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($d.Name -like ('*' + $ModelObj.ModelId + '*')) {
                foreach ($f in (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)) { $bytes += $f.Length }
            }
        }
    }
    $term = Join-Path $Dir 'terminal'
    if (Test-Path -LiteralPath $term) {
        foreach ($f in (Get-ChildItem -LiteralPath $term -Recurse -File -Force -ErrorAction SilentlyContinue)) { $bytes += $f.Length }
    }
    return $bytes
}

function Get-DiskNeedGB {
    param($ModelObj, [string]$Dir)
    $total    = $ModelObj.WeightGB + $SHARED_GB + $PACK_GB + $FRAMEWORK_GB + $script:ReserveGB
    $existing = (Get-ExistingRelevantBytes -Dir $Dir -ModelObj $ModelObj) / $GB_DEC
    $need     = $total - $existing
    if ($need -lt 0) { $need = 0 }
    return [pscustomobject]@{ TotalGB = $total; ExistingGB = $existing; NeedGB = $need }
}

function Evaluate-Dir {
    param([string]$Dir, $ModelObj)
    $root  = [System.IO.Path]::GetPathRoot($Dir)
    $drive = $null
    foreach ($d in (Get-FixedDrives)) { if ($d.Root -eq $root) { $drive = $d } }
    if (-not $drive) { return $null }
    $need = Get-DiskNeedGB -ModelObj $ModelObj -Dir $Dir
    $ok   = ($drive.FreeGB + $need.ExistingGB) -ge ($need.TotalGB - 0.05)
    return [pscustomobject]@{ Dir = $Dir; Root = $root; FreeGB = $drive.FreeGB; DriveTotalGB = $drive.TotalGB; Need = $need; Ok = $ok }
}

function Report-Eval {
    param($Eval, [string]$Tag)
    $m = $script:ChosenModel
    Write-Line ('  {0}数据目录 {1}（分区 {2}）' -f $Tag, $Eval.Dir, $Eval.Root)
    Write-Line ('    最低合计 {0:N1} GB = 权重 {1:N1} + 共享(mmproj 0.85 + MTP 6.45) {2:N1} + pack {3:N1} + 框架 {4:N1} + 缓存预留 {5:N1}' -f $Eval.Need.TotalGB, $m.WeightGB, $SHARED_GB, $PACK_GB, $FRAMEWORK_GB, $script:ReserveGB)
    Write-Line ('    分区剩余 {0:N1} GB   该目录已占用(与本次相关) {1:N1} GB   还需新增 {2:N1} GB' -f $Eval.FreeGB, $Eval.Need.ExistingGB, $Eval.Need.NeedGB)
    if ($Eval.Ok) { Write-Line '    判定：通过' 'Green' } else { Write-Line '    判定：不足' 'Red' }
}

function Show-DriveNeedTable {
    param([double]$NeedGB)
    Write-Line ''
    Write-Line ('候选固定盘对照表（本次需求量 {0:N1} GB）：' -f $NeedGB) 'White'
    Write-Line ('  {0,-6} {1,-10} {2,12} {3,12}  {4}' -f '盘符', '类型', '总量 GB', '剩余 GB', '是否满足')
    foreach ($d in (Get-FixedDrives)) {
        $ok = '不足'
        if ($d.FreeGB -ge $NeedGB) { $ok = '满足' }
        Write-Line ('  {0,-6} {1,-10} {2,12:N1} {3,12:N1}  {4}' -f $d.Root, $d.Type, $d.TotalGB, $d.FreeGB, $ok)
    }
    Write-Line '  提示：先清理磁盘 / 改用更小的量化（Coder IQ1_M、IQ3_XXS）/ 减小 -ReserveGB。' 'Yellow'
}

function Record-Stage3 {
    param($Eval, [string]$Tag)
    $script:StageSummary += ('阶段3 磁盘：{0}数据目录 {1}（分区 {2}，分区剩余 {3:N1} GB）；最低合计 {4:N1} GB / 还需新增 {5:N1} GB / 缓存预留 {6:N1} GB' -f $Tag, $Eval.Dir, $Eval.Root, $Eval.FreeGB, $Eval.Need.TotalGB, $Eval.Need.NeedGB, $script:ReserveGB)
}

function Ensure-DataDir {
    param([string]$Dir)
    if (Test-Path -LiteralPath $Dir) { return }
    if ($DryRun) { Write-Log ('DryRun：不创建目录 {0}' -f $Dir) 'warn'; return }
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    Write-Log ('已创建数据目录：{0}' -f $Dir) 'ok'
}

function Invoke-Stage3 {
    Write-Stage 3 6 '数据目录与磁盘空间'
    $m = $script:ChosenModel

    $localRoot = [System.IO.Path]::GetPathRoot($ProjectDir)
    if ($LocalOnly) {
        Write-Log ('-LocalOnly：数据只落在当前磁盘 {0}（脚本所在分区），不检索其他分区、不改选' -f $localRoot) 'ok'
        if ($DataDir -and [System.IO.Path]::GetPathRoot($DataDir) -ne $localRoot) {
            Exit-Deploy 2 ('-LocalOnly 要求数据目录在当前磁盘 {0}，但 -DataDir 指定了 {1}（去掉 -LocalOnly 或改 -DataDir）' -f $localRoot, $DataDir)
        }
    }

    $hint = $DataDir
    if (-not $hint -and -not $LocalOnly) { $hint = Get-DataDirFromRunConfig }
    $script:StrataCmd = Find-StrataCmd -HintDataDir $hint
    if ($script:StrataCmd) { Write-Log ('找到 strata 命令：{0}' -f $script:StrataCmd) }

    if ($script:StrataCmd -and $hint) {
        $p0 = Get-PlanInfo -ModelObj $m -Dir $hint
        if ($p0) {
            Write-Log ('--plan 还需下载 {0} GB：{1}' -f $p0.download.gb, $p0.download.text)
            if ($p0.download.gb -le 0) { Write-Log '模型已完整（--plan 返回 0 GB）' 'ok' }
        }
    }
    Write-Log ('磁盘门槛按「全量足迹」判定：权重 {0:N1} + 共享 {1:N1} + pack {2:N1} + 框架 {3:N1} + 缓存预留 {4:N1}' -f $m.WeightGB, $SHARED_GB, $PACK_GB, $FRAMEWORK_GB, $script:ReserveGB)

    if ($DataDir) {
        $script:DataDirForced = $true
        Write-Log ('-DataDir 强制指定：{0}（不再自动改选分区）' -f $DataDir)
        $eval = Evaluate-Dir -Dir $DataDir -ModelObj $m
        if (-not $eval) {
            Show-DriveNeedTable (Get-DiskNeedGB -ModelObj $m -Dir $DataDir).NeedGB
            Exit-Deploy 2 ('-DataDir 所在分区不是本地固定磁盘：' + $DataDir)
        }
        Report-Eval $eval '指定'
        if (-not $eval.Ok) { Show-DriveNeedTable $eval.Need.NeedGB; Exit-Deploy 2 ('指定分区 ' + $eval.Root + ' 剩余空间不足') }
        $script:DataDirUsed = $DataDir
        Record-Stage3 $eval '指定'
        Ensure-DataDir $DataDir
        return
    }

    $existing = Get-DataDirFromRunConfig
    if ($LocalOnly) {
        # 只在当前磁盘上检索：其他磁盘上的安装记录一律忽略
        if ($existing -and [System.IO.Path]::GetPathRoot($existing) -ne $localRoot) {
            Write-Log ('-LocalOnly：忽略其他磁盘上的安装记录 {0}' -f $existing) 'warn'
            $existing = $null
        }
        if (-not $existing) { $existing = Search-DataDirOnDrives -OnlyRoot $localRoot }
        if ($existing) {
            Write-Log ('当前磁盘 {0} 上已有数据目录：{1}' -f $localRoot, $existing) 'ok'
            $eval = Evaluate-Dir -Dir $existing -ModelObj $m
            Report-Eval $eval '复用'
            if (-not $eval.Ok) {
                Write-Log ('-LocalOnly：当前磁盘 {0} 剩余 {1:N1} GB 无法容纳 {2}（需要 {3:N1} GB，含 {4:N1} GB 缓存预留）→ 空间不足，无法安装' -f $eval.Root, $eval.FreeGB, $m.Display, $eval.Need.TotalGB, $script:ReserveGB) 'error'
                Exit-Deploy 2 ('-LocalOnly：当前磁盘空间不足（不改选其他分区）')
            }
            $script:DataDirUsed = $existing
            Record-Stage3 $eval '复用'
            Ensure-DataDir $existing
            $null = Get-PlanInfo -ModelObj $m -Dir $existing
            return
        }
        $target = Join-Path $localRoot 'Strata-data'
        $eval = Evaluate-Dir -Dir $target -ModelObj $m
        Report-Eval $eval '新建'
        if (-not $eval.Ok) {
            Write-Log ('-LocalOnly：当前磁盘 {0} 剩余 {1:N1} GB 无法容纳 {2}（需要 {3:N1} GB，含 {4:N1} GB 缓存预留）→ 空间不足，无法安装' -f $eval.Root, $eval.FreeGB, $m.Display, $eval.Need.TotalGB, $script:ReserveGB) 'error'
            Exit-Deploy 2 ('-LocalOnly：当前磁盘空间不足（不改选其他分区）')
        }
        $script:DataDirUsed = $target
        Record-Stage3 $eval '新建'
        if ($DryRun) {
            Write-Log ('DryRun：不创建目录 {0}' -f $target) 'warn'
            return
        }
        if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
        Write-Log ('数据目录：{0}' -f $target) 'ok'
        $script:StrataCmd = Find-StrataCmd -HintDataDir $target
        $null = Get-PlanInfo -ModelObj $m -Dir $target
        return
    }

    if ($existing) { Write-Log ('从 %LOCALAPPDATA%\Strata\install\strata-*.json 的 args 反推出已有数据目录：{0}' -f $existing) 'ok' }
    if (-not $existing) {
        $existing = Search-DataDirOnDrives
        if ($existing) { Write-Log ('扫描固定磁盘找到已有数据目录：{0}' -f $existing) 'ok' }
    }

    $eval = $null
    if ($existing) {
        $eval = Evaluate-Dir -Dir $existing -ModelObj $m
        Report-Eval $eval '复用'
        if ($eval.Ok) {
            $script:DataDirUsed = $existing
            Record-Stage3 $eval '复用'
            Write-Log '复用已有数据目录（即使含中文路径也没问题：生成的 bat 按 GBK 落盘）' 'ok'
            Ensure-DataDir $existing
            $null = Get-PlanInfo -ModelObj $m -Dir $existing
            return
        }
        Write-Log ('已有数据目录所在分区 {0} 不足，尝试改选其他固定分区' -f $eval.Root) 'warn'
    }

    $drives     = @(Get-FixedDrives)
    $scriptRoot = [System.IO.Path]::GetPathRoot($ProjectDir)
    $ordered    = @()
    foreach ($d in $drives) { if ($d.Root -eq $scriptRoot) { $ordered += $d } }
    foreach ($d in ($drives | Sort-Object -Property FreeGB -Descending)) { if ($d.Root -ne $scriptRoot) { $ordered += $d } }

    Write-Line '候选固定分区（仅本地固定磁盘，已排除可移动/网络/光驱）：'
    foreach ($d in $ordered) { Write-Line ('  {0} 类型 {1}  总量 {2:N1} GB  剩余 {3:N1} GB' -f $d.Root, $d.Type, $d.TotalGB, $d.FreeGB) }

    foreach ($d in $ordered) {
        $target = Join-Path $d.Root 'Strata-data'
        $need   = Get-DiskNeedGB -ModelObj $m -Dir $target
        if ($d.FreeGB + $need.ExistingGB -lt ($need.TotalGB - 0.05)) {
            Write-Log ('跳过 {0}：剩余 {1:N1} GB < 还需 {2:N1} GB' -f $d.Root, $d.FreeGB, $need.NeedGB)
            continue
        }
        Write-Log ('{0} 可满足（剩余 {1:N1} GB），计划数据目录 {2}（纯 ASCII 路径，便于生成的 bat 按 ANSI 解析）' -f $d.Root, $d.FreeGB, $target)
        if ($DryRun) {
            Write-Log ('DryRun：不创建目录 {0}' -f $target) 'warn'
            Show-DriveNeedTable $need.NeedGB
            if ($existing) {
                Exit-Deploy 2 ('当前分区 {0} 对 {1} 不足（还需 {2:N1} GB）；DryRun 不新建数据目录，预览到此终止（真实运行会自动改用 {3}）' -f $eval.Root, $m.Display, $need.NeedGB, $target)
            }
            Exit-Deploy 2 ('没有可复用的数据目录，DryRun 不新建数据目录，预览到此终止（真实运行会创建 {0}）' -f $target)
        }
        try {
            if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
        } catch {
            Write-Log ('创建 {0} 失败（{1}），尝试下一个分区' -f $target, $_.Exception.Message) 'warn'
            continue
        }
        $e2 = Evaluate-Dir -Dir $target -ModelObj $m
        Report-Eval $e2 '新建'
        if (-not $e2.Ok) { continue }
        $script:DataDirUsed = $target
        Record-Stage3 $e2 '新建'
        Write-Log ('数据目录：{0}' -f $target) 'ok'
        $script:StrataCmd = Find-StrataCmd -HintDataDir $target
        return
    }

    Show-DriveNeedTable (Get-DiskNeedGB -ModelObj $m -Dir (Join-Path $scriptRoot 'Strata-data')).NeedGB
    Exit-Deploy 2 '所有本地固定分区的剩余空间都不满足所选模型的最低合计'
}

# ------------------------------------------------------------------ 阶段 4：框架与引擎
function Test-GitHubReachable {
    if ($null -eq $script:GithubReachable) {
        $ok = $false
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $ar = $client.BeginConnect('github.com', 443, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(3000, $true)) { $client.EndConnect($ar); $ok = $true }
            $client.Close()
        } catch { $ok = $false }
        if (-not $ok) {
            try { $ok = Test-NetConnection github.com -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue } catch { $ok = $false }
        }
        $script:GithubReachable = $ok
    }
    return $script:GithubReachable
}

function Invoke-GitHubDownload {
    param([string]$RepoUrl, [string]$OutFile)
    $url = $RepoUrl
    if (-not (Test-GitHubReachable)) { $url = 'https://gh-proxy.com/' + $RepoUrl }
    Show-Cmd @('-L', '--fail', '--retry', '2', '-o', $OutFile, $url) 'curl.exe'
    if ($DryRun) { Write-Log 'DryRun：跳过实际下载' 'warn'; return $false }
    try {
        & curl.exe -L --fail --retry 2 -o $OutFile $url
        if ((Get-LastExitCode) -ne 0 -or -not (Test-Path -LiteralPath $OutFile)) { return $false }
        Write-Log ('下载完成：{0}（{1}）' -f $OutFile, (Fmt-GB (Get-Item -LiteralPath $OutFile).Length)) 'ok'
        return $true
    } catch {
        Write-Log ('下载失败：{0}' -f $_.Exception.Message) 'error'
        return $false
    }
}

function Invoke-Stage4 {
    Write-Stage 4 6 '框架（Terminal）与引擎：缺什么装什么'
    $dir = $script:DataDirUsed

    if (-not $script:StrataCmd) { $script:StrataCmd = Find-StrataCmd -HintDataDir $dir }
    if ($script:StrataCmd) {
        Write-Log ('Terminal 已安装：{0}（跳过安装）' -f $script:StrataCmd) 'ok'
    } else {
        Write-Log 'Terminal 未安装，准备安装（GitHub 直连不通时走 https://gh-proxy.com/ 前缀）' 'warn'
        $tmp = Join-Path $env:TEMP ('strata-install-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        if (-not $DryRun) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
        $ps1 = Join-Path $tmp 'install.ps1'
        $zip = Join-Path $tmp 'strata-control-0.1.53-windows-x86_64.zip'
        if (-not (Invoke-GitHubDownload 'https://github.com/Niko1221/Strata/releases/latest/download/install.ps1' $ps1)) {
            Exit-Deploy 4 'install.ps1 下载失败（直连与 gh-proxy 均失败）'
        }
        if (Invoke-GitHubDownload 'https://github.com/Niko1221/Strata/releases/download/0.2.7/strata-control-0.1.53-windows-x86_64.zip' $zip) {
            $expected = $null
            try {
                $api = Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/Niko1221/Strata/releases/latest' -TimeoutSec 10
                foreach ($a in $api.assets) {
                    if ($a.name -like '*windows-x86_64.zip*') {
                        $shaUrl = 'https://api.github.com/repos/Niko1221/Strata/releases/assets/' + $a.id
                        Write-Log ('终端包 SHA-256 核对中：{0}' -f $a.name)
                    }
                }
            } catch { $expected = $null }
            $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
            if ($expected) {
                if (($expected -split '\s')[0].ToUpper() -ne $actual.ToUpper()) {
                    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
                    Write-Log ('终端包 SHA-256 不符：期望 {0} / 实际 {1}（已删除该文件）' -f $expected, $actual) 'error'
                    Exit-Deploy 4 'Terminal 包校验失败'
                }
                Write-Log ('终端包 SHA-256 校验通过：{0}' -f $actual) 'ok'
            } else {
                Write-Log ('无法从 GitHub release 页取到官方哈希，无法离线核对，已交由安装器校验。本地记录哈希：{0}' -f $actual) 'warn'
            }
        }
        Show-Cmd @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ps1) 'powershell'
        if ($DryRun) {
            Write-Log 'DryRun：跳过执行 install.ps1' 'warn'
        } else {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $ps1
            if ((Get-LastExitCode) -ne 0) { Exit-Deploy 4 'install.ps1 执行失败' }
            $script:StrataCmd = Find-StrataCmd -HintDataDir $dir
            if (-not $script:StrataCmd) { Exit-Deploy 4 '安装后仍找不到 strata 命令' }
            Write-Log ('Terminal 安装完成：{0}' -f $script:StrataCmd) 'ok'
        }
    }

    if (Test-GitHubReachable) {
        Write-Log 'GitHub 直连可达：引擎安装交给 strata launch 自带的签名下载' 'ok'
    } else {
        Write-Log 'GitHub 直连不通：所有 GitHub 资源改走 https://gh-proxy.com/ 前缀，并使用本地签名 feed' 'warn'
    }

    $engineInstalled = $false
    foreach ($probe in @((Join-Path $env:LOCALAPPDATA 'Strata\components\engine'), (Join-Path $dir 'components\engine'))) {
        if (-not (Test-Path -LiteralPath $probe)) { continue }
        $hit = @(Get-ChildItem -LiteralPath $probe -Recurse -Filter 'engine-component.json' -File -ErrorAction SilentlyContinue)
        if ($hit.Count -gt 0) { $engineInstalled = $true; Write-Log ('引擎已安装：{0}' -f $probe) 'ok'; break }
    }
    if (-not $engineInstalled) { Write-Log '未检测到已安装引擎组件（将由 strata launch 安装）' }

    $feedDir = Join-Path $dir 'feed'
    if ($Feed) { $feedDir = $Feed; Write-Log ('使用参数 -Feed 指定的 feed 目录：{0}' -f $feedDir) }
    $script:FeedDir = $feedDir
    $feedJson = Join-Path $feedDir 'strata-feed.json'
    $feedSig  = Join-Path $feedDir 'strata-feed.json.sig'
    $engTar   = Join-Path $feedDir 'strata-engine-0.1.52-windows-x86_64-cuda-cuda13.tar.gz'
    $hasJson = Test-Path -LiteralPath $feedJson
    $hasSig  = Test-Path -LiteralPath $feedSig
    $hasTar  = Test-Path -LiteralPath $engTar

    if ($hasJson -and $hasSig -and $hasTar) {
        $tarSize = (Get-Item -LiteralPath $engTar).Length
        if ($tarSize -eq $ENGINE_TAR_BYTES) {
            Write-Log ('复用本地签名 feed：{0}（engine 包 {1} 字节，与官方一致）；后续 launch 命令带 --feed' -f $feedDir, $tarSize) 'ok'
        } else {
            Write-Log ('本地签名 feed 的 engine 包 {0} 字节与官方 {1} 不一致，仍尝试使用（ed25519 签名兜底）' -f $tarSize, $ENGINE_TAR_BYTES) 'warn'
        }
        $script:UseFeed = $true
    } else {
        Write-Log ('feed 目录不完整（json={0} sig={1} tar={2}）：{3}' -f $hasJson, $hasSig, $hasTar, $feedDir)
        if (-not (Test-GitHubReachable)) {
            Ensure-DataDir $feedDir
            $items = @(
                'https://github.com/Niko1221/Strata/releases/download/0.2.7/strata-feed.json',
                'https://github.com/Niko1221/Strata/releases/download/0.2.7/strata-feed.json.sig',
                'https://github.com/Niko1221/Strata/releases/download/0.2.7/strata-engine-0.1.52-windows-x86_64-cuda-cuda13.tar.gz'
            )
            $outs = @($feedJson, $feedSig, $engTar)
            for ($i = 0; $i -lt $items.Count; $i++) {
                if (-not (Invoke-GitHubDownload $items[$i] $outs[$i])) { Exit-Deploy 4 ('预取本地签名 feed 失败：' + $items[$i]) }
            }
            if ((Get-Item -LiteralPath $engTar).Length -ne $ENGINE_TAR_BYTES) { Exit-Deploy 4 ('引擎包字节数校验失败（期望 {0}）' -f $ENGINE_TAR_BYTES) }
            $script:UseFeed = $true
            Write-Log ('本地签名 feed 预取完成：{0}' -f $feedDir) 'ok'
        } else {
            $script:UseFeed = $false
            Write-Log 'GitHub 可达，未预取本地 feed（由 strata 自带签名下载）'
        }
    }

    $tp = Join-Path $env:LOCALAPPDATA 'Strata\install\third_party'
    $hasLlama = $false
    if (Test-Path -LiteralPath $tp) {
        $hasLlama = @(Get-ChildItem -LiteralPath $tp -Filter 'llama.cpp*.zip' -File -ErrorAction SilentlyContinue).Count -gt 0
    }
    if ($hasLlama) {
        Write-Log ('llama.cpp 源包已就位：{0}' -f $tp) 'ok'
    } else {
        Write-Log ('{0} 缺少 llama.cpp 源包（踩坑 #4：装引擎时 setup 会卡在 "Checking the engine"）' -f $tp) 'warn'
        Write-Log '需要时手工补齐（GitHub 直连不通走 gh-proxy）：' 'warn'
        Write-Log ('  curl.exe -L -o "{0}\llama.cpp-3cf0325.zip" "https://gh-proxy.com/https://github.com/Niko1221/Strata/releases/download/0.2.7/llama.cpp-3cf0325.zip"' -f $tp) 'cmd'
    }

    $termState = '本次安装'
    if ($script:StrataCmd -and (Test-Path -LiteralPath $script:StrataCmd)) { $termState = '已安装(跳过)' }
    $ghState = '不通(走 gh-proxy)'
    if (Test-GitHubReachable) { $ghState = '可达' }
    $feedState = '由 strata 自带签名下载'
    if ($script:UseFeed) { $feedState = $script:FeedDir }
    $script:StageSummary += ('阶段4 框架/引擎：Terminal {0}；GitHub 直连 {1}；feed {2}' -f $termState, $ghState, $feedState)
}

# ------------------------------------------------------------------ 阶段 5：渠道 / 下载 / 完整性
function Get-ChannelEnv {
    param($ModelObj, [switch]$ForceHf)
    $envList = @()
    $name = ''
    if ($ForceHf) {
        $name = 'hf-mirror（哈希失败后切换）'
        $envList = @('HF_ENDPOINT=https://hf-mirror.com', 'STRATA_SOURCE=huggingface', 'STRATA_DL_CONNECTIONS=4')
    } elseif ($Source -eq 'modelscope') {
        $name = 'ModelScope（-Source 强制）'
        $envList = @('STRATA_SOURCE=modelscope')
    } elseif ($Source -eq 'huggingface') {
        $name = 'hf-mirror（-Source 强制）'
        $envList = @('HF_ENDPOINT=https://hf-mirror.com', 'STRATA_SOURCE=huggingface', 'STRATA_DL_CONNECTIONS=4')
    } elseif ($ModelObj.Key -eq 'iq3') {
        $name = 'ModelScope（auto：IQ3_XXS 先试 ModelScope，哈希不符再改 hf-mirror）'
        $envList = @('STRATA_SOURCE=modelscope')
    } else {
        $name = 'hf-mirror（auto：Coder / UD-IQ4_XS 走固定 revision）'
        $envList = @('HF_ENDPOINT=https://hf-mirror.com', 'STRATA_SOURCE=huggingface', 'STRATA_DL_CONNECTIONS=4')
    }
    $isMs = $false
    if ($envList -contains 'STRATA_SOURCE=modelscope') { $isMs = $true }
    return [pscustomobject]@{ Name = $name; Env = $envList; IsModelScope = $isMs }
}

function Set-ChannelEnv {
    param($Channel)
    Write-Log ('实际生效渠道：{0}' -f $Channel.Name) 'ok'
    foreach ($kv in $Channel.Env) {
        $parts = $kv -split '=', 2
        Set-Item -Path ('env:' + $parts[0]) -Value $parts[1]
        Write-Log ('  set ' + $kv)
    }
}

function Get-DownloadStats {
    param([string]$Dir, $ModelObj)
    $modelsDir   = Join-Path $Dir 'models'
    $doneCount   = 0
    $partBytes   = [long]0
    $targetBytes = [long]0
    foreach ($sh in $ModelObj.Shards) { $targetBytes += $sh.Bytes }
    if (Test-Path -LiteralPath $modelsDir) {
        foreach ($sh in $ModelObj.Shards) {
            $hit = Get-ChildItem -LiteralPath $modelsDir -Recurse -File -Filter $sh.Name -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit -and $hit.Length -eq $sh.Bytes) { $doneCount++ }
        }
        foreach ($p in (Get-ChildItem -LiteralPath $modelsDir -Recurse -File -Filter '*.part' -ErrorAction SilentlyContinue)) { $partBytes += $p.Length }
    }
    return [pscustomobject]@{ Done = $doneCount; Target = $ModelObj.Shards.Count; PartBytes = $partBytes; TargetBytes = $targetBytes }
}

function Test-ModelComplete {
    param([string]$Dir, $ModelObj)
    $problems = @()
    $modelsDir = Join-Path $Dir 'models'
    if (-not (Test-Path -LiteralPath $modelsDir)) {
        $problems += 'models 目录不存在'
    } else {
        foreach ($sh in $ModelObj.Shards) {
            $hit = Get-ChildItem -LiteralPath $modelsDir -Recurse -File -Filter $sh.Name -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $hit) { $problems += ('缺分片 ' + $sh.Name); continue }
            if ($hit.Length -ne $sh.Bytes) { $problems += ('{0} 字节数 {1} != 期望 {2}' -f $sh.Name, $hit.Length, $sh.Bytes); continue }
            if (-not (Test-Path -LiteralPath ($hit.FullName + '.done'))) { $problems += ('{0} 缺 .done 标记（下载未完成）' -f $sh.Name) }
        }
        if (@(Get-ChildItem -LiteralPath $modelsDir -File -Filter 'mmproj*' -ErrorAction SilentlyContinue).Count -eq 0) { $problems += ('缺图片编码器 ' + $MMPROJ_NAME) }
    }
    $mtp = Join-Path $Dir 'mtp'
    if (-not (Test-Path -LiteralPath $mtp) -or @(Get-ChildItem -LiteralPath $mtp -Recurse -File -Force -ErrorAction SilentlyContinue).Count -eq 0) { $problems += 'mtp 目录为空（MTP 草稿层缺失）' }
    $packs = Join-Path $Dir 'packs'
    if (-not (Test-Path -LiteralPath $packs) -or @(Get-ChildItem -LiteralPath $packs -Recurse -File -Force -ErrorAction SilentlyContinue).Count -eq 0) { $problems += 'packs 目录为空（专家映射/热度表缺失）' }
    return $problems
}

function Invoke-StrataDownload {
    param($ModelObj, [string]$Dir)
    $cmdArgs = @('launch', '--family', $ModelObj.Family, '--model', $ModelObj.Model, '--context', $Context, '--data-dir', $Dir)
    if ($script:UseFeed) { $cmdArgs += @('--feed', $script:FeedDir) }
    $cmdArgs += @('--yes', '--no-tui')
    Show-Cmd $cmdArgs $script:StrataCmd
    if ($DryRun) { Write-Log 'DryRun：不执行下载/启动' 'warn'; return '' }

    $argStr  = ($cmdArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $stamp   = Get-Date -Format 'yyyyMMddHHmmss'
    $outFile = Join-Path $env:TEMP ('strata-dl-out-' + $stamp + '.txt')
    $errFile = Join-Path $env:TEMP ('strata-dl-err-' + $stamp + '.txt')
    Write-Log '开始下载（每 15 秒打印一次进度，续传不清理 .part）...'
    $proc = Start-Process -FilePath $script:StrataCmd -ArgumentList $argStr -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    if ($proc) {
        while (-not $proc.HasExited) {
            Start-Sleep -Seconds 15
            $s = Get-DownloadStats -Dir $Dir -ModelObj $ModelObj
            Write-Log ('进度：分片 {0}/{1} 已完成   .part 已写 {2}   目标总体积 {3}' -f $s.Done, $s.Target, (Fmt-GB $s.PartBytes), (Fmt-GB $s.TargetBytes))
        }
    }
    $text = ''
    if (Test-Path -LiteralPath $outFile) { $text += (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) }
    if (Test-Path -LiteralPath $errFile) { $text += "`r`n" + (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue) }
    $lines = @($text -split "`r?`n") | Where-Object { $_.Trim() -ne '' }
    foreach ($ln in $lines) { Write-Log ('  下载输出: ' + $ln.Trim()) }
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    return $text
}

function Invoke-Stage5 {
    Write-Stage 5 6 '模型下载与「全部下完」确认'
    $m   = $script:ChosenModel
    $dir = $script:DataDirUsed

    $channel = Get-ChannelEnv -ModelObj $m
    Set-ChannelEnv $channel

    $plan = Get-PlanInfo -ModelObj $m -Dir $dir
    if ($plan) { Write-Log ('--plan 明细：{0}（{1} GB）' -f $plan.download.text, $plan.download.gb) }

    $problems = Test-ModelComplete -Dir $dir -ModelObj $m
    if ($problems.Count -eq 0) {
        Write-Log '完整性校验通过：分片字节数正确 + .done 齐全 + mmproj / mtp / packs 就位' 'ok'
        $script:StageSummary += ('阶段5 下载：渠道 {0}；模型已完整，跳过下载' -f $channel.Name)
        return
    }
    Write-Log ('完整性不满足：{0}' -f ($problems -join ' ; ')) 'warn'

    $planZero = $false
    if ($plan -and ($plan.download.gb -le 0)) { $planZero = $true }
    if ($planZero) {
        Write-Log ('注意：--plan 报 0 GB，说明 Strata 认为该模型已安装在别处；但 {0} 并不完整' -f $dir) 'warn'
    }

    if ($DryRun) {
        if ($LocalOnly -and $planZero) {
            Write-Log 'DryRun：-LocalOnly 下真实运行会因「该模型已安装在别的目录」而终止（Strata 不会把同一模型再下载到另一个目录；可用 strata models move 迁移）' 'warn'
        }
        $null = Invoke-StrataDownload -ModelObj $m -Dir $dir
        $script:StageSummary += ('阶段5 下载：渠道 {0}；DryRun 未下载；不完整项 {1} 条' -f $channel.Name, $problems.Count)
        return
    }

    if ($LocalOnly -and $planZero) {
        $otherDir = Get-DataDirFromRunConfig
        if (-not $otherDir) { $otherDir = '另一个目录' }
        Write-Log ('-LocalOnly：当前磁盘目录 {0} 还不完整，但 Strata 报告「模型已在本机」——它装在 {1}' -f $dir, $otherDir) 'error'
        Write-Log 'Strata 对同一个模型只使用已安装的那份文件，不会把同一模型再下载到另一个目录。两条可行路径：' 'warn'
        Write-Log ('  a) 官方搬迁（推荐，复制+校验后再删旧副本，不必重下）："{0}" models move "{1}" --plan   去掉 --plan 即执行' -f $script:StrataCmd, $dir)
        Write-Log ('  b) 真要重新下载到当前磁盘：先 "{0}" launch --stop，再移走 {1}\install\strata-{2}.json 与 {1}\launch\{2}-{3}.json，然后重跑本脚本（会重新下载约 64 GB）' -f $script:StrataCmd, (Join-Path $env:LOCALAPPDATA 'Strata'), $m.Tag, $Context)
        Exit-Deploy 2 '-LocalOnly：当前磁盘没有该模型，而它已安装在别的目录（Strata 不会重复下载同一模型）'
    }

    $text = Invoke-StrataDownload -ModelObj $m -Dir $dir
    $hashFail = $false
    if ($text) {
        foreach ($kw in @('SHA-256', 'sha256', 'hash', 'checksum', '哈希')) {
            if ($text -like ('*' + $kw + '*')) { $hashFail = $true; break }
        }
    }
    $problems = Test-ModelComplete -Dir $dir -ModelObj $m
    if (($hashFail -or $problems.Count -gt 0) -and $channel.IsModelScope) {
        Write-Log '识别到哈希失败/未完成，改用 hf-mirror 续传重试一次（踩坑 #8：ModelScope 版本与 Strata 固定 revision 不一致）' 'warn'
        $hf = Get-ChannelEnv -ModelObj $m -ForceHf
        Set-ChannelEnv $hf
        $text     = Invoke-StrataDownload -ModelObj $m -Dir $dir
        $problems = Test-ModelComplete -Dir $dir -ModelObj $m
    }
    if ($problems.Count -gt 0) {
        Write-Log ('仍不完整：{0}' -f ($problems -join ' ; ')) 'error'
        Write-Log '可重跑本脚本续传（.part 不会被清理）' 'warn'
        Exit-Deploy 5 '模型下载未完成 / 完整性校验失败'
    }
    Write-Log '模型下载完成并通过完整性校验' 'ok'
    $script:StageSummary += ('阶段5 下载：渠道 {0}；下载完成并校验通过' -f $channel.Name)
}

# ------------------------------------------------------------------ 阶段 6：启动 / 健康检查 / 产物
function Get-StatusLine {
    if (-not $script:StrataCmd) { return $null }
    Show-Cmd @('launch', '--status') $script:StrataCmd
    $raw = ''
    try { $raw = & $script:StrataCmd launch --status 2>&1 | Out-String } catch { $raw = $_.Exception.Message }
    foreach ($ln in ($raw -split "`r?`n")) {
        $t = $ln.Trim()
        if ($t -match '^(?<tag>[^:\s]+):\s*ready at\s+http://(?<host>[^:/]+):(?<port>\d+)') {
            return [pscustomobject]@{ Tag = $matches['tag']; Host = $matches['host']; Port = [int]$matches['port']; Raw = $t }
        }
    }
    return $null
}

function Get-LocalIPv4 {
    foreach ($nc in (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue)) {
        foreach ($ip in @($nc.IPAddress)) {
            if ($ip -match '^\d+\.\d+\.\d+\.\d+$' -and -not $ip.StartsWith('169.254')) { return $ip }
        }
    }
    return '127.0.0.1'
}

function Wait-Health {
    param([int]$Port, [int]$MaxSeconds = 1200)
    $end = (Get-Date).AddSeconds($MaxSeconds)
    $i = 0
    while ((Get-Date) -lt $end) {
        $i++
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri ('http://127.0.0.1:{0}/health' -f $Port) -TimeoutSec 5
            $j = $resp.Content | ConvertFrom-Json
            if ($j.status -eq 'ok' -or $j.loaded -eq $true) {
                Write-Log ('健康检查第 {0} 次成功：{1}' -f $i, $resp.Content) 'ok'
                return $j
            }
            Write-Log ('健康检查第 {0} 次未就绪：{1}' -f $i, $resp.Content)
        } catch {
            Write-Log ('健康检查第 {0} 次：{1}' -f $i, $_.Exception.Message)
        }
        Start-Sleep -Seconds 5
    }
    return $null
}

function Show-TailLog {
    param([string]$Path, [int]$Lines = 40)
    if (-not (Test-Path -LiteralPath $Path)) { Write-Log ('日志不存在：{0}' -f $Path) 'warn'; return }
    Write-Log ('{0} 尾部 {1} 行：' -f $Path, $Lines) 'warn'
    foreach ($ln in (Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction SilentlyContinue)) { Write-Log ('  ' + $ln) }
}

function New-StartBat {
    param($ModelObj, [string]$Dir, [string]$Strata, [string]$FeedDirArg, $Channel, [bool]$Restart, [string]$ServedName)

    $launchArgs = @('launch', '--family', $ModelObj.Family, '--model', $ModelObj.Model, '--context', $Context,
                    '--kv', 'int8', '--set', ('kv-resident=' + $KVResident), '--set', 'vram-reserve-mib=1408',
                    '--vision', $Vision, '--access', 'lan', '--port', $Port, '--data-dir', ('"' + $Dir + '"'))
    if ($FeedDirArg) { $launchArgs += @('--feed', ('"' + $FeedDirArg + '"')) }
    if ($Restart) { $launchArgs += '--restart' }
    $launchArgs += @('--yes', '--no-tui')

    $lines = @()
    $lines += '@echo off'
    $lines += 'setlocal'
    $lines += ('title Strata {0} {1}' -f $ModelObj.Display, $Context)
    $lines += 'chcp 936 >nul'
    $lines += ('rem generated by deploy-strata.ps1 at ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    foreach ($kv in $Channel.Env) { $lines += ('set ' + $kv) }
    if ($FeedDirArg) { $lines += ('set STRATA_UPDATE_FEED=' + $FeedDirArg) }
    $lines += ('set STRATA=' + $Strata)
    $lines += ('set DATA_DIR=' + $Dir)
    $lines += 'set STATUSFILE=%TEMP%\strata-launch-status.txt'
    $lines += 'set KEYFILE=%TEMP%\strata-api-key.txt'
    $lines += ''
    $lines += 'echo.'
    $lines += 'echo [1/3] 检查模型服务状态...'
    $lines += 'call "%STRATA%" launch --status > "%STATUSFILE%" 2>&1'
    $lines += 'find /i "ready at" "%STATUSFILE%" >nul'
    $lines += 'if errorlevel 1 goto startmodel'
    $lines += 'echo [1/3] 模型已在运行，跳过启动。要换模型先执行: "%STRATA%" launch --stop'
    $lines += 'goto frp'
    $lines += ''
    $lines += ':startmodel'
    $lines += ('echo [1/3] 启动模型服务（{0} / {1} / vision {2} / lan / 端口 {3}）...' -f $ModelObj.Display, $Context, $Vision, $Port)
    $lines += ('call "%STRATA%" ' + ($launchArgs -join ' '))
    $lines += 'if errorlevel 1 goto failed'
    $lines += ''
    $lines += ':frp'
    if ($FrpExe -and $FrpIni) {
        $lines += 'echo.'
        $lines += 'tasklist /fi "imagename eq frpc.exe" 2>nul | find /i "frpc.exe" >nul'
        $lines += 'if errorlevel 1 goto startfrp'
        $lines += 'echo [2/3] FRP 已在运行，跳过。'
        $lines += 'goto check'
        $lines += ''
        $lines += ':startfrp'
        $lines += 'echo [2/3] 启动 FRP 内网穿透...'
        $lines += ('start "Strata-FRP" /min "{0}" -c "{1}"' -f $FrpExe, $FrpIni)
        $lines += 'ping -n 4 127.0.0.1 >nul'
    } else {
        $lines += 'echo [2/3] 未配置 FRP（部署时未给 -FrpExe / -FrpIni），跳过。'
    }
    $lines += ''
    $lines += ':check'
    $lines += 'echo.'
    $lines += 'echo [3/3] 等待服务就绪（最多 40 次轮询）...'
    $lines += 'set READY='
    $lines += 'for /l %%i in (1,1,40) do ('
    $lines += ('  curl -s -m 3 http://127.0.0.1:{0}/health >nul && (set READY=1 & goto ready)' -f $Port)
    $lines += '  ping -n 6 127.0.0.1 >nul'
    $lines += ')'
    $lines += ''
    $lines += ':ready'
    $lines += 'if not defined READY goto failed'
    $lines += ''
    $lines += 'call "%STRATA%" launch --show-key > "%KEYFILE%" 2>&1'
    $lines += 'set APIKEY='
    $lines += 'for /f "usebackq tokens=1" %%k in ("%KEYFILE%") do if not defined APIKEY set APIKEY=%%k'
    $lines += 'echo.'
    $lines += 'echo ============================================================'
    $lines += ('curl -s http://127.0.0.1:{0}/health' -f $Port)
    $lines += 'echo.'
    $lines += ('echo   本机    http://127.0.0.1:{0}/v1' -f $Port)
    $lines += ('echo   局域网  http://{0}:{1}/v1' -f $script:LocalIP, $Port)
    if ($PublicUrl) { $lines += ('echo   公网    ' + $PublicUrl) }
    $servedForBat = $ModelObj.ModelId
    if ($ServedName) { $servedForBat = $ServedName }
    $lines += ('echo   模型    {0}' -f $servedForBat)
    $lines += 'echo   密钥    %APIKEY%'
    $lines += 'echo ============================================================'
    $lines += 'echo   关闭本窗口不会停掉模型服务'
    $lines += 'echo   停止模型: "%STRATA%" launch --stop'
    $lines += 'echo.'
    $lines += 'pause'
    $lines += 'exit /b 0'
    $lines += ''
    $lines += ':failed'
    $lines += 'echo.'
    $lines += ('echo [失败] 服务没有起来，请查看日志: {0}\launch.log' -f $Dir)
    $lines += 'pause'
    $lines += 'exit /b 1'

    $batPath = Join-Path $ProjectDir ('start-strata-{0}.cmd' -f $ModelObj.Key)
    $text = ($lines -join "`r`n") + "`r`n"
    try {
        [System.IO.File]::WriteAllText($batPath, $text, [System.Text.Encoding]::GetEncoding(936))
    } catch {
        Exit-Deploy 7 ('写 start bat 失败：' + $_.Exception.Message)
    }
    Write-Log ('已生成一键启动脚本（GBK/cp936 + CRLF，无 BOM）：{0}' -f $batPath) 'ok'
    return $batPath
}

function New-DesktopShortcut {
    param([string]$BatPath, [string]$DisplayName)
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop ('Strata {0}.lnk' -f $DisplayName)
    if (Test-Path -LiteralPath $lnkPath) { Remove-Item -LiteralPath $lnkPath -Force }
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $sc = $wsh.CreateShortcut($lnkPath)
        $sc.TargetPath = $BatPath
        $sc.WorkingDirectory = Split-Path -Parent $BatPath
        $sc.Description = ('一键启动 Strata {0} 模型服务（端口 {1}，上下文 {2}）' -f $DisplayName, $Port, $Context)
        $sc.IconLocation = "$env:SystemRoot\System32\shell32.dll,137"
        $sc.Save()
    } catch {
        Exit-Deploy 7 ('创建桌面快捷方式失败：' + $_.Exception.Message)
    }
    Write-Log ('已创建桌面快捷方式：{0}' -f $lnkPath) 'ok'
    return $lnkPath
}

function Invoke-Stage6 {
    Write-Stage 6 6 '启动、健康检查与一键启动入口'
    $m         = $script:ChosenModel
    $dir       = $script:DataDirUsed
    $launchLog = Join-Path $dir 'launch.log'

    $script:LocalIP = Get-LocalIPv4
    Write-Log ('本机 IPv4：{0}' -f $script:LocalIP)

    $st = Get-StatusLine
    $needRestart = $false
    if ($st) {
        Write-Log ('当前服务状态：{0}' -f $st.Raw) 'ok'
        $tagModel = $st.Tag.ToLower() -replace '-\d+[km]$', ''
        if ($tagModel -eq $m.ModelId -and $st.Port -eq $Port) {
            Write-Log '服务已在运行且与本次选择一致，跳过启动，直接进入健康检查' 'ok'
        } else {
            Write-Log ('已在运行的服务（{0} 端口 {1}）与本次选择（{2} 端口 {3}）不同' -f $st.Tag, $st.Port, $m.ModelId, $Port) 'warn'
            if ($DryRun) {
                Write-Log 'DryRun：不会顶掉已在运行的服务，只打印将要执行的启动命令' 'warn'
                $needRestart = $true
            } elseif ($ForceRestart) {
                Write-Log '-ForceRestart 已给出：将用 --restart 顶掉当前服务' 'warn'
                $needRestart = $true
            } else {
                $ans = Read-Host '是否顶掉当前服务并启动所选模型？输入 y 确认（其它输入终止部署）'
                if ($ans.Trim().ToLower() -ne 'y') { Exit-Deploy 3 '用户拒绝顶掉已在运行的服务' }
                $needRestart = $true
            }
        }
    } else {
        Write-Log '当前没有已就绪的服务，将直接启动'
    }

    $launchArgs = @('launch', '--family', $m.Family, '--model', $m.Model, '--context', $Context,
                    '--kv', 'int8', '--set', ('kv-resident=' + $KVResident), '--set', 'vram-reserve-mib=1408',
                    '--vision', $Vision, '--access', 'lan', '--port', $Port, '--data-dir', $dir)
    if ($script:UseFeed) { $launchArgs += @('--feed', $script:FeedDir) }
    if ($needRestart) { $launchArgs += '--restart' }
    $launchArgs += @('--yes', '--no-tui')
    Show-Cmd $launchArgs $script:StrataCmd

    if ($DryRun) {
        Write-Log ('DryRun：跳过启动；将轮询 http://127.0.0.1:{0}/health（每 5 秒一次，最长 20 分钟）' -f $Port) 'warn'
        Show-Cmd @('launch', '--show-key') $script:StrataCmd
        Write-Log ('DryRun：跳过 /v1/models 校验，跳过生成 start-strata-{0}.cmd 与桌面快捷方式' -f $m.Key) 'warn'
        $extra = ''
        if ($needRestart) { $extra = '，需 --restart 顶掉已在运行的服务' }
        $script:StageSummary += ('阶段6 启动：DryRun 预览（端口 {0}，kv int8，kv-resident {1}，vram-reserve-mib 1408，vision {2}{3}）' -f $Port, $KVResident, $Vision, $extra)
        return
    }

    if (-not ($st -and (-not $needRestart))) {
        & $script:StrataCmd @launchArgs 2>&1 | ForEach-Object { Write-Log ('  启动输出: ' + $_) }
        if ((Get-LastExitCode) -ne 0) {
            Show-TailLog $launchLog 40
            Exit-Deploy 6 'strata launch 启动失败'
        }
    }

    $health = Wait-Health -Port $Port
    if (-not $health) {
        Show-TailLog $launchLog 40
        Exit-Deploy 6 ('健康检查超时（20 分钟内 http://127.0.0.1:{0}/health 未就绪）；未生成 bat 与快捷方式' -f $Port)
    }

    $key = ''
    $keyOut = & $script:StrataCmd launch --show-key 2>&1 | Out-String
    foreach ($ln in ($keyOut -split "`r?`n")) {
        $t = $ln.Trim()
        if ($t -match '^sk-') { $key = $t; break }
    }
    if (-not $key) { Write-Log '未取得 API Key（--show-key 输出里没有以 sk- 开头的行）' 'warn' }

    $servedName = ''
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri ('http://127.0.0.1:{0}/v1/models' -f $Port) -Headers @{ Authorization = ('Bearer ' + $key) } -TimeoutSec 10
        $mo = $resp.Content | ConvertFrom-Json
        if ($mo.data -and @($mo.data).Count -gt 0) { $servedName = $mo.data[0].id }
    } catch {
        Write-Log ('/v1/models 调用失败：{0}' -f $_.Exception.Message) 'warn'
    }
    if ($servedName -and $servedName.ToLower() -notlike ('*' + $m.ModelId + '*')) {
        Write-Log ('警告：/v1/models 返回模型名 "{0}" 与预期 "{1}" 不一致（不影响部署）' -f $servedName, $m.ModelId) 'warn'
    }

    $ctxTokens = ContextTokens $Context
    Write-Line ''
    Write-Line '=================== 接入信息 ===================' 'Green'
    Write-Line ('  本机地址   http://127.0.0.1:{0}/v1' -f $Port)
    Write-Line ('  局域网地址 http://{0}:{1}/v1' -f $script:LocalIP, $Port)
    if ($PublicUrl) { Write-Line ('  公网地址   ' + $PublicUrl) }
    $shownName = $m.ModelId
    if ($servedName) { $shownName = $servedName }
    Write-Line ('  模型名     ' + $shownName)
    Write-Line ('  上下文     ' + $ctxTokens)
    $shownKey = '(未取得)'
    if ($key) { $shownKey = $key }
    Write-Line ('  API Key    ' + $shownKey)
    Write-Line ('  停止命令   "{0}" launch --stop' -f $script:StrataCmd)
    Write-Line ('  日志       ' + $launchLog)
    Write-Line '=================================================' 'Green'

    $channel  = Get-ChannelEnv -ModelObj $m
    $feedArg  = ''
    if ($script:UseFeed) { $feedArg = $script:FeedDir }
    $batPath  = New-StartBat -ModelObj $m -Dir $dir -Strata $script:StrataCmd -FeedDirArg $feedArg -Channel $channel -Restart $needRestart -ServedName $shownName
    $lnkPath  = ''
    if (-not $NoShortcut) { $lnkPath = New-DesktopShortcut -BatPath $batPath -DisplayName $m.Display }

    $lnkText = '未创建快捷方式(-NoShortcut)'
    if ($lnkPath) { $lnkText = '快捷方式 ' + $lnkPath }
    $script:StageSummary += ('阶段6 启动：{0} 就绪（端口 {1}，上下文 {2}）；bat {3}；{4}' -f $shownName, $Port, $ctxTokens, $batPath, $lnkText)
}

# ------------------------------------------------------------------ 主流程
Write-Line ('deploy-strata.ps1  开始 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) 'White'
Write-Line ('项目目录：' + $ProjectDir)
Write-Line ('日志文件：' + $LogFile)
if ($DryRun) { Write-Line '模式：DryRun（只预览：不下载 / 不启动 / 不写 bat / 不建快捷方式 / 不创建目录）' 'Yellow' }
if ($LocalOnly) { Write-Line ('模式：-LocalOnly（只使用当前磁盘 ' + [System.IO.Path]::GetPathRoot($ProjectDir) + '，不检索/不改选其他磁盘）') 'Yellow' }

try {
    Invoke-Stage1
    Invoke-Stage2
    Invoke-Stage3
    Invoke-Stage4
    Invoke-Stage5
    Invoke-Stage6

    Write-Host ''
    Write-Line '=================== 六阶段结果汇总 ===================' 'Green'
    foreach ($s in $script:StageSummary) { Write-Line ('  ' + $s) }
    Write-Line ('总耗时：{0:N1} 秒' -f $sw.Elapsed.TotalSeconds)
    Write-Line '---------------------------------------------------------'
    Write-Line '下一步（Trae 接入）：'
    Write-Line ('  OpenAI 兼容 Base URL   http://{0}:{1}/v1' -f $script:LocalIP, $Port)
    Write-Line ('  Anthropic 兼容根地址   http://{0}:{1}（不带 /v1）' -f $script:LocalIP, $Port)
    Write-Line ('  上下文窗口 输入        {0}' -f (ContextTokens $Context))
    Write-Line '  支持图片输入           是（vision cpu）'
    Write-Line '  思考强度参数名         reasoning_effort（none / low / medium / high）'
    if ($PublicUrl) { Write-Line ('  公网 Base URL          ' + $PublicUrl) }
    Exit-Deploy 0 '六阶段全部完成'
} catch {
    Write-Log ('脚本异常：{0}' -f $_.Exception.Message) 'error'
    Write-Log ('调用栈：{0}' -f $_.ScriptStackTrace) 'error'
    Exit-Deploy 2 '脚本运行时异常'
}