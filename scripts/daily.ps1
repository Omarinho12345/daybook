<#
.SYNOPSIS
    Appends today's daybook entry, commits it as "log: <date>" and pushes to origin/main.

.DESCRIPTION
    - Entry path: entries/yyyy-MM-dd.md
    - Runs are idempotent and self-healing: when the entry already exists it is not
      rewritten, but the commit/push steps still execute, so an entry created while
      the network was down is pushed by the next run instead of being left behind.
    - Waits (bounded) for GitHub to be reachable before calling gh/git, because Task
      Scheduler can fire this a few seconds after the laptop leaves Modern Standby.
    - PR activity comes from `gh search prs` for the last 24h; a failed gh call is
      recorded as "- No activity recorded" instead of aborting the run.
    - `git push` is retried; the script exits non-zero if the push never succeeds,
      so the task's Last Result reflects the real outcome.
    - All output is appended to scripts/daily.log.
    - The repository is resolved from this script's location, so the script works
      from Task Scheduler with any working directory.
#>

$ErrorActionPreference = 'Continue'

# Never block on an interactive prompt when running unattended.
$env:GIT_TERMINAL_PROMPT = '0'
$env:GH_PROMPT_DISABLED  = '1'

# --- locations (derived from the script itself, not the current directory) ----
$scriptDir  = $PSScriptRoot
$repoPath   = Split-Path -Parent $scriptDir
$logPath    = Join-Path $scriptDir 'daily.log'
$entriesDir = Join-Path $repoPath 'entries'

$date      = Get-Date -Format 'yyyy-MM-dd'
$entryPath = Join-Path $entriesDir "$date.md"
$author    = 'Omarinho12345'

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding utf8 -ErrorAction Stop } catch { }
}

function Resolve-Exe {
    param([string]$Name, [string[]]$Fallbacks)
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($candidate in $Fallbacks) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Invoke-Captured {
    # Runs a native command, mirrors every line of output into the log and
    # returns its exit code.
    param([string]$FilePath, [string[]]$Arguments)
    if (-not $FilePath) {
        Write-Log '  command not found'
        return 127
    }
    $output = & $FilePath @Arguments 2>&1
    $code   = $LASTEXITCODE
    foreach ($item in @($output)) {
        $text = ('{0}' -f $item).TrimEnd()
        if ($text) { Write-Log "  $text" }
    }
    return $code
}

function Test-GitHubReachable {
    param([string]$Target, [int]$TimeoutMs = 4000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($Target, 443, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected) { return $true }
        return $false
    }
    catch { return $false }
    finally { try { $client.Close() } catch { } }
}

function Wait-ForNetwork {
    param([int]$TimeoutSeconds = 180, [int]$IntervalSeconds = 5)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        if ((Test-GitHubReachable 'api.github.com') -or (Test-GitHubReachable 'github.com')) {
            return $true
        }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Seconds $IntervalSeconds
    }
}

function Invoke-Push {
    param([string]$Git, [int]$Attempts = 3, [int]$DelaySeconds = 10)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $code = Invoke-Captured -FilePath $Git -Arguments @('-C', $repoPath, 'push', 'origin', 'main')
        if ($code -eq 0) { return 0 }
        Write-Log "git push attempt $attempt/$Attempts failed (exit $code)"
        if ($attempt -lt $Attempts) {
            [void](Wait-ForNetwork -TimeoutSeconds 60)
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    return 1
}

$git = Resolve-Exe -Name 'git' -Fallbacks @('C:\Program Files\Git\cmd\git.exe')
$gh  = Resolve-Exe -Name 'gh'  -Fallbacks @('C:\Program Files\GitHub CLI\gh.exe')

$entryExists = Test-Path -LiteralPath $entryPath

# --- 0. no-op fast path: logged, committed and already on origin/main --------
# Scheduled repetition and StartWhenAvailable mean this may run several times a
# day; the common case should cost nothing and touch the network not at all.
if ($entryExists) {
    $aheadCount = (& $git -C $repoPath rev-list --count 'origin/main..HEAD' 2>&1 | Out-String).Trim()
    $entryDirty = (& $git -C $repoPath status --porcelain -- "entries/$date.md" 2>&1 | Out-String).Trim()
    if ($aheadCount -eq '0' -and -not $entryDirty) {
        Write-Log "daybook noop: date=$date already committed and pushed"
        exit 0
    }
}

# --- 1. connectivity first: this often fires seconds after leaving standby --
if (-not (Wait-ForNetwork -TimeoutSeconds 180)) {
    Write-Log 'network unavailable after 180s; continuing (gh/git calls may fail)'
}

if ($entryExists) {
    Write-Log "daybook resume: date=$date entry exists but is not on origin/main yet; ensuring it is committed and pushed"
}
else {
    Write-Log "daybook start: date=$date repo=$repoPath"

    if (-not (Test-Path -LiteralPath $entriesDir)) {
        New-Item -ItemType Directory -Path $entriesDir -Force | Out-Null
    }

    # --- 2. work log from the last 24h -------------------------------------
    $workLog = @()
    if (-not $gh) {
        Write-Log 'gh CLI not found; recording "- No activity recorded"'
    }
    else {
        try {
            $ghArgs = @(
                'search', 'prs',
                '--author', $author,
                '--updated', $date,
                '--json', 'repository,number,title,state',
                '--limit', '100'
            )
            $raw = & $gh @ghArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ("gh search prs exited with code {0}: {1}" -f $LASTEXITCODE, (($raw | Out-String).Trim()))
            }
            # gh prints one JSON array; join defensively, then parse. ConvertFrom-Json
            # hands back the whole array as a single pipeline object, so wrap the
            # result in @() only after it has been assigned (otherwise a run with two
            # or more PRs would be treated as one "PR" whose fields are Object[]).
            $json = (@($raw) -join "`n")
            $parsed = $json | ConvertFrom-Json
            $prs = @($parsed)
            foreach ($pr in $prs) {
                $repoName = if ($pr.repository -and $pr.repository.nameWithOwner) { $pr.repository.nameWithOwner }
                            elseif ($pr.repository -and $pr.repository.name) { $pr.repository.name }
                            else { 'unknown' }
                $workLog += ('- {0}#{1} {2} - {3}' -f $repoName, $pr.number, $pr.state, $pr.title)
            }
            Write-Log ("gh search prs: {0} result(s)" -f $prs.Count)
        }
        catch {
            Write-Log ("gh search prs failed: {0}" -f $_.Exception.Message)
            $workLog = @()
        }
    }

    if ($workLog.Count -eq 0) {
        $workLog = @('- No activity recorded')
        Write-Log 'no PR activity found; entry records "- No activity recorded"'
    }

    # --- 3. write the entry -------------------------------------------------
    $lines = @("# $date", '', '## Work log', '') + $workLog + @('', '## Notes', '', '- ')
    $content = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    [System.IO.File]::WriteAllText($entryPath, $content, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log "wrote entries/$date.md"
}

# --- 4. commit (only when something is staged) ------------------------------
$exitCode = 0

$addCode = Invoke-Captured -FilePath $git -Arguments @('-C', $repoPath, 'add', '--', "entries/$date.md")
if ($addCode -ne 0) {
    Write-Log "git add failed (exit $addCode)"
    exit 1
}

$staged = & $git -C $repoPath diff --cached --quiet 2>&1
if ($LASTEXITCODE -ne 0) {
    $commitCode = Invoke-Captured -FilePath $git -Arguments @('-C', $repoPath, 'commit', '-m', "log: $date")
    if ($commitCode -ne 0) {
        Write-Log "git commit failed (exit $commitCode)"
        exit 1
    }
}
else {
    Write-Log 'nothing staged; skipping commit'
}

# --- 5. push, retrying across a flaky post-wake connection ------------------
$pushCode = Invoke-Push -Git $git
if ($pushCode -ne 0) {
    Write-Log "git push failed (exit $pushCode)"
    $exitCode = 1
}

Write-Log "daybook done: date=$date exit=$exitCode"
exit $exitCode
