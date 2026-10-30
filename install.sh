#!/usr/bin/env bash
#
# Installer for revive-private-pages
#
#   curl -fsSL https://raw.githubusercontent.com/Gr33ndev/revive-private-pages/main/install.sh | bash
#
# What it does (asks before every step that changes something):
#   1. Checks for gh, jq and curl and offers to install missing ones
#   2. Checks that gh is logged in with the scopes "repo" and "workflow"
#   3. Installs `revive-private-pages` to ~/.local/bin (override with INSTALL_DIR)
#   4. Offers to check your repositories right away and to fix them
#
# Everything is wrapped in main() so the whole file is downloaded before anything runs.

set -euo pipefail

REPO="${REVIVE_REPO:-Gr33ndev/revive-private-pages}"
BRANCH="${REVIVE_BRANCH:-main}"
TOOL="revive-private-pages"
SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${TOOL}.sh"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
REQUIRED_SCOPES="repo workflow"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; DIM=$'\e[2m'; BLD=$'\e[1m'; RST=$'\e[0m'
else
  RED=""; YEL=""; GRN=""; DIM=""; BLD=""; RST=""
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✔%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s!%s %s\n' "$YEL" "$RST" "$*"; }
fail() { printf '%s✘ %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }
step() { printf '\n%s%s%s\n' "$BLD" "$*" "$RST"; }

# Prompts read from the terminal, because stdin is the piped script.
HAS_TTY=0
if { exec 3<>/dev/tty; } 2>/dev/null; then HAS_TTY=1; fi

# ask_yn "Question" default(y|n) → returns 0 for yes
ask_yn() {
  local q="$1" def="$2" hint ans=""
  [[ "$def" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
  if (( HAS_TTY == 0 )); then
    say "$q $hint (no terminal – using default: $def)"
    [[ "$def" == "y" ]]; return
  fi
  printf '%s %s ' "$q" "$hint" >&3
  read -r ans <&3 || ans=""
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[yY]([eE][sS])?$ ]]
}

# Runs a command with the terminal as stdin (so interactive tools work under curl | bash)
run_tty() {
  if (( HAS_TTY == 1 )); then "$@" <&3; else "$@" </dev/null; fi
}

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then run_tty sudo "$@"
  else fail "Need root privileges to run: $* (sudo not found)"; fi
}

# --------------------------------------------------------------------------
# 1. Dependencies
# --------------------------------------------------------------------------
detect_pkg_manager() {
  if command -v brew >/dev/null 2>&1; then echo brew
  elif command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v pacman >/dev/null 2>&1; then echo pacman
  elif command -v zypper >/dev/null 2>&1; then echo zypper
  elif command -v apk >/dev/null 2>&1; then echo apk
  else echo none; fi
}

pkg_name() {  # $1 = manager, $2 = tool
  if [[ "$2" == "gh" ]]; then
    case "$1" in pacman|apk) echo github-cli ;; *) echo gh ;; esac
  else
    echo "$2"
  fi
}

install_packages() {  # $1 = manager, rest = tools
  local pm="$1"; shift
  local pkgs=() t
  for t in "$@"; do pkgs+=("$(pkg_name "$pm" "$t")"); done
  case "$pm" in
    brew)   run_tty brew install "${pkgs[@]}" ;;
    apt)    as_root apt-get update && as_root apt-get install -y "${pkgs[@]}" ;;
    dnf)    as_root dnf install -y "${pkgs[@]}" ;;
    pacman) as_root pacman -S --needed --noconfirm "${pkgs[@]}" ;;
    zypper) as_root zypper --non-interactive install "${pkgs[@]}" ;;
    apk)    as_root apk add "${pkgs[@]}" ;;
    *)      return 1 ;;
  esac
}

check_dependencies() {
  step "1/4  Checking dependencies"
  local missing=() t pm
  for t in curl gh jq; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"; else warn "$t is missing"; missing+=("$t"); fi
  done
  (( ${#missing[@]} == 0 )) && return 0

  pm=$(detect_pkg_manager)
  if [[ "$pm" == "none" ]]; then
    say ""
    say "No supported package manager found. Please install manually: ${missing[*]}"
    say "  gh:  https://github.com/cli/cli#installation"
    say "  jq:  https://jqlang.org/download/"
    [[ "$(uname -s)" == "Darwin" ]] && say "  Tip: install Homebrew first: https://brew.sh"
    exit 1
  fi

  ask_yn "Install ${missing[*]} with ${pm}?" y || fail "Cannot continue without: ${missing[*]}"
  if ! install_packages "$pm" "${missing[@]}"; then
    say ""
    warn "Installation via ${pm} failed."
    [[ " ${missing[*]} " == *" gh "* ]] && say "  Install gh manually: https://github.com/cli/cli#installation"
    exit 1
  fi
  hash -r 2>/dev/null || true
  for t in "${missing[@]}"; do
    command -v "$t" >/dev/null 2>&1 || fail "$t is still not available after installation."
    ok "$t installed"
  done
}

# --------------------------------------------------------------------------
# 2. GitHub CLI login & scopes
# --------------------------------------------------------------------------
missing_scopes() {
  # Classic OAuth tokens (what `gh auth login` creates) report their scopes in a header.
  local header s out=""
  header=$(gh api -i /user 2>/dev/null | tr -d '\r' | grep -i '^x-oauth-scopes:' || true)
  [[ -z "$header" ]] && { echo "?"; return; }   # e.g. fine-grained token – cannot check
  for s in $REQUIRED_SCOPES; do
    [[ "$header" =~ (:|,|[[:space:]])${s}(,|[[:space:]]|$) ]] || out="${out} ${s}"
  done
  echo "${out# }"
}

check_auth() {
  step "2/4  Checking GitHub login"
  if ! gh auth status >/dev/null 2>&1; then
    warn "gh is not logged in."
    ask_yn "Log in now (opens the GitHub login flow)?" y || fail "Please run: gh auth login -s repo,workflow"
    run_tty gh auth login -s repo,workflow || fail "Login failed."
  fi
  local user; user=$(gh api /user --jq .login 2>/dev/null || echo "?")
  ok "Logged in as ${user}"

  local missing; missing=$(missing_scopes)
  if [[ "$missing" == "?" ]]; then
    warn "Could not read token scopes (fine-grained token?). Make sure it can manage Pages,"
    warn "contents, Actions and repository settings of your private repos."
  elif [[ -n "$missing" ]]; then
    warn "Token is missing scope(s): ${missing}"
    ask_yn "Add them now (gh auth refresh)?" y || fail "Please run: gh auth refresh -s repo,workflow"
    run_tty gh auth refresh -h github.com -s repo,workflow || fail "Refreshing the token failed."
    ok "Scopes added"
  else
    ok "Token has scopes: ${REQUIRED_SCOPES}"
  fi
}

# --------------------------------------------------------------------------
# 3. Install the tool
# --------------------------------------------------------------------------
install_tool() {
  step "3/4  Installing ${TOOL}"
  local tmp src_dir target="${INSTALL_DIR}/${TOOL}"
  tmp=$(mktemp)

  # Running from a local clone? Use the file next to this installer.
  src_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    src_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  fi
  if [[ -n "$src_dir" && -f "${src_dir}/${TOOL}.sh" ]]; then
    cp "${src_dir}/${TOOL}.sh" "$tmp"
    say "${DIM}Using local copy: ${src_dir}/${TOOL}.sh${RST}"
  else
    curl -fsSL "$SCRIPT_URL" -o "$tmp" || fail "Download failed: ${SCRIPT_URL}"
  fi

  head -n1 "$tmp" | grep -q '^#!.*bash' || fail "Downloaded file does not look like a bash script."
  bash -n "$tmp" || fail "Downloaded script has syntax errors."

  mkdir -p "$INSTALL_DIR"
  mv "$tmp" "$target"
  chmod 755 "$target"
  ok "Installed to ${target}"

  case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) TOOL_CMD="$TOOL" ;;
    *)
      TOOL_CMD="$target"
      warn "${INSTALL_DIR} is not in your PATH. Add it with:"
      local rc="\$HOME/.bashrc"; [[ "${SHELL:-}" == *zsh ]] && rc="\$HOME/.zshrc"
      say "    echo 'export PATH=\"${INSTALL_DIR}:\$PATH\"' >> ${rc}"
      ;;
  esac
}

# --------------------------------------------------------------------------
# 4. Offer to run it
# --------------------------------------------------------------------------
offer_run() {
  step "4/4  Ready"
  say "Run it any time with: ${BLD}${TOOL_CMD}${RST}   (see ${TOOL_CMD} --help)"
  (( HAS_TTY == 1 )) || return 0

  say ""
  ask_yn "Check your private repositories now? (read-only, changes nothing)" y || return 0
  say ""
  local rc=0
  run_tty "${INSTALL_DIR}/${TOOL}" --check || rc=$?
  if (( rc == 2 )); then
    say ""
    if ask_yn "Fix the offline sites now? (you will be asked again before anything risky)" n; then
      say ""
      run_tty "${INSTALL_DIR}/${TOOL}" || true
    else
      say "Okay. Run ${BLD}${TOOL_CMD}${RST} whenever you are ready."
    fi
  fi
}

main() {
  say "${BLD}revive-private-pages installer${RST}"
  check_dependencies
  check_auth
  install_tool
  offer_run
  say ""
  ok "Done."
}

main "$@"
