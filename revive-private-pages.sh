#!/usr/bin/env bash
#
# revive-private-pages — bring GitHub Pages sites of private repositories back online.
#
# When a GitHub Pro / GitHub Education plan lapses or gets renewed, Pages sites of
# private repositories can silently stop being served (HTTP 404), even though the
# Pages settings still say "built". This tool finds those sites and revives them.
#
# It tries the following fixes, from least to most invasive:
#   A) Re-trigger the Pages build / deployment
#   B) Push an empty commit to the Pages branch (via the API, no clone needed)
#   C) Disable Pages and re-enable it with the exact same configuration
#   D) Make the repository public for a few seconds, then private again
#      (only after explicit confirmation)
#
# https://github.com/Gr33ndev/revive-private-pages
# License: MIT
#
# Compatible with Bash 3.2+ (default macOS bash) and Linux.

set -uo pipefail

VERSION="1.0.0"

# --------------------------------------------------------------------------
# Defaults & CLI
# --------------------------------------------------------------------------
AFFILIATION="owner"
TEST_REPO=""
FROM=""
TIMEOUT=240     # seconds to wait for sites to come back after each fix
WAIT=5          # seconds a repo stays public in fix D
COOLDOWN=30     # seconds before retrying a fix that errored
CHECK_ONLY=0

usage() {
  cat <<EOF
revive-private-pages ${VERSION}
Bring GitHub Pages sites of private repositories back online.

Usage:
  revive-private-pages [options]

Options:
  --check            Only list offline Pages sites, change nothing
  --test OWNER/REPO  Repository to try the fixes on first
                     (default: first offline, non-archived, non-user-site repo)
  --from A|B|C|D     Skip testing and start directly with this fix
  --timeout SEC      Max. seconds to wait for sites after a fix   (default: ${TIMEOUT})
  --wait SEC         Seconds a repo stays public in fix D           (default: ${WAIT})
  --cooldown SEC     Seconds before retrying a fix that errored     (default: ${COOLDOWN})
  --all              Also include repos you access as collaborator / org member
  -h, --help         Show this help
  -v, --version      Show version

Fixes (least to most invasive):
  A  Re-trigger the Pages build or deployment workflow
  B  Push an empty commit to the Pages branch
  C  Disable Pages and re-enable it with the same configuration
  D  Make the repo public for a few seconds, then private again (asks first)

Requirements: gh (logged in, scopes "repo" and "workflow"), jq, curl
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while (( $# > 0 )); do
  case "$1" in
    --check)       CHECK_ONLY=1 ;;
    --test)        TEST_REPO="${2:-}"; [[ -n "$TEST_REPO" ]] || die "--test needs OWNER/REPO"; shift ;;
    --from)        FROM="${2:-}"; [[ -n "$FROM" ]] || die "--from needs A, B, C or D"; shift ;;
    --timeout)     TIMEOUT="${2:-}"; shift ;;
    --wait)        WAIT="${2:-}"; shift ;;
    --cooldown)    COOLDOWN="${2:-}"; shift ;;
    --all)         AFFILIATION="owner,collaborator,organization_member" ;;
    -h|--help)     usage; exit 0 ;;
    -v|--version)  echo "revive-private-pages ${VERSION}"; exit 0 ;;
    *)             usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

for n in "$TIMEOUT" "$WAIT" "$COOLDOWN"; do
  [[ "$n" =~ ^[0-9]+$ ]] || die "expected a number of seconds, got '$n'"
done

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; DIM=$'\e[2m'; BLD=$'\e[1m'; RST=$'\e[0m'
else
  RED=""; YEL=""; GRN=""; DIM=""; BLD=""; RST=""
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s    %s%s\n' "$DIM" "$*" "$RST"; }

# Ask a question on the terminal (works even when stdin is a pipe).
# The answer is stored in ANSWER. Without a terminal the answer is empty (= "no").
ANSWER=""
ask() {
  ANSWER=""
  if { exec 3<>/dev/tty; } 2>/dev/null; then
    printf '%s' "$1" >&3
    read -r ANSWER <&3 || ANSWER=""
    exec 3>&-
  else
    printf '%s(no terminal – treated as "no")\n' "$1"
  fi
}

# HTTP status of a URL, bypassing caches
http_code() {
  curl -s -o /dev/null -L -m 15 -w '%{http_code}' -H 'Cache-Control: no-cache' \
    "$1?nocache=${RANDOM}${RANDOM}" || echo "000"
}

# Run gh: stdout goes to GOUT, a short error message to LAST_ERR
GOUT=""; LAST_ERR=""
g() {
  local errf rc
  errf=$(mktemp)
  GOUT=$(gh "$@" 2>"$errf"); rc=$?
  if (( rc != 0 )); then
    LAST_ERR="$(tr '\n' ' ' <"$errf" | sed 's/  */ /g; s/ *$//' | cut -c1-220)"
    [[ -n "$LAST_ERR" ]] || LAST_ERR="gh exited with code $rc"
  fi
  rm -f "$errf"
  return "$rc"
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
for cmd in gh jq curl; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is not installed (see README for the installer)."
done
gh auth status >/dev/null 2>&1 || die "gh is not logged in. Run: gh auth login -s repo,workflow"

# ==========================================================================
# 1. Find offline Pages sites
# ==========================================================================
say "Loading private repositories …"
g api --paginate "/user/repos?visibility=private&affiliation=${AFFILIATION}&per_page=100" \
  --jq '.[] | select(.has_pages) | "\(.full_name)\t\(.archived)"' \
  || die "could not list repositories: ${LAST_ERR}"
REPO_LIST="$GOUT"

OFF_REPOS=(); OFF_URLS=(); OFF_ARCH=()
online_count=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  repo="${line%%$'\t'*}"; archived="${line##*$'\t'}"
  url=$(gh api "/repos/${repo}/pages" --jq '.html_url' 2>/dev/null) || continue
  code=$(http_code "$url")
  tag=""; [[ "$archived" == "true" ]] && tag=" ${DIM}[archived]${RST}"
  if [[ "$code" == "200" ]]; then
    printf '%s✔%s %s%s\n' "$GRN" "$RST" "$repo" "$tag"
    online_count=$((online_count + 1))
  else
    printf '%s✘%s %s (HTTP %s)%s\n' "$RED" "$RST" "$repo" "$code" "$tag"
    OFF_REPOS+=("$repo"); OFF_URLS+=("$url"); OFF_ARCH+=("$archived")
  fi
done <<<"$REPO_LIST"

say ""
say "${GRN}Online: ${online_count}${RST}   ${RED}Offline: ${#OFF_REPOS[@]}${RST}"
(( ${#OFF_REPOS[@]} == 0 )) && { say "${GRN}All Pages sites are online. Nothing to do.${RST}"; exit 0; }
if (( CHECK_ONLY == 1 )); then
  say ""; say "Run without --check to fix them."
  exit 2
fi

# --------------------------------------------------------------------------
# Archived repos are read-only: ask one by one whether the site is still needed.
# Selected ones are unarchived for the fix and re-archived on exit (also on Ctrl+C).
# --------------------------------------------------------------------------
TO_UNARCHIVE=()
n_archived=0
for a in "${OFF_ARCH[@]}"; do [[ "$a" == "true" ]] && n_archived=$((n_archived + 1)); done
if (( n_archived > 0 )); then
  say ""
  say "${BLD}${n_archived} offline site(s) belong to archived repositories.${RST}"
  say "Archived repos are read-only, so they will be unarchived for the fix and archived again afterwards."
  K_REPOS=(); K_URLS=(); K_ARCH=()
  for (( i=0; i<${#OFF_REPOS[@]}; i++ )); do
    if [[ "${OFF_ARCH[$i]}" == "true" ]]; then
      ask "  Do you still need the site of ${OFF_REPOS[$i]}? [y/N] "
      if [[ "$ANSWER" =~ ^[yY]$ ]]; then
        TO_UNARCHIVE+=("${OFF_REPOS[$i]}")
      else
        info "skipped"; continue
      fi
    fi
    K_REPOS+=("${OFF_REPOS[$i]}"); K_URLS+=("${OFF_URLS[$i]}"); K_ARCH+=("${OFF_ARCH[$i]}")
  done
  OFF_REPOS=(${K_REPOS[@]+"${K_REPOS[@]}"})
  OFF_URLS=(${K_URLS[@]+"${K_URLS[@]}"})
  OFF_ARCH=(${K_ARCH[@]+"${K_ARCH[@]}"})
fi

N=${#OFF_REPOS[@]}
say ""
(( N == 0 )) && { say "Nothing left to fix."; exit 0; }
say "${BLD}Fixing ${N} site(s).${RST}"

# ==========================================================================
# 2. The fixes — each returns 0 if it could be applied, otherwise sets LAST_ERR
# ==========================================================================

# --- A) Re-trigger build / deployment --------------------------------------
fix_rebuild() {
  local repo="$1" pages build_type run_id wf_id
  g api "/repos/${repo}/pages" || return 1; pages="$GOUT"
  build_type=$(jq -r '.build_type // "legacy"' <<<"$pages")

  if [[ "$build_type" == "legacy" ]]; then
    g api -X POST "/repos/${repo}/pages/builds" && { info "Pages build requested"; return 0; }
  fi

  # GitHub Actions deployment (or fallback): re-run the latest Pages/deploy run
  run_id=""
  g api "/repos/${repo}/actions/runs?per_page=30" --jq '
    [.workflow_runs[] | select(.event != "pull_request")
     | select((.name // "" | test("pages|deploy";"i")) or (.path // "" | test("pages|deploy";"i")))][0].id // empty' \
    && run_id="$GOUT"
  if [[ -n "$run_id" ]]; then
    g api -X POST "/repos/${repo}/actions/runs/${run_id}/rerun" && { info "re-ran workflow run ${run_id}"; return 0; }
    wf_id=""
    g api "/repos/${repo}/actions/runs/${run_id}" --jq '.workflow_id' && wf_id="$GOUT"
    if [[ -n "$wf_id" ]]; then
      g workflow run "$wf_id" -R "$repo" && { info "dispatched workflow ${wf_id}"; return 0; }
    fi
  fi
  return 1
}

# --- B) Empty commit via the Git Data API ------------------------------------
fix_empty_commit() {
  local repo="$1" pages branch sha tree new
  g api "/repos/${repo}/pages" || return 1; pages="$GOUT"
  branch=$(jq -r '.source.branch // empty' <<<"$pages")
  if [[ -z "$branch" ]]; then
    g api "/repos/${repo}" --jq '.default_branch' || return 1; branch="$GOUT"
  fi
  g api "/repos/${repo}/git/ref/heads/${branch}" --jq '.object.sha' || return 1; sha="$GOUT"
  g api "/repos/${repo}/git/commits/${sha}"      --jq '.tree.sha'   || return 1; tree="$GOUT"
  g api -X POST "/repos/${repo}/git/commits" \
      -f message="chore: redeploy GitHub Pages" -f tree="$tree" -f "parents[]=${sha}" \
      --jq '.sha' || return 1; new="$GOUT"
  g api -X PATCH "/repos/${repo}/git/refs/heads/${branch}" -f sha="$new" || return 1
  info "empty commit pushed to '${branch}'"
  if [[ "$(jq -r '.build_type // "legacy"' <<<"$pages")" == "legacy" ]]; then
    gh api -X POST "/repos/${repo}/pages/builds" >/dev/null 2>&1
  fi
  return 0
}

# --- C) Disable and re-enable Pages -------------------------------------------
PAGES_LOST=()
fix_toggle_pages() {
  local repo="$1" pages build_type branch path cname https i ok=0
  g api "/repos/${repo}/pages" || return 1; pages="$GOUT"
  build_type=$(jq -r '.build_type // "legacy"' <<<"$pages")
  branch=$(jq -r '.source.branch // empty' <<<"$pages")
  path=$(jq -r '.source.path // "/"' <<<"$pages")
  cname=$(jq -r '.cname // empty' <<<"$pages")
  https=$(jq -r '.https_enforced // false' <<<"$pages")

  g api -X DELETE "/repos/${repo}/pages" || { LAST_ERR="disabling Pages failed: ${LAST_ERR}"; return 1; }
  sleep 5
  for i in 1 2 3 4 5 6; do
    if [[ "$build_type" == "workflow" ]]; then
      g api -X POST "/repos/${repo}/pages" -f build_type=workflow && { ok=1; break; }
    else
      g api -X POST "/repos/${repo}/pages" -f build_type=legacy \
        -f "source[branch]=${branch}" -f "source[path]=${path}" && { ok=1; break; }
    fi
    sleep 5
  done
  if (( ok == 0 )) && ! gh api "/repos/${repo}/pages" >/dev/null 2>&1; then
    LAST_ERR="re-enabling Pages failed (${LAST_ERR})"
    PAGES_LOST+=("${repo}  (source: ${build_type}, branch ${branch:-–}, path ${path})")
    return 1
  fi
  [[ -n "$cname" ]]         && gh api -X PUT "/repos/${repo}/pages" -f cname="$cname" >/dev/null 2>&1
  [[ "$https" == "true" ]]  && gh api -X PUT "/repos/${repo}/pages" -F https_enforced=true >/dev/null 2>&1
  [[ "$build_type" == "workflow" ]] && fix_rebuild "$repo" >/dev/null 2>&1
  info "Pages re-enabled (${build_type}, ${branch:-–}${path}${cname:+, $cname})"
  return 0
}

# --- D) Public for a few seconds, then private again ---------------------------
set_visibility()     { g repo edit "$1" --visibility "$2" --accept-visibility-change-consequences; }
current_visibility() { gh api "/repos/$1" --jq '.visibility' 2>/dev/null || echo "unknown"; }
make_private_again() {
  local repo="$1" i
  for i in 1 2 3 4 5 6; do
    set_visibility "$repo" private && [[ "$(current_visibility "$repo")" == "private" ]] && return 0
    sleep 2
  done
  return 1
}

CURRENT_PUBLIC=""; STILL_PUBLIC=()
fix_visibility() {
  local repo="$1"
  CURRENT_PUBLIC="$repo"
  set_visibility "$repo" public || { CURRENT_PUBLIC=""; return 1; }
  sleep "$WAIT"
  if make_private_again "$repo"; then
    CURRENT_PUBLIC=""; info "was public for ~${WAIT}s, private again ✔"; return 0
  fi
  CURRENT_PUBLIC=""; STILL_PUBLIC+=("$repo")
  LAST_ERR="could NOT be made private again!"
  return 1
}

confirm_visibility() {  # "$@" = repos
  local r
  say ""
  say "${BLD}${YEL}Fix D makes these repositories PUBLIC for ~${WAIT}s each:${RST}"
  for r in "$@"; do say "  - $r"; done
  say "During that window the code and the full git history are public."
  say "Bots scan new public repos for secrets within seconds – rotate any secret that was ever committed."
  say "Switching back to private removes all stars and watchers."
  ask "Continue? Type 'yes': "
  [[ "$ANSWER" == "yes" ]]
}

# --------------------------------------------------------------------------
# Cleanup on exit (also on Ctrl+C): restore visibility first, then re-archive
# --------------------------------------------------------------------------
UNARCHIVED=()
rearchive_all() {
  local r
  (( ${#UNARCHIVED[@]} > 0 )) || return 0
  say ""; say "Archiving ${#UNARCHIVED[@]} repo(s) again …"
  for r in "${UNARCHIVED[@]}"; do
    if gh repo archive "$r" --yes >/dev/null 2>&1; then
      say "  ${GRN}✔${RST} $r archived"
    else
      say "  ${RED}✘ $r could not be archived → run: gh repo archive $r --yes${RST}"
    fi
  done
  UNARCHIVED=()
}
on_exit() {
  if [[ -n "$CURRENT_PUBLIC" ]]; then
    say ""; say "${YEL}Interrupted – making ${CURRENT_PUBLIC} private again …${RST}"
    if make_private_again "$CURRENT_PUBLIC"; then
      say "${GRN}${CURRENT_PUBLIC} is private again.${RST}"
    else
      say "${RED}WARNING: ${CURRENT_PUBLIC} may still be PUBLIC! Check it now.${RST}"
    fi
    CURRENT_PUBLIC=""
  fi
  rearchive_all
}
trap on_exit EXIT
trap 'exit 130' INT TERM

STRATS=(fix_rebuild fix_empty_commit fix_toggle_pages fix_visibility)
NAMES=("A) re-trigger build" "B) empty commit" "C) disable/enable Pages" "D) public → private")
LETTERS=(A B C D)

# ==========================================================================
# One round: apply fix $1 to the indices in ROUND_IN.
# Errors are retried once after COOLDOWN; then we only wait for the repos where
# the fix was actually applied. Results: ROUND_OK (online), ROUND_OUT (not fixed).
# ==========================================================================
ROUND_IN=(); ROUND_OK=(); ROUND_OUT=()
LAST_ERRS=(); for (( i=0; i<N; i++ )); do LAST_ERRS+=(""); done

apply_fix() {  # $1 = fix index, $2 = repo index, $3 = label suffix
  say "  ${OFF_REPOS[$2]}${3:-}"
  if "${STRATS[$1]}" "${OFF_REPOS[$2]}"; then return 0; fi
  say "${RED}    ✘ ${LAST_ERR}${RST}"
  LAST_ERRS[$2]="$LAST_ERR"
  return 1
}

run_round() {
  local s="$1" i waited=0
  local applied=() failed=() still=() pending=() next=()

  for i in ${ROUND_IN[@]+"${ROUND_IN[@]}"}; do
    if apply_fix "$s" "$i"; then applied+=("$i"); else failed+=("$i"); fi
  done

  if (( ${#failed[@]} > 0 )); then
    say "  ${DIM}${#failed[@]} failed – retrying in ${COOLDOWN}s …${RST}"
    sleep "$COOLDOWN"
    for i in "${failed[@]}"; do
      if apply_fix "$s" "$i" " (retry)"; then applied+=("$i"); else still+=("$i"); fi
    done
    failed=(${still[@]+"${still[@]}"})
  fi

  ROUND_OK=()
  pending=(${applied[@]+"${applied[@]}"})
  if (( ${#pending[@]} > 0 )); then
    printf '  Waiting up to %ss for %d site(s) ' "$TIMEOUT" "${#pending[@]}"
    while (( ${#pending[@]} > 0 )); do
      next=()
      for i in "${pending[@]}"; do
        if [[ "$(http_code "${OFF_URLS[$i]}")" == "200" ]]; then ROUND_OK+=("$i"); else next+=("$i"); fi
      done
      pending=(${next[@]+"${next[@]}"})
      (( ${#pending[@]} == 0 || waited >= TIMEOUT )) && break
      printf '.'; sleep 10; waited=$((waited + 10))
    done
    printf '\n'
    for i in ${ROUND_OK[@]+"${ROUND_OK[@]}"}; do say "  ${GRN}✔ ${OFF_REPOS[$i]} is online${RST}"; done
    for i in ${pending[@]+"${pending[@]}"}; do
      say "  ${YEL}✘ ${OFF_REPOS[$i]} still offline after ${TIMEOUT}s${RST}"
      LAST_ERRS[i]="still offline after ${NAMES[$s]}"
    done
  fi
  ROUND_OUT=(${failed[@]+"${failed[@]}"} ${pending[@]+"${pending[@]}"})
}

# ==========================================================================
# Unarchive the archived repos the user selected (re-archived on exit)
# ==========================================================================
if (( ${#TO_UNARCHIVE[@]} > 0 )); then
  say "Unarchiving ${#TO_UNARCHIVE[@]} repo(s) …"
  for r in "${TO_UNARCHIVE[@]}"; do
    if g repo unarchive "$r" --yes; then
      UNARCHIVED+=("$r"); say "  ${GRN}✔${RST} $r"
    else
      say "  ${RED}✘ $r: ${LAST_ERR}${RST}"
    fi
  done
fi

# ==========================================================================
# 3. Find the first working fix on a test repo (or use --from)
# ==========================================================================
DONE=(); START=-1; TEST_IDX=-1; TEST_FAILED=0

if [[ -n "$FROM" ]]; then
  FROM_UC=$(tr '[:lower:]' '[:upper:]' <<<"$FROM")
  for (( s=0; s<4; s++ )); do [[ "${LETTERS[$s]}" == "$FROM_UC" ]] && START=$s; done
  (( START >= 0 )) || die "--from must be A, B, C or D"
  say ""; say "Skipping the test, starting with fix ${NAMES[$START]}."
else
  if [[ -n "$TEST_REPO" ]]; then
    for (( i=0; i<N; i++ )); do [[ "${OFF_REPOS[$i]}" == "$TEST_REPO" ]] && TEST_IDX=$i; done
    (( TEST_IDX >= 0 )) || die "${TEST_REPO} is not in the list of offline sites."
  else
    # Prefer a repo that is neither archived nor the user/org site (*.github.io)
    for (( i=0; i<N; i++ )); do
      [[ "${OFF_REPOS[$i]}" != *.github.io && "${OFF_ARCH[$i]}" != "true" ]] && { TEST_IDX=$i; break; }
    done
    if (( TEST_IDX < 0 )); then
      for (( i=0; i<N; i++ )); do [[ "${OFF_REPOS[$i]}" != *.github.io ]] && { TEST_IDX=$i; break; }; done
    fi
    (( TEST_IDX >= 0 )) || TEST_IDX=0
  fi
  say ""; say "Test repository: ${BLD}${OFF_REPOS[$TEST_IDX]}${RST}"

  for (( s=0; s<4; s++ )); do
    say ""; say "${BLD}── Testing ${NAMES[$s]}${RST}"
    if [[ "${STRATS[$s]}" == "fix_visibility" ]]; then
      if ! confirm_visibility "${OFF_REPOS[$TEST_IDX]}"; then
        say "  Fix D declined for the test repository."
        LAST_ERRS[TEST_IDX]="A–C did not help, D declined"
        break
      fi
    fi
    ROUND_IN=("$TEST_IDX"); run_round "$s"
    if (( ${#ROUND_OK[@]} > 0 )); then
      say "${GRN}  → ${NAMES[$s]} works.${RST}"
      START=$s; DONE+=("$TEST_IDX"); break
    fi
  done

  if (( START < 0 )); then
    TEST_FAILED=1
    say ""; say "${YEL}No fix helped the test repository – trying all fixes on the others anyway.${RST}"
    START=0
  fi
fi

# ==========================================================================
# 4. All others: working fix first, then every other fix, D always last.
#    Each repo goes through the list until it is online or all fixes were tried.
# ==========================================================================
REMAINING=()
for (( i=0; i<N; i++ )); do (( i == TEST_IDX )) || REMAINING+=("$i"); done

ORDER=("$START")
for (( s=0; s<3; s++ )); do (( s == START )) || ORDER+=("$s"); done
(( START == 3 )) || ORDER+=(3)

for (( o=0; o<${#ORDER[@]} && ${#REMAINING[@]} > 0; o++ )); do
  s=${ORDER[$o]}
  say ""
  say "${BLD}══ ${NAMES[$s]} for ${#REMAINING[@]} repo(s)${RST}"
  if [[ "${STRATS[$s]}" == "fix_visibility" ]]; then
    names=(); for i in "${REMAINING[@]}"; do names+=("${OFF_REPOS[$i]}"); done
    if ! confirm_visibility "${names[@]}"; then
      say "Fix D declined."
      for i in "${REMAINING[@]}"; do LAST_ERRS[i]="${LAST_ERRS[$i]:+${LAST_ERRS[$i]}; }D declined"; done
      break
    fi
  fi
  ROUND_IN=("${REMAINING[@]}"); run_round "$s"
  DONE+=(${ROUND_OK[@]+"${ROUND_OK[@]}"})
  REMAINING=(${ROUND_OUT[@]+"${ROUND_OUT[@]}"})
  if (( ${#REMAINING[@]} > 0 && o < ${#ORDER[@]} - 1 )); then
    say "  ${DIM}→ ${#REMAINING[@]} repo(s) move on to the next fix${RST}"
  fi
done
(( TEST_FAILED == 1 )) && REMAINING+=("$TEST_IDX")

# ==========================================================================
# 5. Summary
# ==========================================================================
say ""
say "================ Summary ================"
printf '%sBack online: %d/%d%s\n' "$GRN" "${#DONE[@]}" "$N" "$RST"
printf '%sStill offline: %d%s\n' "$YEL" "${#REMAINING[@]}" "$RST"
for i in ${REMAINING[@]+"${REMAINING[@]}"}; do
  say "  - ${OFF_REPOS[$i]}  ${DIM}(${LAST_ERRS[$i]:-unknown})${RST}"
done
if (( ${#PAGES_LOST[@]} > 0 )); then
  say "${BLD}${RED}Pages were disabled and could NOT be re-enabled – turn them on under Settings → Pages:${RST}"
  for r in "${PAGES_LOST[@]}"; do say "  - $r"; done
fi
if (( ${#STILL_PUBLIC[@]} > 0 )); then
  say "${BLD}${RED}WARNING – still PUBLIC:${RST}"
  for r in "${STILL_PUBLIC[@]}"; do
    say "  - $r  →  gh repo edit $r --visibility private --accept-visibility-change-consequences"
  done
  exit 1
fi
(( ${#REMAINING[@]} == 0 )) && exit 0
exit 2
