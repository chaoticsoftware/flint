# flint

A primitive tool for striking a spark on a cold, blank machine, to raise phoenix from the ashes.

`spark` is the bootstrap one-liner. Run it on a fresh box and you'll end up with a fully configured
[Kitsune](https://github.com/chaoticsoftware/Kitsune) workstation: Git + Node + Agency + VS Code + GitHub CLI,
dual GitHub identities (personal + work) wired through SSH host aliases and `includeIf`-scoped gitconfig,
Kitsune cloned to `~/src/chaos/Kitsune`, npm dependencies installed, and VS Code launched into the workspace
with the `chaoticsoftware/Kitsune` chat plugin marketplace registered.

## Quick start

### Windows

Open a PowerShell window (stock `powershell.exe` is fine — the script self-bootstraps `pwsh` if missing) and run:

```powershell
irm https://raw.githubusercontent.com/chaoticsoftware/flint/main/scripts/spark.ps1 | iex
```

### macOS / Linux

Open a terminal and run:

```bash
curl -fsSL https://raw.githubusercontent.com/chaoticsoftware/flint/main/scripts/spark.sh | bash
```

Linux is supported on distros with `apt`, `dnf`, `yum`, or `pacman`. macOS installs Homebrew on the fly if absent.

## What spark does

In order:

1. Installs **Git**.
2. Installs **Node.js** (LTS).
3. Installs the **Agency CLI** (best-effort; needs corporate VPN — non-fatal if it fails).
4. Installs **VS Code** (stable; Insiders is detected if already present).
5. Installs **GitHub CLI (`gh`)** and wires `git` to use it as the credential helper.
   1. Generates ed25519 SSH keys for two identities: `github-chaos` (personal) and `github-msft` (work),
      pausing after each so you can paste the public key into the matching GitHub account.
   2. Writes `Host github-chaos` / `Host github-msft` blocks to `~/.ssh/config`.
   3. Creates per-identity `~/.gitconfig-chaos` and `~/.gitconfig-msft` with `user.name`/`user.email`
      and a `url.insteadOf` rewrite so plain `git@github.com:` URLs route through the correct alias.
   4. Adds `includeIf "gitdir:~/src/chaos/"` and `includeIf "gitdir:~/src/msft/"` blocks to `~/.gitconfig`
      so the right identity is selected based on which folder a repo lives in.
   5. Runs `gh auth login` once per identity (skipped if both accounts are already authenticated).
6. Clones `chaoticsoftware/Kitsune` to `~/src/chaos/Kitsune`.
7. Runs `npm install` in `local-store/` and `text-renderer/`.
8. Patches VS Code `settings.json` to enable chat plugins and register the
   `chaoticsoftware/Kitsune` marketplace.
9. Opens VS Code in the freshly cloned Kitsune workspace.

After it finishes, accept VS Code's prompt to install the **bionic-brain** plugin from the
`chaoticsoftware/Kitsune` marketplace, then sign in to both GitHub accounts in VS Code so the
`bb-github-chaos` and `bb-github-msft` MCP servers can bind to the right account.

## Flags

Both scripts accept a single flag to skip the SSH key passphrase prompts:

- `spark.ps1`: `-NoPassphrase`
- `spark.sh`: `--no-passphrase`

Passing the flag stores both private keys unencrypted on disk. Only use this in automated contexts
where an agent isn't available to hold the passphrase. The flag is only meaningful when the script is
downloaded and invoked locally — the README one-liner doesn't forward args.

## Source

- [`scripts/spark.ps1`](scripts/spark.ps1) — Windows
- [`scripts/spark.sh`](scripts/spark.sh) — macOS / Linux

The two scripts are functional twins; any behavioral change to one must be mirrored in the other in
the same commit. Each carries a banner comment to that effect.
