#!/usr/bin/env bash
# spark.sh — macOS / Linux bootstrap for a fresh Kitsune machine.
#
# ┌─────────────────────────────────────────────────────────────────────┐
# │  MIRROR NOTICE                                                      │
# │                                                                     │
# │  This script has a PowerShell twin at scripts/spark.ps1 which       │
# │  performs the equivalent setup on Windows. ANY behavioral change    │
# │  here (new step, reordered step, renamed identity, changed clone    │
# │  path, etc.) MUST be reflected in spark.ps1 in the same commit, and │
# │  vice versa. Step numbering is shared between the two so a reader   │
# │  diff'ing them can confirm they stay in sync at a glance.           │
# └─────────────────────────────────────────────────────────────────────┘
#
# Run via the README one-liner. Works on macOS (Homebrew) and on Linux
# distros with apt / dnf / yum / pacman.
#
# Steps:
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

set -euo pipefail

# ── Flags ────────────────────────────────────────────────────────────────────

NO_PASSPHRASE=0
for arg in "$@"; do
    case "$arg" in
        --no-passphrase)
            # WARNING: private keys will be stored unencrypted on disk. Use
            # only in automated contexts where an agent is not available.
            NO_PASSPHRASE=1
            ;;
        *)
            echo "spark: unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────

# Colors only when stdout is a tty.
if [ -t 1 ]; then
    C_STEP=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_OFF=$'\033[0m'
else
    C_STEP=''; C_OK=''; C_WARN=''; C_FAIL=''; C_OFF=''
fi

step() { printf '\n%s▶ %s%s\n' "$C_STEP" "$1" "$C_OFF"; }
ok()   { printf '  %s✓ %s%s\n'  "$C_OK"   "$1" "$C_OFF"; }
warn() { printf '  %s⚠ %s%s\n'  "$C_WARN" "$1" "$C_OFF"; }
fail() { printf '  %s✗ %s%s\n'  "$C_FAIL" "$1" "$C_OFF"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ── Platform detection ───────────────────────────────────────────────────────

OS="$(uname -s)"
case "$OS" in
    Darwin) PLATFORM=macos ;;
    Linux)  PLATFORM=linux ;;
    *)      fail "Unsupported OS: $OS. spark.sh targets macOS and Linux only."; exit 1 ;;
esac

LINUX_PM=""
if [ "$PLATFORM" = linux ]; then
    if   have apt-get; then LINUX_PM=apt
    elif have dnf;     then LINUX_PM=dnf
    elif have yum;     then LINUX_PM=yum
    elif have pacman;  then LINUX_PM=pacman
    else fail "Could not detect a supported Linux package manager (apt/dnf/yum/pacman)."; exit 1
    fi
fi

# Homebrew is the macOS workhorse — install it if absent before anything else.
if [ "$PLATFORM" = macos ] && ! have brew; then
    step "Installing Homebrew (required on macOS)..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Homebrew on Apple Silicon installs to /opt/homebrew; on Intel to /usr/local.
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    ok "Homebrew installed."
fi

# ── 1. Git ────────────────────────────────────────────────────────────────────

step "Checking Git..."
if have git; then
    ok "Git already installed: $(git --version)"
else
    echo "  Installing Git..."
    case "$PLATFORM" in
        macos) brew install git ;;
        linux)
            case "$LINUX_PM" in
                apt)    sudo apt-get update -q && sudo apt-get install -y git ;;
                dnf)    sudo dnf install -y git ;;
                yum)    sudo yum install -y git ;;
                pacman) sudo pacman -Sy --noconfirm git ;;
            esac
            ;;
    esac
    if have git; then ok "Git installed: $(git --version)"
    else fail "Git installation failed. Please install manually and re-run."; exit 1
    fi
fi

# ── 2. Node.js LTS ────────────────────────────────────────────────────────────

step "Checking Node.js..."
if have node; then
    ok "Node.js already installed: $(node --version)"
else
    echo "  Installing Node.js LTS..."
    case "$PLATFORM" in
        macos) brew install node ;;
        linux)
            case "$LINUX_PM" in
                apt)
                    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
                    sudo apt-get install -y nodejs
                    ;;
                dnf|yum)
                    curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -
                    sudo "$LINUX_PM" install -y nodejs
                    ;;
                pacman)
                    sudo pacman -Sy --noconfirm nodejs npm
                    ;;
            esac
            ;;
    esac
    if have node; then ok "Node.js installed: $(node --version)"
    else fail "Node.js installation failed. Please install manually and re-run."; exit 1
    fi
fi

# ── 3. Agency CLI ─────────────────────────────────────────────────────────────

step "Checking Agency CLI..."
if have agency; then
    ok "Agency already installed: $(agency --version 2>&1 | head -n1)"
else
    echo "  Installing Agency CLI..."
    if curl -sSfL https://aka.ms/InstallTool.sh | sh -s agency; then
        # The installer modifies the shell profile; pull common bin dirs onto
        # PATH for this session.
        export PATH="$PATH:$HOME/.local/bin:/usr/local/bin"
    else
        warn "Agency install returned an error. This can happen when not on VPN."
        warn "If Agency is required, connect to VPN and re-run, or install manually: https://aka.ms/agency"
    fi
    if have agency; then
        ok "Agency installed: $(agency --version 2>&1 | head -n1)"
    else
        warn "Agency not found on PATH after install. You may need to open a new terminal."
        warn "Continuing setup — you can install Agency later: https://aka.ms/agency"
    fi
fi

# ── 4. VS Code ────────────────────────────────────────────────────────────────

step "Checking VS Code..."
CODE_CMD=""
if   have code;          then CODE_CMD=code
elif have code-insiders; then CODE_CMD=code-insiders
fi

if [ -n "$CODE_CMD" ]; then
    ok "VS Code already installed ($CODE_CMD)."
else
    echo "  Installing VS Code..."
    case "$PLATFORM" in
        macos) brew install --cask visual-studio-code ;;
        linux)
            case "$LINUX_PM" in
                apt)
                    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
                        | sudo gpg --dearmor -o /usr/share/keyrings/packages.microsoft.gpg
                    echo "deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
                        | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
                    sudo apt-get update -q
                    sudo apt-get install -y code
                    ;;
                dnf|yum)
                    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
                    sudo sh -c 'cat > /etc/yum.repos.d/vscode.repo <<EOF
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF'
                    sudo "$LINUX_PM" install -y code
                    ;;
                pacman)
                    warn "VS Code is not in the official Arch repos. Install from AUR (visual-studio-code-bin) manually."
                    ;;
            esac
            ;;
    esac
    if   have code;          then CODE_CMD=code
    elif have code-insiders; then CODE_CMD=code-insiders
    fi
    if [ -n "$CODE_CMD" ]; then
        ok "VS Code installed ($CODE_CMD)."
    else
        fail "VS Code installation failed. Please install it manually: https://code.visualstudio.com"
        exit 1
    fi
fi

# ── 5. GitHub CLI (gh) ────────────────────────────────────────────────────────

step "Checking GitHub CLI..."
if have gh; then
    ok "GitHub CLI already installed: $(gh --version | head -n1)"
else
    echo "  Installing GitHub CLI..."
    case "$PLATFORM" in
        macos) brew install gh ;;
        linux)
            case "$LINUX_PM" in
                apt)
                    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
                        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
                    sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
                    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
                        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
                    sudo apt-get update -q
                    sudo apt-get install -y gh
                    ;;
                dnf|yum)
                    sudo "$LINUX_PM" install -y 'dnf-command(config-manager)' 2>/dev/null || true
                    sudo "$LINUX_PM" config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
                    sudo "$LINUX_PM" install -y gh
                    ;;
                pacman)
                    sudo pacman -Sy --noconfirm github-cli
                    ;;
            esac
            ;;
    esac
    if ! have gh; then
        fail "GitHub CLI installation failed. Please install it manually: https://cli.github.com"
        exit 1
    fi
    ok "GitHub CLI installed: $(gh --version | head -n1)"
fi

# Route all git ops through gh's credential helper.
git config --global credential.helper '!gh auth git-credential' 2>/dev/null || true
ok "Git credential helper set to GitHub CLI."

# ── 5a. Dual-identity SSH keys ────────────────────────────────────────────────

step "Setting up dual-identity SSH keys (chaos + msft)..."

SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [ "$NO_PASSPHRASE" -eq 0 ]; then
    echo ""
    echo "  ${C_STEP}A passphrase encrypts each private key on disk. You will be prompted${C_OFF}"
    echo "  ${C_STEP}once per key (enter the same value twice). Press Enter twice to leave${C_OFF}"
    echo "  ${C_STEP}it empty, or re-run with --no-passphrase to skip the prompts entirely.${C_OFF}"
    echo "  ${C_STEP}(Empty passphrases are not recommended on personal machines.)${C_OFF}"
    echo ""
fi

for identity in github-chaos github-msft; do
    KEY_PATH="$SSH_DIR/$identity"
    if [ -f "$KEY_PATH" ]; then
        ok "SSH key already exists: $KEY_PATH"
    else
        echo "  Generating ed25519 key for $identity..."
        if [ "$NO_PASSPHRASE" -eq 1 ]; then
            ssh-keygen -t ed25519 -f "$KEY_PATH" -N '' -C "$identity" >/dev/null
            warn "  Key generated without passphrase (--no-passphrase). Private key is unencrypted on disk."
        else
            ssh-keygen -t ed25519 -f "$KEY_PATH" -C "$identity"
        fi
        chmod 600 "$KEY_PATH"
        chmod 644 "$KEY_PATH.pub"
        ok "Generated $KEY_PATH"
        echo ""
        printf '%s  ┌─────────────────────────────────────────────────────────┐%s\n' "$C_WARN" "$C_OFF"
        printf '%s  │  ACTION REQUIRED — add this public key to GitHub        │%s\n' "$C_WARN" "$C_OFF"
        printf '%s  │                                                         │%s\n' "$C_WARN" "$C_OFF"
        if [ "$identity" = "github-chaos" ]; then
            printf '%s  │  Sign into your PERSONAL GitHub account, then go to:   │%s\n' "$C_WARN" "$C_OFF"
        else
            printf '%s  │  Sign into your WORK GitHub account, then go to:       │%s\n' "$C_WARN" "$C_OFF"
        fi
        printf '%s  │  Settings → SSH and GPG Keys → New SSH key             │%s\n' "$C_WARN" "$C_OFF"
        printf '%s  │                                                         │%s\n' "$C_WARN" "$C_OFF"
        printf '%s  │  Public key to paste:                                   │%s\n' "$C_WARN" "$C_OFF"
        printf '%s  └─────────────────────────────────────────────────────────┘%s\n' "$C_WARN" "$C_OFF"
        cat "$KEY_PATH.pub"
        echo ""
        read -r -p "  Press Enter once you have added the key to GitHub, then continue: " _
    fi
done

# ── 5b. SSH config host aliases ───────────────────────────────────────────────

step "Configuring SSH host aliases..."

SSH_CONFIG="$SSH_DIR/config"
touch "$SSH_CONFIG"

for identity in github-chaos github-msft; do
    if grep -q "^Host $identity\$" "$SSH_CONFIG" 2>/dev/null; then
        ok "SSH config block for $identity already present."
    else
        cat >>"$SSH_CONFIG" <<EOF

Host $identity
    HostName github.com
    User git
    IdentityFile ~/.ssh/$identity
    IdentitiesOnly yes
EOF
        ok "Added SSH config block for $identity."
    fi
done

chmod 600 "$SSH_CONFIG"

# ── 5c. Per-identity gitconfig files + url.insteadOf rewrites ─────────────────

step "Writing per-identity gitconfig files..."

GITCONFIG_CHAOS="$HOME/.gitconfig-chaos"
GITCONFIG_MSFT="$HOME/.gitconfig-msft"

NEED_CHAOS=0; [ ! -f "$GITCONFIG_CHAOS" ] && NEED_CHAOS=1
NEED_MSFT=0;  [ ! -f "$GITCONFIG_MSFT"  ] && NEED_MSFT=1

if [ "$NEED_CHAOS" -eq 1 ]; then
    echo ""
    printf '  %sPersonal Git identity (written to ~/.gitconfig-chaos):%s\n' "$C_STEP" "$C_OFF"
    read -r -p "    Full name: " CHAOS_NAME
    read -r -p "    Email: "     CHAOS_EMAIL
fi
if [ "$NEED_MSFT" -eq 1 ]; then
    echo ""
    printf '  %sWork Git identity (written to ~/.gitconfig-msft):%s\n' "$C_STEP" "$C_OFF"
    read -r -p "    Full name: " MSFT_NAME
    read -r -p "    Email: "     MSFT_EMAIL
fi

if [ "$NEED_CHAOS" -eq 1 ]; then
    cat >"$GITCONFIG_CHAOS" <<EOF
[user]
    name = $CHAOS_NAME
    email = $CHAOS_EMAIL

[url "git@github-chaos:"]
    insteadOf = git@github.com:
EOF
    ok "Wrote $GITCONFIG_CHAOS"
else
    ok "$GITCONFIG_CHAOS already exists — skipped."
fi

if [ "$NEED_MSFT" -eq 1 ]; then
    cat >"$GITCONFIG_MSFT" <<EOF
[user]
    name = $MSFT_NAME
    email = $MSFT_EMAIL

[url "git@github-msft:"]
    insteadOf = git@github.com:
EOF
    ok "Wrote $GITCONFIG_MSFT"
else
    ok "$GITCONFIG_MSFT already exists — skipped."
fi

# ── 5d. Global ~/.gitconfig includeIf blocks ─────────────────────────────────

step "Patching global ~/.gitconfig with includeIf blocks..."

GLOBAL_GITCONFIG="$HOME/.gitconfig"
touch "$GLOBAL_GITCONFIG"

if grep -q 'gitdir:~/src/chaos/' "$GLOBAL_GITCONFIG"; then
    ok "includeIf block for ~/src/chaos/ already present."
else
    cat >>"$GLOBAL_GITCONFIG" <<'EOF'

[includeIf "gitdir:~/src/chaos/"]
    path = ~/.gitconfig-chaos
EOF
    ok "Added includeIf block for ~/src/chaos/."
fi

if grep -q 'gitdir:~/src/msft/' "$GLOBAL_GITCONFIG"; then
    ok "includeIf block for ~/src/msft/ already present."
else
    cat >>"$GLOBAL_GITCONFIG" <<'EOF'

[includeIf "gitdir:~/src/msft/"]
    path = ~/.gitconfig-msft
EOF
    ok "Added includeIf block for ~/src/msft/."
fi

# ── 5e. gh auth login per identity ───────────────────────────────────────────
#
# gh 2.40+ stores multiple accounts per hostname natively; the second login
# does NOT overwrite the first. `gh auth switch -u <user>` selects the active
# account for gh CLI calls. Git operations are routed by SSH host alias +
# includeIf gitconfig, which are independent of which gh account is active.

step "Checking GitHub authentication (dual-identity)..."

GH_STATUS="$(gh auth status --hostname github.com 2>&1 || true)"
LOGGED_IN_USERS="$(printf '%s\n' "$GH_STATUS" | grep -oE 'account[[:space:]]+[^[:space:]]+' | awk '{print $2}' | sort -u)"
LOGGED_IN_COUNT=0
[ -n "$LOGGED_IN_USERS" ] && LOGGED_IN_COUNT=$(printf '%s\n' "$LOGGED_IN_USERS" | wc -l | tr -d ' ')

if [ "$LOGGED_IN_COUNT" -ge 2 ]; then
    ok "Two or more accounts already logged in: $(printf '%s' "$LOGGED_IN_USERS" | tr '\n' ',' | sed 's/,$//; s/,/, /g'). Skipping gh auth login."
else
    read -r -p "  Enter your PERSONAL GitHub username (chaos identity): " CHAOS_USERNAME
    read -r -p "  Enter your WORK GitHub username (msft identity): "     MSFT_USERNAME

    for entry in "personal (chaos)|$CHAOS_USERNAME" "work (msft)|$MSFT_USERNAME"; do
        LABEL="${entry%%|*}"
        USERNAME="${entry##*|}"
        if printf '%s\n' "$LOGGED_IN_USERS" | grep -qx "$USERNAME"; then
            ok "Already logged in as $USERNAME ($LABEL)."
        else
            echo ""
            printf '%s  ┌─────────────────────────────────────────────────────────┐%s\n' "$C_STEP" "$C_OFF"
            printf '%s  │  Logging in to %s account (%s)%s\n' "$C_STEP" "$LABEL" "$USERNAME" "$C_OFF"
            printf '%s  │  Make sure your browser is signed into THAT account     │%s\n' "$C_STEP" "$C_OFF"
            printf '%s  │  before approving the OAuth prompt.                     │%s\n' "$C_STEP" "$C_OFF"
            printf '%s  └─────────────────────────────────────────────────────────┘%s\n' "$C_STEP" "$C_OFF"
            gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key
            ok "Logged in as $USERNAME ($LABEL)."
        fi
    done
fi

ok "GitHub dual-identity auth complete."

# ── 6. Clone Kitsune ─────────────────────────────────────────────────────────

step "Cloning Kitsune..."

CLONE_TARGET="$HOME/src/chaos/Kitsune"

if [ -d "$CLONE_TARGET/.git" ]; then
    ok "Kitsune already cloned at $CLONE_TARGET — pulling latest..."
    git -C "$CLONE_TARGET" pull --ff-only
else
    mkdir -p "$(dirname "$CLONE_TARGET")"
    gh repo clone chaoticsoftware/Kitsune "$CLONE_TARGET"
    ok "Cloned to $CLONE_TARGET"
fi

# ── 7. npm install ────────────────────────────────────────────────────────────

step "Installing npm dependencies..."

for pkg in local-store text-renderer; do
    PKG_DIR="$CLONE_TARGET/$pkg"
    if [ -f "$PKG_DIR/package.json" ]; then
        echo "  npm install in $pkg..."
        ( cd "$PKG_DIR" && npm install )
        ok "$pkg dependencies installed."
    else
        warn "$PKG_DIR/package.json not found — skipping."
    fi
done

# ── 8. VS Code settings.json patch ───────────────────────────────────────────
#
# We use Node (just installed) to do a structure-preserving JSON edit. jq
# would also work but is not present by default on macOS, and we already
# require Node for the rest of the toolchain.

step "Patching VS Code settings.json..."

# Resolve platform-specific settings dir; prefer Insiders when the chosen
# code binary is `code-insiders` AND its settings dir exists.
case "$PLATFORM" in
    macos)
        BASE="$HOME/Library/Application Support"
        ;;
    linux)
        BASE="${XDG_CONFIG_HOME:-$HOME/.config}"
        ;;
esac

INSIDERS_DIR="$BASE/Code - Insiders/User"
STABLE_DIR="$BASE/Code/User"
if [ "$CODE_CMD" = "code-insiders" ] && [ -d "$INSIDERS_DIR" ]; then
    SETTINGS_DIR="$INSIDERS_DIR"
else
    SETTINGS_DIR="$STABLE_DIR"
fi

SETTINGS_FILE="$SETTINGS_DIR/settings.json"
mkdir -p "$SETTINGS_DIR"

# If the file does not exist, start with an empty object so the Node script
# below has something to read.
if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{}' >"$SETTINGS_FILE"
fi

CHANGED=$(SETTINGS_FILE="$SETTINGS_FILE" node <<'JS'
const fs = require('fs');
const path = process.env.SETTINGS_FILE;
let raw;
try { raw = fs.readFileSync(path, 'utf8'); } catch (e) { raw = '{}'; }
let s;
try { s = JSON.parse(raw); }
catch (e) {
    // Back up the unparseable file and start fresh.
    fs.copyFileSync(path, path + '.bak');
    s = {};
}
let changed = false;
if (s['chat.plugins.enabled'] !== true) {
    s['chat.plugins.enabled'] = true;
    changed = true;
}
const kitsune = 'chaoticsoftware/Kitsune';
const mk = s['chat.plugins.marketplaces'];
if (!Array.isArray(mk)) {
    s['chat.plugins.marketplaces'] = [kitsune];
    changed = true;
} else if (!mk.includes(kitsune)) {
    s['chat.plugins.marketplaces'] = mk.concat([kitsune]);
    changed = true;
}
if (changed) {
    fs.writeFileSync(path, JSON.stringify(s, null, 4) + '\n');
}
process.stdout.write(changed ? '1' : '0');
JS
)

if [ "$CHANGED" = "1" ]; then
    ok "VS Code settings.json updated at $SETTINGS_FILE"
else
    ok "VS Code settings.json already up to date."
fi

# ── 9. Open VS Code ───────────────────────────────────────────────────────────

step "Opening VS Code in $CLONE_TARGET..."
"$CODE_CMD" "$CLONE_TARGET"

echo ""
printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_OK" "$C_OFF"
printf '%s  Kitsune setup complete!%s\n' "$C_OK" "$C_OFF"
echo ""
echo "  Next steps:"
echo "    1. VS Code will prompt you to install the bionic-brain"
echo "       plugin from the chaoticsoftware/Kitsune marketplace."
echo "    2. Sign in to BOTH GitHub accounts in VS Code:"
echo "       - Personal (chaos) account → binds bb-github-chaos MCP."
echo "       - Work (msft) account     → binds bb-github-msft MCP."
echo "       VS Code will prompt which account to bind when each"
echo "       server is first used. Verify with bb-github-*.get_me."
echo "    3. Run /configure in any Copilot Chat session to finish"
echo "       per-user setup (learner repo, journal paths, etc.)."
echo "    4. Install workiq CLI separately — see bionic-brain README."
printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_OK" "$C_OFF"
