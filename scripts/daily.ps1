<#
.SYNOPSIS
    Appends today's daybook entry, commits it as "log: <date>" and pushes to origin/main.

.DESCRIPTION
    - Entry path: entries/yyyy-MM-dd.md
    - If the entry already exists the script exits 0 without writing or committing,
      so it is safe to run more than once per day.
    - PR activity comes from `gh search prs` for the last 24h; a failed gh call is
      recorded as "- No activity recorded" instead of aborting the run.
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

# --- 1/2. already logged today? exit 0 silently -----------------------------
if (Test-Path -LiteralPath $entryPath) {
    exit 0
}

Write-Log "daybook start: date=$date repo=$repoPath"

if (-not (Test-Path -LiteralPath $entriesDir)) {
    New-Item -ItemType Directory -Path $entriesDir -Force | Out-Null
}

$git = Resolve-Exe -Name 'git' -Fallbacks @('C:\Program Files\Git\cmd\git.exe')
$gh  = Resolve-Exe -Name 'gh'  -Fallbacks @('C:\Program Files\GitHub CLI\gh.exe')

# --- 3/4. work log from the last 24h ---------------------------------------
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
    $prs = @($raw | Out-String | ConvertFrom-Json)
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

# --- 3. write the entry -----------------------------------------------------
$lines = @("# $date", '', '## Work log', '') + $workLog + @('', '## Notes', '', '- ')
$content = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
[System.IO.File]::WriteAllText($entryPath, $content, (New-Object System.Text.UTF8Encoding($false)))
Write-Log "wrote entries/$date.md"

# --- 5. commit and push -----------------------------------------------------
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

$pushCode = Invoke-Captured -FilePath $git -Arguments @('-C', $repoPath, 'push', 'origin', 'main')
if ($pushCode -ne 0) {
    Write-Log "git push failed (exit $pushCode)"
    $exitCode = 1
}

Write-Log "daybook done: date=$date exit=$exitCode"
exit $exitCode
