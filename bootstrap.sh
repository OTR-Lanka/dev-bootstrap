#!/usr/bin/env bash
#
# OTR-Lanka developer VM bootstrap, stage 0.
#
# This script is public on purpose. It holds no tokens, hostnames or repository
# lists. It installs the GitHub CLI, signs you in to GitHub, checks your
# OTR-Lanka membership, clones the private OTR-Lanka/otr-workspace repository
# and hands over to the full bootstrap there (stage 1).
#
# The Developer Guide (OTR-Lanka/docs, onboarding/developer-guide.md) documents
# the exact command, pinned to a release tag, and the SHA-256 checksum to verify.
#
# The whole body sits in main(), called on the last line, so a partially
# downloaded copy fails with a syntax error instead of running half the steps.

main() {
  set -euo pipefail

  local org="OTR-Lanka"
  local workspace_repo="otr-workspace"
  local projects_dir="${OTR_PROJECTS_DIR:-$HOME/dev/projects}"
  local dry_run=false
  local assume_yes=false
  local -a passthrough=()

  usage() {
    cat <<EOF
Usage: bootstrap.sh [options] [-- stage-1 options]

Stage 0 of the OTR-Lanka developer VM bootstrap. Installs git, curl and the
GitHub CLI, signs you in to GitHub, checks your ${org} membership, clones
${org}/${workspace_repo} into ${projects_dir} and runs its bootstrap.sh.

Options:
  -n, --dry-run   Print the plan without changing anything.
  -y, --yes       Do not ask for confirmation.
  -h, --help      Show this help.

Anything after "--" is passed to stage 1, for example:
  bash bootstrap.sh -- --profile backend

Environment:
  OTR_PROJECTS_DIR   Base directory for repositories (default: ~/dev/projects)
EOF
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run) dry_run=true ;;
      -y|--yes) assume_yes=true ;;
      -h|--help) usage; return 0 ;;
      --) shift; passthrough=("$@"); break ;;
      *) echo "Unknown option: $1 (try --help)" >&2; return 2 ;;
    esac
    shift
  done

  say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
  ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
  warn() { printf '\033[1;33m !!\033[0m %s\n' "$*" >&2; }
  die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
  run()  {
    if "$dry_run"; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi
  }
  have() { command -v "$1" >/dev/null 2>&1; }
  # True only when a terminal can actually be opened (not just when /dev/tty exists).
  has_tty() { { : </dev/tty; } 2>/dev/null; }

  # Prompts read from the terminal, so they work under "curl ... | bash" too.
  confirm() {
    "$assume_yes" && return 0
    has_tty || die "No terminal available for confirmation; re-run with --yes."
    local answer=""
    read -r -p "$1 [y/N]: " answer </dev/tty
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
  }

  # --- Preflight --------------------------------------------------------------
  say "Checking this machine"
  [[ "$(id -u)" -ne 0 ]] || die "Run this as your own user, not root. It uses sudo where needed."
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This bootstrap supports Ubuntu (found: ${PRETTY_NAME:-unknown})."
  ok "${PRETTY_NAME}"
  have sudo || die "sudo is required."
  have curl || have wget || die "curl or wget is required to continue."
  if ! curl -fsS --max-time 10 -o /dev/null https://github.com 2>/dev/null; then
    die "Cannot reach https://github.com. From outside the office network, connect the VPN first."
  fi
  ok "github.com is reachable"

  cat <<EOF

This will:
  1. install git, curl and the GitHub CLI (gh) with apt, if missing;
  2. sign you in to GitHub in your browser (one-time device code);
  3. check that you are a member of the ${org} organization;
  4. clone ${org}/${workspace_repo} into ${projects_dir}/${workspace_repo};
  5. run ${projects_dir}/${workspace_repo}/bootstrap.sh ${passthrough[*]:-}

EOF
  "$dry_run" && say "Dry run: nothing will be changed."
  confirm "Continue?" || { echo "Cancelled."; return 1; }

  if ! "$dry_run"; then
    sudo -v || die "sudo authentication failed."
  fi

  # --- Packages and GitHub CLI -----------------------------------------------
  say "Installing base packages"
  local -a missing=()
  have git || missing+=(git)
  have curl || missing+=(curl)
  dpkg -s ca-certificates >/dev/null 2>&1 || missing+=(ca-certificates)
  if [[ ${#missing[@]} -gt 0 ]]; then
    run sudo apt-get update -qq
    run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
  fi
  ok "git and curl present"

  if have gh; then
    ok "GitHub CLI present ($(gh --version | head -1))"
  else
    say "Installing the GitHub CLI from GitHub's apt repository"
    local keyring=/etc/apt/keyrings/githubcli-archive-keyring.gpg
    run sudo mkdir -p -m 755 /etc/apt/keyrings
    if "$dry_run"; then
      printf '    [dry-run] %s\n' "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee $keyring"
      printf '    [dry-run] %s\n' "add https://cli.github.com/packages to /etc/apt/sources.list.d/github-cli.list"
    else
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee "$keyring" >/dev/null
      sudo chmod go+r "$keyring"
      echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    fi
    run sudo apt-get update -qq
    run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh
    ok "GitHub CLI installed"
  fi

  # --- GitHub sign-in ---------------------------------------------------------
  say "Signing in to GitHub"
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    ok "Already signed in as $(gh api user --jq .login)"
  else
    echo "    You will get a one-time code. Open the link on your laptop, enter the code and approve."
    echo "    When asked, let gh generate and upload an SSH key."
    if "$dry_run"; then
      printf '    [dry-run] %s\n' "gh auth login --hostname github.com --git-protocol ssh --web"
    else
      has_tty || die "GitHub sign-in needs a terminal."
      gh auth login --hostname github.com --git-protocol ssh --web </dev/tty
    fi
  fi

  # --- Organization membership -------------------------------------------------
  say "Checking ${org} membership"
  if "$dry_run"; then
    printf '    [dry-run] %s\n' "gh api user/memberships/orgs/${org}"
  else
    local state=""
    state="$(gh api "user/memberships/orgs/${org}" --jq .state 2>/dev/null || true)"
    case "$state" in
      active) ok "You are an active member of ${org}" ;;
      pending) die "Your ${org} invitation is pending. Accept it at https://github.com/${org}, then re-run." ;;
      *) die "You are not a member of ${org}. Ask the engineering lead to add you to the organization and the developers team, then re-run." ;;
    esac
  fi

  # --- SSH reachability (port 22, else 443) ------------------------------------
  say "Checking SSH access to GitHub"
  if "$dry_run"; then
    printf '    [dry-run] %s\n' "ssh -T git@github.com (fallback: ssh.github.com:443)"
  else
    local ssh_out=""
    ssh_out="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)"
    if [[ "$ssh_out" == *"successfully authenticated"* ]]; then
      ok "SSH to github.com works"
    else
      ssh_out="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p 443 git@ssh.github.com 2>&1 || true)"
      if [[ "$ssh_out" == *"successfully authenticated"* ]]; then
        warn "Port 22 looks blocked; routing GitHub SSH through ssh.github.com:443"
        mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
        if ! grep -qs "^Host github.com" "$HOME/.ssh/config"; then
          printf '\n# Added by OTR-Lanka dev-bootstrap: port 22 blocked\nHost github.com\n  Hostname ssh.github.com\n  Port 443\n  User git\n' >>"$HOME/.ssh/config"
          chmod 600 "$HOME/.ssh/config"
        fi
        ok "SSH to GitHub works over port 443"
      else
        die "SSH to GitHub failed. Check that gh uploaded your SSH key (gh ssh-key list), then re-run."
      fi
    fi
  fi

  # --- Clone the workspace repository -------------------------------------------
  local dest="${projects_dir}/${workspace_repo}"
  say "Getting ${org}/${workspace_repo}"
  run mkdir -p "$projects_dir"
  if [[ -d "$dest/.git" ]]; then
    run git -C "$dest" pull --ff-only
    ok "Updated ${dest}"
  else
    run gh repo clone "${org}/${workspace_repo}" "$dest"
    ok "Cloned into ${dest}"
  fi

  # --- Hand over to stage 1 -----------------------------------------------------
  say "Starting the full bootstrap (stage 1)"
  local -a stage1_args=("${passthrough[@]}")
  "$dry_run" && stage1_args+=(--dry-run)
  "$assume_yes" && stage1_args+=(--yes)
  if "$dry_run" && [[ ! -x "$dest/bootstrap.sh" ]]; then
    printf '    [dry-run] %s\n' "$dest/bootstrap.sh ${stage1_args[*]:-}"
    return 0
  fi
  exec "$dest/bootstrap.sh" "${stage1_args[@]}"
}

main "$@"
