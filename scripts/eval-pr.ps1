<#
.SYNOPSIS
  VIctory-AMD Two-Phase PR Security Gate & Hardware Benchmark Evaluator.

.DESCRIPTION
  Phase 1 (ALWAYS runs first, NEVER compiles or executes PR code):
    - Fetches PR diff from CarlosB456/VIctory-AMD without checking out or building.
    - Enforces SECURITY-GATE.md blocklists on off-topic paths, high-risk files
      (build.rs, Cargo.toml, Cargo.lock, .github/, scripts/, binaries), and dangerous added patterns.
    - STOPS before compilation unless -SecurityApproved is explicitly passed.

  Phase 2 (ONLY runs when -SecurityApproved is passed after Antigravity/human audit):
    - Creates an isolated temporary git worktree.
    - Runs `cargo test --release --workspace` (comparing any failures against baseline `main` so only NEW regressions fail).
    - Builds `target\release\victory.exe` (`cargo build --release -p victory`).
    - If -GameDir is provided, runs a timed baseline vs PR benchmark of `victory.exe run --execute --console series-s`
      and compares crashes, device removals, avg/min FPS, frame ms, and copy ms.
#>
param(
    [int]$PrNumber = 0,
    [string]$Ref = '',
    [string]$BaseRef = 'victoryamd/main',
    [string]$Repo = 'CarlosB456/VIctory-AMD',
    [switch]$SecurityApproved,
    [string]$GameDir = '',
    [int]$Seconds = 90,
    [string]$TestFilter = '',
    [switch]$SkipBenchmark
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path $PSScriptRoot -Parent

function Get-TargetRemote {
    $remotes = @(git -C $RepoRoot remote -v)
    foreach ($line in $remotes) {
        if ($line -match '^(\S+)\s+.*CarlosB456/VIctory-AMD') {
            return $Matches[1]
        }
    }
    return 'origin'
}

function Invoke-GitQuiet {
    param([string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & git -C $RepoRoot @GitArgs 2>&1
    } finally {
        $ErrorActionPreference = $prev
    }
}

$TargetRemote = Get-TargetRemote

function Resolve-TargetCommit {
    if ($PrNumber -gt 0) {
        $null = Get-Command gh -ErrorAction Stop
        Write-Host "[Phase 1] Fetching PR #$PrNumber metadata & ref from $Repo (no checkout, no build)..."
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $prRaw = & gh pr view $PrNumber --repo $Repo --json number,title,author,headRefOid,baseRefName,state 2>$null
        $ErrorActionPreference = $prev
        $prJson = $prRaw | ConvertFrom-Json
        if (-not $prJson) { throw "Could not load PR #$PrNumber via gh" }
        Write-Host "  PR #$($prJson.number): $($prJson.title) by @$($prJson.author.login) (state: $($prJson.state), head: $($prJson.headRefOid))"
        Invoke-GitQuiet @('fetch', $TargetRemote, "pull/$PrNumber/head:refs/remotes/$TargetRemote/pr-$PrNumber")
        return [pscustomobject]@{
            Commit = (git -C $RepoRoot rev-parse "refs/remotes/$TargetRemote/pr-$PrNumber").Trim()
            Label  = "PR #$PrNumber (@$($prJson.author.login))"
        }
    }
    if (-not $Ref) {
        throw "Provide either -PrNumber <N> or -Ref <branch-or-sha>."
    }
    return [pscustomobject]@{
        Commit = (git -C $RepoRoot rev-parse $Ref).Trim()
        Label  = $Ref
    }
}

$target = Resolve-TargetCommit
Invoke-GitQuiet @('fetch', $TargetRemote, 'main')
$baseCommit = (git -C $RepoRoot rev-parse $BaseRef).Trim()
$diffRange = "$baseCommit...$($target.Commit)"

Write-Host ""
Write-Host "=== PHASE 1: STATIC SECURITY & ANTI-SLOP AUDIT ($($target.Label)) ==="
$changedFiles = @(git -C $RepoRoot diff --name-only $diffRange)
if ($changedFiles.Count -eq 0) {
    Write-Host "No changes between $BaseRef and $($target.Label)."
    exit 0
}

Write-Host "Changed files ($($changedFiles.Count)):"
git -C $RepoRoot diff --stat $diffRange | Write-Host

$highRiskPaths = @(
    '(^|/)build\.rs$',
    '(^|/)Cargo\.(toml|lock)$',
    '^\.github/',
    '^scripts/',
    '\.(ps1|bat|cmd|py|sh|vbs|js|exe|dll|pdb|bin|rpf)$'
)

$allowedScopeRoots = '^(crates/|apps/|tests/|docs/|README\.md$|TASKS\.(md|json)$|LEADERBOARD\.md$)'

$flaggedPaths = @()
$offTopicPaths = @()
foreach ($f in $changedFiles) {
    if ($f -notmatch $allowedScopeRoots) {
        $offTopicPaths += $f
    }
    foreach ($pat in $highRiskPaths) {
        if ($f -match $pat) {
            $flaggedPaths += $f
            break
        }
    }
}

$dangerPatterns = @(
    @{ Name = 'Process/Shell Spawn';   Regex = 'std::process::Command|Command::new|ShellExecute|CreateProcess|WinExec|powershell|cmd\.exe|wscript|mshta|rundll32|iex\s|EncodedCommand' },
    @{ Name = 'Network/Download';      Regex = 'std::net::|TcpStream|UdpSocket|TcpListener|reqwest|ureq|hyper|WinHttp|wininet|WSAStartup|Invoke-WebRequest|Invoke-RestMethod|curl\.exe|wget\s' },
    @{ Name = 'Memory/Hook Injection'; Regex = 'CreateRemoteThread|WriteProcessMemory|VirtualAllocEx|SetWindowsHookEx|NtUnmapViewOfSection' },
    @{ Name = 'Persistence/Registry';  Regex = 'RegSetValue|RegCreateKey|CurrentVersion\\Run|schtasks' },
    @{ Name = 'Obfuscation/Blob';      Regex = 'include_bytes!\(|from_base64|base64::decode|FromBase64String' },
    @{ Name = 'Prompt Injection';      Regex = 'ignore (all )?previous instructions|disregard (all )?(above|prior)|system prompt|developer mode|jailbreak|auto[- ]?approve|skip security' },
    @{ Name = 'Slop/Test Bypass';      Regex = '#\[ignore\]' }
)

$diffLines = @(git -C $RepoRoot diff --unified=0 $diffRange)
$currentFile = ''
$flaggedCode = @()

foreach ($line in $diffLines) {
    if ($line -match '^\+\+\+ b/(.+)$') {
        $currentFile = $Matches[1]
        continue
    }
    if ($line -match '^\+[^\+]') {
        $codeLine = $line.Substring(1)
        foreach ($rule in $dangerPatterns) {
            if ($codeLine -match $rule.Regex) {
                $flaggedCode += [pscustomobject]@{
                    Rule = $rule.Name
                    File = $currentFile
                    Line = $codeLine.Trim()
                }
            }
        }
    }
}

Write-Host ""
if ($offTopicPaths.Count -gt 0) {
    Write-Host "[SCOPE WARNING] Files outside VIctory-AMD core scope (crates/, apps/, tests/, docs/, README/TASKS/LEADERBOARD):" -ForegroundColor Yellow
    $offTopicPaths | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
if ($flaggedPaths.Count -gt 0) {
    Write-Host "[SECURITY WARNING] High-risk paths modified:" -ForegroundColor Yellow
    $flaggedPaths | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
if ($flaggedCode.Count -gt 0) {
    Write-Host "[SECURITY WARNING] Suspicious added patterns detected:" -ForegroundColor Red
    $flaggedCode | ForEach-Object { Write-Host "  [$($_.Rule)] $($_.File): $($_.Line)" -ForegroundColor Red }
}
if ($offTopicPaths.Count -eq 0 -and $flaggedPaths.Count -eq 0 -and $flaggedCode.Count -eq 0) {
    Write-Host "[Phase 1] Automated scan found 0 off-topic paths, 0 blocklisted paths, and 0 dangerous added patterns." -ForegroundColor Green
}

if (-not $SecurityApproved) {
    Write-Host ""
    Write-Host "STOPPED BEFORE COMPILATION (Fail-Closed Security Gate)." -ForegroundColor Cyan
    Write-Host "Next steps:"
    Write-Host "  1. Review the full diff with Antigravity / git diff $diffRange against SECURITY-GATE.md"
    Write-Host "  2. If completely safe, re-run with -SecurityApproved to execute Phase 2 (tests + benchmark)."
    exit 2
}

Write-Host ""
Write-Host "=== PHASE 2: ISOLATED WORKTREE BUILD, TEST & BENCHMARK ==="

function Invoke-VictoryBenchmark {
    param(
        [string]$ExePath,
        [string]$Label,
        [string]$OutSubDir
    )
    if (-not (Test-Path $OutSubDir)) { $null = New-Item -ItemType Directory -Path $OutSubDir -Force }
    $gameExe = Join-Path $GameDir 'game_scarlett_master.exe'
    if (-not (Test-Path $gameExe)) { throw "Game executable not found at $gameExe" }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.Arguments = "run --execute --console series-s `"$gameExe`""
    $psi.WorkingDirectory = $GameDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables['VICTORY_GAME_DIR'] = $GameDir

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $null = $p.Start()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()

    $exitedEarly = $p.WaitForExit($Seconds * 1000)
    if (-not $exitedEarly -and -not $p.HasExited) {
        $p.Kill()
        $p.WaitForExit(5000) | Out-Null
    }
    $combined = ($outTask.Result + "`n" + $errTask.Result)
    $combined | Set-Content (Join-Path $OutSubDir 'victory.log') -Encoding utf8

    $fpsSamples = @([regex]::Matches($combined, '([0-9]+(?:\.[0-9]+)?) fps,\s*([0-9]+(?:\.[0-9]+)?) ms/frame') | ForEach-Object { [double]$_.Groups[1].Value })
    $msSamples = @([regex]::Matches($combined, '([0-9]+(?:\.[0-9]+)?) fps,\s*([0-9]+(?:\.[0-9]+)?) ms/frame') | ForEach-Object { [double]$_.Groups[2].Value })
    $copySamples = @([regex]::Matches($combined, 'copies\s+([0-9]+(?:\.[0-9]+)?) ms') | ForEach-Object { [double]$_.Groups[1].Value })

    $avgFps = if ($fpsSamples.Count -gt 0) { [math]::Round(($fpsSamples | Measure-Object -Average).Average, 2) } else { 0.0 }
    $minFps = if ($fpsSamples.Count -gt 0) { [math]::Round(($fpsSamples | Measure-Object -Minimum).Minimum, 2) } else { 0.0 }
    $avgMs = if ($msSamples.Count -gt 0) { [math]::Round(($msSamples | Measure-Object -Average).Average, 1) } else { 0.0 }
    $avgCopyMs = if ($copySamples.Count -gt 0) { [math]::Round(($copySamples | Measure-Object -Average).Average, 1) } else { 0.0 }

    $crashes = ([regex]::Matches($combined, 'STATUS_ACCESS_VIOLATION|0xc0000005|panicked at|unhandled exception')).Count
    if ($exitedEarly -and $p.ExitCode -ne 0) { $crashes += 1 }
    $removals = ([regex]::Matches($combined, 'device removed|DXGI_ERROR_DEVICE_REMOVED|DXGI_ERROR_DEVICE_HUNG')).Count

    return [pscustomobject]@{
        Label      = $Label
        Crashes    = $crashes
        Removals   = $removals
        Samples    = $fpsSamples.Count
        AvgFps     = $avgFps
        MinFps     = $minFps
        AvgFrameMs = $avgMs
        AvgCopyMs  = $avgCopyMs
    }
}

$wtDir = Join-Path $env:TEMP ("victoryamd-eval-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$benchDir = Join-Path $env:TEMP ("victoryamd-bench-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

try {
    Write-Host "Creating isolated worktree at $wtDir ($($target.Commit))..."
    Invoke-GitQuiet @('worktree', 'add', '--detach', $wtDir, $target.Commit)
    if ($LASTEXITCODE -ne 0) { throw "Failed to create git worktree" }

    Write-Host "Running unit tests in isolated worktree..."
    $savedErr = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $testArgs = @('test', '--release', '--manifest-path', (Join-Path $wtDir 'Cargo.toml'), '--workspace', '--lib')
        if ($TestFilter) { $testArgs += @('--', $TestFilter, '--test-threads=1') } else { $testArgs += @('--', '--test-threads=1') }
        $prTestOut = & cargo @testArgs 2>&1 | Tee-Object -Variable prTestLines
        $prTestExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErr
    }
    if ($prTestExit -ne 0) {
        $prFailed = @($prTestLines | Where-Object { $_ -match '^test (\S+) \.\.\. FAILED$' } | ForEach-Object { $Matches[1] })
        Write-Host "PR had $($prFailed.Count) failing test(s); checking against baseline ($baseCommit) for regressions..." -ForegroundColor Yellow
        $baseWt = Join-Path $env:TEMP ("victoryamd-base-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            Invoke-GitQuiet @('worktree', 'add', '--detach', $baseWt, $baseCommit)
            $ErrorActionPreference = 'Continue'
            $baseArgs = @('test', '--release', '--manifest-path', (Join-Path $baseWt 'Cargo.toml'), '--workspace', '--lib')
            if ($TestFilter) { $baseArgs += @('--', $TestFilter, '--test-threads=1') } else { $baseArgs += @('--', '--test-threads=1') }
            $baseTestLines = @(& cargo @baseArgs 2>&1)
            $baseFailed = @($baseTestLines | Where-Object { $_ -match '^test (\S+) \.\.\. FAILED$' } | ForEach-Object { $Matches[1] })
        } finally {
            $ErrorActionPreference = $savedErr
            if (Test-Path $baseWt) { Invoke-GitQuiet @('worktree', 'remove', '--force', $baseWt) }
        }
        $newFailures = @($prFailed | Where-Object { $_ -notin $baseFailed })
        if ($newFailures.Count -gt 0) {
            Write-Host "[VERDICT] REJECT: $($newFailures.Count) NEW failing test(s) introduced by PR:" -ForegroundColor Red
            $newFailures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
            exit 1
        }
        Write-Host "0 new test regressions." -ForegroundColor Green
    }

    Write-Host "Building release victory.exe in isolated worktree..."
    $savedErr2 = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & cargo build --release --manifest-path (Join-Path $wtDir 'Cargo.toml') -p victory 2>&1 | Out-Host
    $buildExit = $LASTEXITCODE
    $ErrorActionPreference = $savedErr2
    if ($buildExit -ne 0) {
        Write-Host "[VERDICT] REJECT: Release build failed." -ForegroundColor Red
        exit 1
    }

    if ($SkipBenchmark -or -not $GameDir) {
        Write-Host "[VERDICT] TESTS & BUILD PASSED (live benchmark skipped: pass -GameDir to benchmark against baseline)." -ForegroundColor Green
        exit 0
    }

    $baseExe = Join-Path $RepoRoot 'target\release\victory.exe'
    $prExe = Join-Path $wtDir 'target\release\victory.exe'
    if (-not (Test-Path $baseExe)) { throw "Baseline executable not found at $baseExe; build main first." }

    Write-Host "Running baseline benchmark ($Seconds s)..."
    $baseStats = Invoke-VictoryBenchmark -ExePath $baseExe -Label 'baseline' -OutSubDir (Join-Path $benchDir 'baseline')
    Write-Host "Running PR benchmark ($Seconds s)..."
    $prStats = Invoke-VictoryBenchmark -ExePath $prExe -Label 'pr' -OutSubDir (Join-Path $benchDir 'pr')

    Write-Host ""
    Write-Host "=== BENCHMARK COMPARISON ==="
    @($baseStats, $prStats) | Format-Table -AutoSize | Out-Host

    if ($prStats.Crashes -gt 0 -or $prStats.Removals -gt 0) {
        Write-Host "[VERDICT] REJECT: PR had $($prStats.Crashes) crash(es) and $($prStats.Removals) device removal(s)." -ForegroundColor Red
        exit 1
    }
    if ($baseStats.AvgFps -gt 0 -and $prStats.AvgFps -lt ($baseStats.AvgFps * 0.95)) {
        Write-Host "[VERDICT] REJECT: FPS regressed (>5% below baseline: $($prStats.AvgFps) vs $($baseStats.AvgFps))." -ForegroundColor Red
        exit 1
    }
    if ($prStats.AvgFps -ge $baseStats.AvgFps -or ($prStats.AvgCopyMs -lt $baseStats.AvgCopyMs)) {
        Write-Host "[VERDICT] APPROVE CANDIDATE: 0 crashes/removals and improved or equal performance." -ForegroundColor Green
        exit 0
    } else {
        Write-Host "[VERDICT] NEUTRAL / MANUAL REVIEW: 0 crashes, slight variance ($($prStats.AvgFps) vs $($baseStats.AvgFps) fps)." -ForegroundColor Yellow
        exit 0
    }
} finally {
    if (Test-Path $wtDir) {
        Invoke-GitQuiet @('worktree', 'remove', '--force', $wtDir)
    }
}
