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
# Requires: Ubuntu, run as your own user with sudo; bash 4.4 or later; curl or
# wget; ssh. Installs git, curl and the GitHub CLI (gh) with apt when missing.
# As a setup tool, it uses sudo only for those installs, and backs up
# ~/.ssh/config (to ~/.config/otr/backup/) before it changes it.
#
# Environment:
#   OTR_PROJECTS_DIR       Base directory for repositories (default: ~/dev/projects)
#   OTR_BOOTSTRAP_DRY_RUN  true is the same as --dry-run (stage 1 reads it too)
#   NO_COLOR               Any value turns off colour
#
# Output: the plan goes to stdout; progress, prompts, warnings and errors go to
# stderr. Exit codes: 0 success (also --help, a dry run, and declining the
# confirmation), 1 a check or step failed, 2 usage error, 127 a required tool
# is missing, 130 interrupted. After the hand-over, stage 1's exit code.
#
# Only settings and function definitions come before the last line, main "$@",
# so a partially downloaded copy fails with a syntax error or does nothing,
# instead of running half the steps.

set -Eeuo pipefail
IFS=$'\n\t'

readonly ORG="OTR-Lanka"
readonly WORKSPACE_REPO="otr-workspace"
readonly PROJECTS_DIR="${OTR_PROJECTS_DIR:-$HOME/dev/projects}"
readonly BACKUP_DIR="$HOME/.config/otr/backup"
readonly API_TIMEOUT=60
readonly DOWNLOAD_TIMEOUT=120

DRY_RUN=false
[[ "${OTR_BOOTSTRAP_DRY_RUN:-false}" != true ]] || DRY_RUN=true
ASSUME_YES=false
PASSTHROUGH=()
USE_COLOUR_ERR=false

usage() {
  cat <<EOF
Usage: bootstrap.sh [options] [-- stage-1 options]

Stage 0 of the OTR-Lanka developer VM bootstrap. Installs git, curl and the
GitHub CLI, signs you in to GitHub, checks your ${ORG} membership, clones
${ORG}/${WORKSPACE_REPO} into ${PROJECTS_DIR} and runs its bootstrap.sh.

Options:
  -n, --dry-run   Print the plan without changing anything.
  -y, --yes       Do not ask for confirmation.
  -h, --help      Show this help.

Anything after "--" is passed to stage 1, for example:
  bash bootstrap.sh -- --profile backend

Environment:
  OTR_PROJECTS_DIR       Base directory for repositories (default: ~/dev/projects)
  OTR_BOOTSTRAP_DRY_RUN  true is the same as --dry-run
EOF
}

# --- Output helpers -------------------------------------------------------------
# Colour (messages on stderr only) on a terminal, and never when NO_COLOR is set.
init_colour() {
  if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then USE_COLOUR_ERR=true; fi
  return 0
}

# paint <true|false> <SGR code> <text>: the text, coloured when the flag is true.
paint() {
  if "$1"; then printf '\033[%sm%s\033[0m' "$2" "$3"; else printf '%s' "$3"; fi
}

# join_by <one-character separator> <items...>
join_by() {
  local IFS="$1"
  shift
  printf '%s' "$*"
}

info() { printf '%s %s\n' "$(paint "$USE_COLOUR_ERR" '1;34' '==>')" "$1" >&2; }
success() { printf '%s %s\n' "$(paint "$USE_COLOUR_ERR" '1;32' 'OK:')" "$1" >&2; }
warn() { printf '%s %s\n' "$(paint "$USE_COLOUR_ERR" '1;33' 'Warning:')" "$1" >&2; }
error() { printf '%s %s\n' "$(paint "$USE_COLOUR_ERR" '1;31' 'Error:')" "$1" >&2; }
# detail <message>: a continuation line under the previous message.
detail() { printf '    %s\n' "$1" >&2; }
fail() {
  error "$1"
  exit 1
}
# usage_error <message>: a bad option or argument; exits 2.
usage_error() {
  error "$1"
  exit 2
}
# missing_tool <message>: a required tool is not installed; exits 127.
missing_tool() {
  error "$1"
  exit 127
}
have() { command -v "$1" >/dev/null 2>&1; }

# note_dry <words...>: what a dry run would do.
note_dry() { printf '    [dry-run] %s\n' "$(join_by ' ' "$@")" >&2; }
run() { if "$DRY_RUN"; then note_dry "$@"; else "$@"; fi; }

# ask <variable> <prompt>: reads one answer into <variable>. When the input
# ends first, stops with an error instead of looping or failing through the
# error trap.
ask() {
  read -r -p "$2" "$1" || fail "No answer: the input ended at \"${2%: }\"."
}

# confirm <question>: yes at once with --yes; otherwise asks on the terminal.
# Fails when there is no terminal or the input ends; returns 1 unless the
# answer is yes.
confirm() {
  local answer=""
  if "$ASSUME_YES"; then
    printf '%s [y/N]: yes (--yes)\n' "$1" >&2
    return 0
  fi
  [[ -t 0 ]] || fail "No terminal available for confirmation; re-run with --yes."
  ask answer "$1 [y/N]: "
  [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}

# --- Safety ------------------------------------------------------------------------
setup_traps() {
  trap 'on_error "$LINENO"' ERR
  trap 'printf "\nInterrupted.\n" >&2; exit 130' INT TERM
}

on_error() {
  local exit_code=$?
  printf '\nError: bootstrap.sh failed near line %s.\n' "${1:-unknown}" >&2
  exit "$exit_code"
}

# backup_file <file> <name>: copies the file to BACKUP_DIR/<name>.<timestamp>,
# keeping its mode.
backup_file() {
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  cp -p -- "$1" "$BACKUP_DIR/$2.$(date +%Y%m%d%H%M%S)"
}

# reachable <url>: the URL answers, with curl or else wget.
reachable() {
  if have curl; then
    curl -fsS --max-time 10 -o /dev/null "$1" 2>/dev/null
  else
    wget -q --timeout=10 -O /dev/null "$1"
  fi
}

gh_api() { timeout "$API_TIMEOUT" gh api "$@"; }

# --- Arguments ------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n | --dry-run) DRY_RUN=true ;;
      -y | --yes) ASSUME_YES=true ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        PASSTHROUGH=("$@")
        break
        ;;
      *) usage_error "Unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

# --- Steps -----------------------------------------------------------------------------
check_machine() {
  info "Checking this machine"
  [[ "$(id -u)" -ne 0 ]] || fail "Run this as your own user, not root. It uses sudo where needed."
  [[ -r /etc/os-release ]] || fail "Cannot read /etc/os-release."
  local os_id os_name
  # shellcheck disable=SC1091 # a system file, not part of this repository
  os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  # shellcheck disable=SC1091 # a system file, not part of this repository
  os_name="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-}")"
  [[ "$os_id" == "ubuntu" ]] || fail "This bootstrap supports Ubuntu (found: ${os_name:-unknown})."
  success "$os_name"
  have sudo || missing_tool "sudo is required."
  have curl || have wget || missing_tool "curl or wget is required to continue."
  have ssh || missing_tool "ssh is required (Ubuntu package openssh-client)."
  reachable https://github.com ||
    fail "Cannot reach https://github.com. From outside the office network, connect the VPN first."
  success "github.com is reachable"
}

print_plan() {
  cat <<EOF

This will:
  1. install git, curl and the GitHub CLI (gh) with apt, if missing;
  2. sign you in to GitHub in your browser (one-time device code);
  3. check that you are a member of the ${ORG} organization;
  4. clone ${ORG}/${WORKSPACE_REPO} into ${PROJECTS_DIR}/${WORKSPACE_REPO};
  5. run ${PROJECTS_DIR}/${WORKSPACE_REPO}/bootstrap.sh $(join_by ' ' "${PASSTHROUGH[@]}")

EOF
}

install_packages() {
  info "Installing base packages"
  local -a missing=()
  have git || missing+=(git)
  have curl || missing+=(curl)
  dpkg -s ca-certificates >/dev/null 2>&1 || missing+=(ca-certificates)
  if [[ ${#missing[@]} -gt 0 ]]; then
    run sudo apt-get update -qq
    run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
  fi
  success "git and curl present"
}

install_gh() {
  if have gh; then
    success "GitHub CLI present ($(gh --version | sed -n 1p))"
    return 0
  fi
  info "Installing the GitHub CLI from GitHub's apt repository"
  local keyring=/etc/apt/keyrings/githubcli-archive-keyring.gpg
  run sudo mkdir -p -m 755 /etc/apt/keyrings
  if "$DRY_RUN"; then
    note_dry "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee $keyring"
    note_dry "add https://cli.github.com/packages to /etc/apt/sources.list.d/github-cli.list"
  else
    curl -fsSL --max-time "$DOWNLOAD_TIMEOUT" https://cli.github.com/packages/githubcli-archive-keyring.gpg |
      sudo tee "$keyring" >/dev/null
    sudo chmod go+r "$keyring"
    printf 'deb [arch=%s signed-by=%s] https://cli.github.com/packages stable main\n' \
      "$(dpkg --print-architecture)" "$keyring" |
      sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  fi
  run sudo apt-get update -qq
  run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh
  success "GitHub CLI installed"
}

sign_in() {
  info "Signing in to GitHub"
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    success "Already signed in as $(gh_api user --jq .login)"
    return 0
  fi
  detail "You will get a one-time code. Open the link on your laptop, enter the code and approve."
  detail "When asked, let gh generate and upload an SSH key."
  if "$DRY_RUN"; then
    note_dry gh auth login --hostname github.com --git-protocol ssh --web
    return 0
  fi
  [[ -t 0 ]] || fail "GitHub sign-in needs a terminal."
  gh auth login --hostname github.com --git-protocol ssh --web
}

check_membership() {
  info "Checking ${ORG} membership"
  if "$DRY_RUN"; then
    note_dry gh api "user/memberships/orgs/${ORG}"
    return 0
  fi
  local state
  state="$(gh_api "user/memberships/orgs/${ORG}" --jq .state 2>/dev/null || true)"
  case "$state" in
    active) success "You are an active member of ${ORG}" ;;
    pending) fail "Your ${ORG} invitation is pending. Accept it at https://github.com/${ORG}, then re-run." ;;
    *) fail "You are not a member of ${ORG}. Ask the engineering lead to add you to the organization and the developers team, then re-run." ;;
  esac
}

# ssh_authenticates <ssh options...>: GitHub accepts the SSH key.
ssh_authenticates() {
  local out
  out="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$@" 2>&1 || true)"
  [[ "$out" == *"successfully authenticated"* ]]
}

# check_ssh: SSH to GitHub works on port 22, or else through port 443 (then
# ~/.ssh/config routes github.com there, after a backup).
check_ssh() {
  info "Checking SSH access to GitHub"
  if "$DRY_RUN"; then
    note_dry "ssh -T git@github.com (fallback: ssh.github.com:443)"
    return 0
  fi
  if ssh_authenticates git@github.com; then
    success "SSH to github.com works"
    return 0
  fi
  ssh_authenticates -p 443 git@ssh.github.com ||
    fail "SSH to GitHub failed. Check that gh uploaded your SSH key (gh ssh-key list), then re-run."
  warn "Port 22 looks blocked; routing GitHub SSH through ssh.github.com:443"
  local ssh_config="$HOME/.ssh/config"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  if ! grep -qs "^Host github.com" "$ssh_config"; then
    if [[ -f "$ssh_config" ]]; then backup_file "$ssh_config" ssh-config; fi
    printf '\n# Added by OTR-Lanka dev-bootstrap: port 22 blocked\nHost github.com\n  Hostname ssh.github.com\n  Port 443\n  User git\n' >>"$ssh_config"
    chmod 600 "$ssh_config"
  fi
  success "SSH to GitHub works over port 443"
}

get_workspace() {
  local dest="${PROJECTS_DIR}/${WORKSPACE_REPO}"
  info "Getting ${ORG}/${WORKSPACE_REPO}"
  run mkdir -p "$PROJECTS_DIR"
  if [[ -d "$dest/.git" ]]; then
    GIT_TERMINAL_PROMPT=0 run git -C "$dest" pull --ff-only ||
      fail "Could not update ${dest} (git pull --ff-only). Fix that checkout, then re-run."
    success "Updated ${dest}"
  else
    GIT_TERMINAL_PROMPT=0 run gh repo clone "${ORG}/${WORKSPACE_REPO}" "$dest" ||
      fail "Could not clone ${ORG}/${WORKSPACE_REPO} into ${dest}."
    success "Cloned into ${dest}"
  fi
}

hand_over() {
  local dest="${PROJECTS_DIR}/${WORKSPACE_REPO}"
  local -a stage1_args=("${PASSTHROUGH[@]}")
  info "Starting the full bootstrap (stage 1)"
  if "$DRY_RUN"; then stage1_args+=(--dry-run); fi
  if "$ASSUME_YES"; then stage1_args+=(--yes); fi
  if "$DRY_RUN" && [[ ! -x "$dest/bootstrap.sh" ]]; then
    note_dry "$dest/bootstrap.sh" "${stage1_args[@]}"
    return 0
  fi
  exec "$dest/bootstrap.sh" "${stage1_args[@]}"
}

main() {
  init_colour
  setup_traps
  parse_args "$@"
  check_machine
  print_plan
  if "$DRY_RUN"; then info "Dry run: nothing will be changed."; fi
  if ! confirm "Continue?"; then
    printf 'No changes made.\n'
    exit 0
  fi
  if ! "$DRY_RUN"; then
    sudo -v || fail "sudo authentication failed."
  fi
  install_packages
  install_gh
  sign_in
  check_membership
  check_ssh
  get_workspace
  hand_over
}

main "$@"
