#!/usr/bin/env pwsh
# spark.ps1 — Windows bootstrap for a fresh Kitsune machine.
#
# ┌─────────────────────────────────────────────────────────────────────┐
# │  MIRROR NOTICE                                                      │
# │                                                                     │
# │  This script has a POSIX twin at scripts/spark.sh which performs    │
# │  the equivalent setup on macOS and Linux. ANY behavioral change     │
# │  here (new step, reordered step, renamed identity, changed clone    │
# │  path, etc.) MUST be reflected in spark.sh in the same commit, and  │
# │  vice versa. Step numbering is shared between the two so a reader   │
# │  diff'ing them can confirm they stay in sync at a glance.           │
# └─────────────────────────────────────────────────────────────────────┘
#
# Run via the README one-liner. The script self-bootstraps pwsh 7 if the
# host is stock Windows PowerShell 5.1; everything below the bootstrap
# block runs in pwsh.
#
# Steps:
#   0.  Self-bootstrap PowerShell 7 (pwsh) if missing
#   1.  Git
#   2.  Node.js LTS
#   3.  Agency CLI
#   4.  VS Code
#   5.  GitHub CLI (gh)
#   5a. ed25519 SSH keys for github-chaos + github-msft
#   5b. ~/.ssh/config host alias blocks
#   5c. Per-identity ~/.gitconfig-chaos + ~/.gitconfig-msft
#   5d. Global ~/.gitconfig includeIf blocks (~/src/chaos, ~/src/msft)
#   5e. gh auth login for each identity
#   6.  Clone chaoticsoftware/Kitsune → ~/src/chaos/Kitsune
#   7.  npm install in local-store/ + text-renderer/
#   8.  Patch VS Code settings.json (chat.plugins.* keys)
#   9.  Open VS Code

param(
    # Skip the interactive passphrase prompt when generating SSH keys.
    # WARNING: private keys will be stored unencrypted on disk. Use only in
    # automated contexts where an agent is not available. Not settable via
    # the README one-liner (`iex` doesn't forward args); only meaningful when
    # the script is downloaded and invoked locally.
    [switch]$NoPassphrase
)

# ── 0. Self-bootstrap pwsh ────────────────────────────────────────────────────
#
# `irm | iex` runs in whatever shell the user pasted into. On a fresh Windows
# box that is Windows PowerShell 5.1 (`powershell.exe`). The rest of this
# script uses pwsh-7 features (ConvertFrom-Json -AsHashtable, certain pipeline
# behaviors), so install pwsh and re-launch ourselves there.

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "spark: PowerShell 7 (pwsh) not detected; installing via winget..." -ForegroundColor Cyan
    winget install Microsoft.PowerShell --accept-package-agreements --accept-source-agreements | Out-Null
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        Write-Host "spark: pwsh install did not put pwsh on PATH; open a new terminal and re-run." -ForegroundColor Red
        exit 1
    }
    Write-Host "spark: re-launching in pwsh..." -ForegroundColor Cyan
    pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/chaoticsoftware/flint/main/scripts/spark.ps1').Content"
    exit $LASTEXITCODE
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Step([string]$msg) { Write-Host "`n▶ $msg" -ForegroundColor Cyan }
function Write-Ok  ([string]$msg) { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "  ⚠ $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg) { Write-Host "  ✗ $msg" -ForegroundColor Red }

function Test-Cmd([string]$name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Update-PathEnv {
    # Re-read PATH so newly installed tools are visible without a new shell.
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path    = "$machinePath;$userPath"
}

# ── 1. Git ────────────────────────────────────────────────────────────────────

Write-Step "Checking Git..."
if (Test-Cmd 'git') {
    Write-Ok "Git already installed: $(git --version)"
} else {
    Write-Host "  Installing Git..."
    winget install --id Git.Git --exact --accept-package-agreements --accept-source-agreements
    Update-PathEnv
    if (Test-Cmd 'git') { Write-Ok "Git installed: $(git --version)" }
    else { Write-Fail "Git installation failed. Please install manually and re-run."; exit 1 }
}

# ── 2. Node.js LTS ────────────────────────────────────────────────────────────

Write-Step "Checking Node.js..."
if (Test-Cmd 'node') {
    Write-Ok "Node.js already installed: $(node --version)"
} else {
    Write-Host "  Installing Node.js LTS..."
    winget install --id OpenJS.NodeJS.LTS --exact --accept-package-agreements --accept-source-agreements
    Update-PathEnv
    if (Test-Cmd 'node') { Write-Ok "Node.js installed: $(node --version)" }
    else { Write-Fail "Node.js installation failed. Please install manually and re-run."; exit 1 }
}

# ── 3. Agency CLI ─────────────────────────────────────────────────────────────

Write-Step "Checking Agency CLI..."
if (Test-Cmd 'agency') {
    Write-Ok "Agency already installed: $(agency --version 2>&1 | Select-Object -First 1)"
} else {
    Write-Host "  Installing Agency CLI..."
    try {
        Invoke-Expression "& { $(Invoke-RestMethod 'https://aka.ms/InstallTool.ps1') } agency"
        Update-PathEnv
    } catch {
        Write-Warn "Agency install returned an error. This can happen when not on VPN."
        Write-Warn "If Agency is required, connect to VPN and re-run, or install manually: https://aka.ms/agency"
    }
    if (Test-Cmd 'agency') {
        Write-Ok "Agency installed: $(agency --version 2>&1 | Select-Object -First 1)"
    } else {
        Write-Warn "Agency not found on PATH after install. You may need to open a new terminal."
        Write-Warn "Continuing setup — you can install Agency later: https://aka.ms/agency"
    }
}

# ── 4. VS Code ────────────────────────────────────────────────────────────────

Write-Step "Checking VS Code..."
$codeCmd = if (Test-Cmd 'code') { 'code' } elseif (Test-Cmd 'code-insiders') { 'code-insiders' } else { $null }
if ($codeCmd) {
    Write-Ok "VS Code already installed ($codeCmd)."
} else {
    Write-Host "  Installing VS Code..."
    winget install --id Microsoft.VisualStudioCode --exact --accept-package-agreements --accept-source-agreements
    Update-PathEnv
    $codeCmd = if (Test-Cmd 'code') { 'code' } elseif (Test-Cmd 'code-insiders') { 'code-insiders' } else { $null }
    if ($codeCmd) { Write-Ok "VS Code installed ($codeCmd)." }
    else { Write-Fail "VS Code installation failed. Please install it manually: https://code.visualstudio.com"; exit 1 }
}

# ── 5. GitHub CLI (gh) ────────────────────────────────────────────────────────

Write-Step "Checking GitHub CLI..."
if (Test-Cmd 'gh') {
    Write-Ok "GitHub CLI already installed: $(gh --version | Select-Object -First 1)"
} else {
    Write-Host "  Installing GitHub CLI..."
    winget install --id GitHub.cli --exact --accept-package-agreements --accept-source-agreements
    Update-PathEnv
    if (-not (Test-Cmd 'gh')) {
        Write-Fail "GitHub CLI installation failed. Please install it manually: https://cli.github.com"
        exit 1
    }
    Write-Ok "GitHub CLI installed: $(gh --version | Select-Object -First 1)"
}

# Route all git ops through gh's credential helper.
git config --global credential.helper '!gh auth git-credential' 2>$null
Write-Ok "Git credential helper set to GitHub CLI."

# ── 5a. Dual-identity SSH keys ────────────────────────────────────────────────

Write-Step "Setting up dual-identity SSH keys (chaos + msft)..."

$sshDir = Join-Path $HOME '.ssh'
if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
}

if (-not $NoPassphrase) {
    Write-Host ""
    Write-Host "  A passphrase encrypts each private key on disk. You will be prompted" -ForegroundColor Cyan
    Write-Host "  once per key (enter the same value twice). Press Enter twice to leave" -ForegroundColor Cyan
    Write-Host "  it empty, or re-run with -NoPassphrase to skip the prompts entirely." -ForegroundColor Cyan
    Write-Host "  (Empty passphrases are not recommended on personal machines.)" -ForegroundColor Cyan
    Write-Host ""
}

foreach ($identity in @('github-chaos', 'github-msft')) {
    $keyPath = Join-Path $sshDir $identity
    if (Test-Path $keyPath) {
        Write-Ok "SSH key already exists: $keyPath"
    } else {
        Write-Host "  Generating ed25519 key for $identity..."
        if ($NoPassphrase) {
            ssh-keygen -t ed25519 -f $keyPath -N '' -C $identity 2>&1 | Out-Null
            Write-Warn "  Key generated without passphrase (-NoPassphrase). Private key is unencrypted on disk."
        } else {
            ssh-keygen -t ed25519 -f $keyPath -C $identity
        }
        Write-Ok "Generated $keyPath"
        Write-Host ""
        Write-Host "  ┌─────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
        Write-Host "  │  ACTION REQUIRED — add this public key to GitHub        │" -ForegroundColor Yellow
        Write-Host "  │                                                         │" -ForegroundColor Yellow
        if ($identity -eq 'github-chaos') {
            Write-Host "  │  Sign into your PERSONAL GitHub account, then go to:   │" -ForegroundColor Yellow
        } else {
            Write-Host "  │  Sign into your WORK GitHub account, then go to:       │" -ForegroundColor Yellow
        }
        Write-Host "  │  Settings → SSH and GPG Keys → New SSH key             │" -ForegroundColor Yellow
        Write-Host "  │                                                         │" -ForegroundColor Yellow
        Write-Host "  │  Public key to paste:                                   │" -ForegroundColor Yellow
        Write-Host "  └─────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
        Get-Content "$keyPath.pub"
        Write-Host ""
        Read-Host "  Press Enter once you have added the key to GitHub, then continue"
    }
}

# ── 5b. SSH config host aliases ───────────────────────────────────────────────

Write-Step "Configuring SSH host aliases..."

$sshConfigPath = Join-Path $sshDir 'config'
$sshConfigContent = if (Test-Path $sshConfigPath) { Get-Content $sshConfigPath -Raw } else { '' }

foreach ($identity in @('github-chaos', 'github-msft')) {
    $hostBlock = "Host $identity"
    if ($sshConfigContent -match [regex]::Escape($hostBlock)) {
        Write-Ok "SSH config block for $identity already present."
    } else {
        $block = @"

Host $identity
    HostName github.com
    User git
    IdentityFile ~/.ssh/$identity
    IdentitiesOnly yes
"@
        Add-Content -Path $sshConfigPath -Value $block
        Write-Ok "Added SSH config block for $identity."
    }
}

# ── 5c. Per-identity gitconfig files + url.insteadOf rewrites ─────────────────

Write-Step "Writing per-identity gitconfig files..."

$gitconfigChaos = Join-Path $HOME '.gitconfig-chaos'
$gitconfigMsft  = Join-Path $HOME '.gitconfig-msft'

$needChaos = -not (Test-Path $gitconfigChaos)
$needMsft  = -not (Test-Path $gitconfigMsft)

if ($needChaos) {
    Write-Host ""
    Write-Host "  Personal Git identity (written to ~/.gitconfig-chaos):" -ForegroundColor Cyan
    $chaosName  = Read-Host "    Full name"
    $chaosEmail = Read-Host "    Email"
}
if ($needMsft) {
    Write-Host ""
    Write-Host "  Work Git identity (written to ~/.gitconfig-msft):" -ForegroundColor Cyan
    $msftName  = Read-Host "    Full name"
    $msftEmail = Read-Host "    Email"
}

if ($needChaos) {
    @"
[user]
    name = $chaosName
    email = $chaosEmail

[url "git@github-chaos:"]
    insteadOf = git@github.com:
"@ | Set-Content $gitconfigChaos -Encoding utf8
    Write-Ok "Wrote $gitconfigChaos"
} else {
    Write-Ok "$gitconfigChaos already exists — skipped."
}

if ($needMsft) {
    @"
[user]
    name = $msftName
    email = $msftEmail

[url "git@github-msft:"]
    insteadOf = git@github.com:
"@ | Set-Content $gitconfigMsft -Encoding utf8
    Write-Ok "Wrote $gitconfigMsft"
} else {
    Write-Ok "$gitconfigMsft already exists — skipped."
}

# ── 5d. Global ~/.gitconfig includeIf blocks ─────────────────────────────────

Write-Step "Patching global ~/.gitconfig with includeIf blocks..."

$globalGitconfig = Join-Path $HOME '.gitconfig'
$globalContent   = if (Test-Path $globalGitconfig) { Get-Content $globalGitconfig -Raw } else { '' }

$chaosInclude = '[includeIf "gitdir:~/src/chaos/"]'
$msftInclude  = '[includeIf "gitdir:~/src/msft/"]'

if ($globalContent -match [regex]::Escape($chaosInclude)) {
    Write-Ok "includeIf block for ~/src/chaos/ already present."
} else {
    @"

[includeIf "gitdir:~/src/chaos/"]
    path = ~/.gitconfig-chaos
"@ | Add-Content -Path $globalGitconfig
    Write-Ok "Added includeIf block for ~/src/chaos/."
}

if ($globalContent -match [regex]::Escape($msftInclude)) {
    Write-Ok "includeIf block for ~/src/msft/ already present."
} else {
    @"

[includeIf "gitdir:~/src/msft/"]
    path = ~/.gitconfig-msft
"@ | Add-Content -Path $globalGitconfig
    Write-Ok "Added includeIf block for ~/src/msft/."
}

# ── 5e. gh auth login per identity ───────────────────────────────────────────
#
# gh 2.40+ stores multiple accounts per hostname natively; the second login
# does NOT overwrite the first. `gh auth switch -u <user>` selects the active
# account for gh CLI calls. Git operations are routed by SSH host alias +
# includeIf gitconfig, which are independent of which gh account is active.

Write-Step "Checking GitHub authentication (dual-identity)..."

$ghStatusOutput = gh auth status --hostname github.com 2>&1 | Out-String
$loggedInUsers = [regex]::Matches($ghStatusOutput, 'account\s+(\S+)') |
    ForEach-Object { $_.Groups[1].Value }

if ($loggedInUsers.Count -ge 2) {
    Write-Ok "Two or more accounts already logged in: $($loggedInUsers -join ', '). Skipping gh auth login."
} else {
    $chaosUsername = Read-Host "  Enter your PERSONAL GitHub username (chaos identity)"
    $msftUsername  = Read-Host "  Enter your WORK GitHub username (msft identity)"

    foreach ($entry in @(
        @{ label = 'personal (chaos)'; username = $chaosUsername },
        @{ label = 'work (msft)';      username = $msftUsername  }
    )) {
        if ($loggedInUsers -contains $entry.username) {
            Write-Ok "Already logged in as $($entry.username) ($($entry.label))."
        } else {
            Write-Host ""
            Write-Host "  ┌─────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
            Write-Host "  │  Logging in to $($entry.label) account ($($entry.username))" -ForegroundColor Cyan
            Write-Host "  │  Make sure your browser is signed into THAT account     │" -ForegroundColor Cyan
            Write-Host "  │  before approving the OAuth prompt.                     │" -ForegroundColor Cyan
            Write-Host "  └─────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
            gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key
            Write-Ok "Logged in as $($entry.username) ($($entry.label))."
        }
    }
}

Write-Ok "GitHub dual-identity auth complete."

# ── 6. Clone Kitsune ─────────────────────────────────────────────────────────

Write-Step "Cloning Kitsune..."

$cloneTarget = Join-Path $HOME 'src' 'chaos' 'Kitsune'

if (Test-Path (Join-Path $cloneTarget '.git')) {
    Write-Ok "Kitsune already cloned at $cloneTarget — pulling latest..."
    git -C $cloneTarget pull --ff-only
} else {
    $parentDir = Split-Path $cloneTarget
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    gh repo clone chaoticsoftware/Kitsune $cloneTarget
    Write-Ok "Cloned to $cloneTarget"
}

# ── 7. npm install ────────────────────────────────────────────────────────────

Write-Step "Installing npm dependencies..."

foreach ($pkg in @('local-store', 'text-renderer')) {
    $pkgDir = Join-Path $cloneTarget $pkg
    if (Test-Path (Join-Path $pkgDir 'package.json')) {
        Write-Host "  npm install in $pkg..."
        Push-Location $pkgDir
        try { npm install } finally { Pop-Location }
        Write-Ok "$pkg dependencies installed."
    } else {
        Write-Warn "$pkgDir/package.json not found — skipping."
    }
}

# ── 8. VS Code settings.json patch ───────────────────────────────────────────

Write-Step "Patching VS Code settings.json..."

$appData  = [System.Environment]::GetFolderPath('ApplicationData')
$insiders = Join-Path $appData 'Code - Insiders' 'User'
$stable   = Join-Path $appData 'Code' 'User'
$settingsDir = if ($codeCmd -eq 'code-insiders' -and (Test-Path $insiders)) { $insiders } else { $stable }

$settingsFile = Join-Path $settingsDir 'settings.json'

if (-not (Test-Path $settingsDir)) {
    New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
}

$settings = if (Test-Path $settingsFile) {
    try {
        Get-Content $settingsFile -Raw | ConvertFrom-Json -AsHashtable
    } catch {
        Write-Warn "settings.json exists but could not be parsed as JSON — backing up and starting fresh."
        Copy-Item $settingsFile "$settingsFile.bak"
        @{}
    }
} else {
    @{}
}

$changed = $false

if ($settings['chat.plugins.enabled'] -ne $true) {
    $settings['chat.plugins.enabled'] = $true
    $changed = $true
}

$marketplaces = $settings['chat.plugins.marketplaces']
$kitsune      = 'chaoticsoftware/Kitsune'
if ($marketplaces -isnot [System.Collections.IList] -or ($kitsune -notin $marketplaces)) {
    if ($marketplaces -isnot [System.Collections.IList]) {
        $settings['chat.plugins.marketplaces'] = @($kitsune)
    } else {
        $settings['chat.plugins.marketplaces'] = @($marketplaces) + $kitsune
    }
    $changed = $true
}

if ($changed) {
    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding utf8
    Write-Ok "VS Code settings.json updated at $settingsFile"
} else {
    Write-Ok "VS Code settings.json already up to date."
}

# ── 9. Open VS Code ───────────────────────────────────────────────────────────

Write-Step "Opening VS Code in $cloneTarget..."
& $codeCmd $cloneTarget

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host "  Kitsune setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host "    1. VS Code will prompt you to install the bionic-brain"
Write-Host "       plugin from the chaoticsoftware/Kitsune marketplace."
Write-Host "    2. Sign in to BOTH GitHub accounts in VS Code:"
Write-Host "       - Personal (chaos) account → binds bb-github-chaos MCP."
Write-Host "       - Work (msft) account     → binds bb-github-msft MCP."
Write-Host "       VS Code will prompt which account to bind when each"
Write-Host "       server is first used. Verify with bb-github-*.get_me."
Write-Host "    3. Run /configure in any Copilot Chat session to finish"
Write-Host "       per-user setup (learner repo, journal paths, etc.)."
Write-Host "    4. Install workiq CLI separately — see bionic-brain README."
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
