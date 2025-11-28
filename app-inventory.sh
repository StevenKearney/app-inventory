#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2317
# Enhanced application inventory for Linux systems
# Lists packages from: distro repos, AUR, Flatpak, Snap, AppImages, local binaries, and global pip packages
#
# Author: Steven Kearney
# GitHub: https://github.com/StevenKearney/app-inventory
# License: MIT
# Version: 0.6.10

set -euo pipefail

VERSION="0.6.10"
GITHUB_URL="https://github.com/StevenKearney/app-inventory"

# Sane PATH for security
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# ---------- Configuration ----------
OUTFILE=""
OUTPUT_FORMAT="tsv"
DIFF_FILE=""
SEARCH_TERM=""
SOURCES_ARG=""
MANAGERS_ARG=""
NO_COLOR=0
VERBOSE=0
QUIET=0
RUN_BINARIES=0
SHOW_ONLY_ORPHANS=0
SHOW_BANNER=1
MENU_CONFIRMED=0
INCLUDE_ALL_PACKAGES="${APP_INVENTORY_INCLUDE_ALL:-0}"
NON_INTERACTIVE="${APP_INVENTORY_NONINTERACTIVE:-0}"
[[ "$INCLUDE_ALL_PACKAGES" != "0" ]] && INCLUDE_ALL_PACKAGES=1 || INCLUDE_ALL_PACKAGES=0
[[ "$NON_INTERACTIVE" != "0" ]] && NON_INTERACTIVE=1 || NON_INTERACTIVE=0
SCAN_START_TIME=$(date +%s)
SCAN_DURATION=0
readonly DETAIL_MAX_DISPLAY=60
readonly NAME_MAX_DISPLAY=50

# Default color vars so set -u does not explode before setup_colors runs
RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; BOLD=''; DIM=''; RESET=''

# ---------- Colors ----------
setup_colors() {
  if [[ -t 1 && "$NO_COLOR" -eq 0 ]]; then
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
    BLUE=$'\e[34m'; MAGENTA=$'\e[35m'; CYAN=$'\e[36m'
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
  else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; BOLD=''; DIM=''; RESET=''
  fi
}

init_color_helpers() {
  TYPE_COLOR_MAP["Repo"]="$GREEN"
  TYPE_COLOR_MAP["AUR/Foreign"]="$YELLOW"
  TYPE_COLOR_MAP["Foreign"]="$YELLOW"
  TYPE_COLOR_MAP["Flatpak"]="$BLUE"
  TYPE_COLOR_MAP["Snap"]="$MAGENTA"
  TYPE_COLOR_MAP["AppImage"]="$CYAN"
  TYPE_COLOR_MAP["Local Binary"]="$MAGENTA"
  TYPE_COLOR_MAP["Python Package"]="$YELLOW"
  TYPE_COLOR_MAP["Container Image"]="$BLUE"
  TYPE_COLOR_MAP["Container"]="$BLUE"
  TYPE_COLOR_MAP["Ollama Model"]="$MAGENTA"
  TYPE_COLOR_MAP["Nix Package"]="$GREEN"
  TYPE_COLOR_MAP["Rust Binary"]="$YELLOW"
  TYPE_COLOR_MAP["Node Package"]="$YELLOW"
  TYPE_COLOR_MAP["Homebrew Package"]="$CYAN"
  TYPE_COLOR_MAP["Go Binary"]="$GREEN"
  TYPE_COLOR_MAP["Pipx Package"]="$YELLOW"
  TYPE_COLOR_MAP["User Service"]="$BLUE"
  ORPHAN_SUMMARY_COLOR="${BOLD}${YELLOW}"
  ORPHAN_COLOR="$ORPHAN_SUMMARY_COLOR"
  TOTAL_COLOR="${BOLD}${CYAN}"
}

declare -A TYPE_COLOR_MAP=()
ORPHAN_COLOR=""
TOTAL_COLOR=""
ORPHAN_SUMMARY_COLOR=""

log_info() {
  if [[ "$QUIET" -eq 0 ]]; then
    echo "${CYAN}[INFO]${RESET} $*" >&2
  fi
  return 0
}
log_verbose() {
  if [[ "$VERBOSE" -eq 1 && "$QUIET" -eq 0 ]]; then
    echo "${DIM}[VERBOSE]${RESET} $*" >&2
  fi
  return 0
}
log_warn() { echo "${YELLOW}[WARN]${RESET} $*" >&2; return 0; }
log_error() { echo "${RED}[ERROR]${RESET} $*" >&2; }
log_success() {
  if [[ "$QUIET" -eq 0 ]]; then
    echo "${GREEN}[SUCCESS]${RESET} $*" >&2
  fi
  return 0
}

# Strip control chars except tab/newline
safe_print() {
  printf '%s\n' "$1" | tr -d '\000-\010\013\014\016-\037\177'
}

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

draw_ascii_banner() {
cat <<'BANNER'

                         _                      _
  __ _ _ __  _ __       (_)_ ____   _____ _ __ | |_ ___  _ __ _   _
 / _` | '_ \| '_ \ _____| | '_ \ \ / / _ \ '_ \| __/ _ \| '__| | | |
| (_| | |_) | |_) |_____| | | | \ V /  __/ | | | || (_) | |  | |_| |
 \__,_| .__/| .__/      |_|_| |_|\_/ \___|_| |_|\__\___/|_|   \__, |
      |_|   |_|                                               |___/
                 a p p   -   i n v e n t o r y
BANNER
  printf '                         version %s\n\n' "$VERSION"
}

draw_menu_header() {
  (( SHOW_BANNER )) || return 0
  cat <<'BANNER'
                         _                      _
  __ _ _ __  _ __       (_)_ ____   _____ _ __ | |_ ___  _ __ _   _
 / _` | '_ \| '_ \ _____| | '_ \ \ / / _ \ '_ \| __/ _ \| '__| | | |
| (_| | |_) | |_) |_____| | | | \ V /  __/ | | | || (_) | |  | |_| |
 \__,_| .__/| .__/      |_|_| |_|\_/ \___|_| |_|\__\___/|_|   \__, |
      |_|   |_|                                               |___/
                 a p p   -   i n v e n t o r y
BANNER
  printf '                         version %s\n\n' "$VERSION"
}

# ---------- Command cache ----------
declare -A COMMAND_CACHE=()
declare -A TYPE_COUNTS=()

# ---------- Spinner ----------
SPINNER_FRAMES=("-" "\\" "|" "/")

_spinner_loop() {
  local message="$1"
  local i=0
  while true; do
    printf '\r%s %s...' "${SPINNER_FRAMES[$i]}" "$message" >&2
    i=$(( (i + 1) % ${#SPINNER_FRAMES[@]} ))
    sleep 0.1
  done
}

run_with_spinner() {
  local message="$1"
  shift
  if [[ ! -t 2 || "$QUIET" -eq 1 || "$NON_INTERACTIVE" -eq 1 ]]; then
    log_verbose "$message..."
    "${@}"
    return $?
  fi
  _spinner_loop "$message" &
  local spinner_pid=$!
  "${@}"
  local status=$?
  if kill -0 "$spinner_pid" 2>/dev/null; then
    kill "$spinner_pid" >/dev/null 2>&1 || true
  fi
  wait "$spinner_pid" 2>/dev/null || true
  local symbol="[X]"
  (( status == 0 )) && symbol="[OK]"
  printf '\r%s %s\n' "$symbol" "$message" >&2
  return $status
}

run_step() {
  local message="$1"
  shift
  run_with_spinner "$message" "$@"
  if [[ -t 1 && "$QUIET" -eq 0 && "$NON_INTERACTIVE" -eq 0 ]]; then
    sleep 1
  fi
}

command_exists() {
  local cmd="$1"
  if [[ -v "COMMAND_CACHE[$cmd]" ]]; then
    return "${COMMAND_CACHE[$cmd]}"
  fi
  if command -v "$cmd" >/dev/null 2>&1; then
    COMMAND_CACHE["$cmd"]=0; return 0
  fi
  COMMAND_CACHE["$cmd"]=1; return 1
}

show_pre_scan_loading() {
  [[ -t 1 && "$QUIET" -eq 0 && "$NON_INTERACTIVE" -eq 0 ]] || return 0
  printf '\n%sCompiling selections...%s\n' "$DIM" "$RESET"
  sleep 2
}

# ---------- Helpers ----------
format_size() {
  local bytes="$1"
  if [[ -z "$bytes" || "$bytes" == "0" ]]; then
    echo "-"
    return
  fi

  if command_exists numfmt; then
    local formatted
    if formatted=$(numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null); then
      formatted="${formatted// /}"
      echo "$formatted"
    else
      echo "${bytes}B"
    fi
  else
    echo "${bytes}B"
  fi
}

extract_version_number() {
  local input="$1"
  if [[ "$input" =~ ([0-9]+([.][0-9]+)+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$input" =~ ([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf ''
  fi
}

truncate_field() {
  local text="$1"
  local max_len="${2:-60}"
  local clean="$text"
  local length=${#clean}
  if (( length <= max_len )); then
    printf '%s' "$clean"
  else
    local cutoff=$(( max_len > 3 ? max_len - 3 : 0 ))
    printf '%s...' "${clean:0:cutoff}"
  fi
}

format_duration() {
  local seconds="$1"
  (( seconds < 0 )) && seconds=0
  local hours=$(( seconds / 3600 ))
  local minutes=$(( (seconds % 3600) / 60 ))
  local secs=$(( seconds % 60 ))
  local parts=()
  (( hours > 0 )) && parts+=("${hours}h")
  (( minutes > 0 )) && parts+=("${minutes}m")
  parts+=("${secs}s")
  printf '%s' "${parts[*]}"
}

extract_version() {
  local file="$1"
  local version=""
  local output flag base

  if (( RUN_BINARIES )) && [[ -x "$file" ]]; then
    for flag in --version -V -v version; do
      if command_exists timeout; then
        output=$(timeout 1s "$file" "$flag" 2>/dev/null | head -n1) || true
      else
        output=$("$file" "$flag" 2>/dev/null | head -n1) || true
      fi
      if [[ "$output" =~ ([0-9]+[._-][0-9]+([._-][0-9]+)*) ]]; then
        version="${BASH_REMATCH[1]}"
        break
      fi
    done
  fi

  if [[ -z "$version" && "$file" =~ \.AppImage$ ]]; then
    base="$(basename "$file" .AppImage)"
    if [[ "$base" =~ ([0-9]+(\.[0-9]+)*) ]]; then
      version="${BASH_REMATCH[1]}"
    fi
  fi

  if [[ -z "$version" ]]; then
    printf '%s\n' "-"
  else
    printf '%s\n' "$version"
  fi
}

# ---------- Usage ----------
show_usage() {
cat << EOF
app-inventory ${VERSION}

USAGE:
  app-inventory [OPTIONS]

OUTPUT:
  (default) TSV table shown in console (no file)
  --json               JSON (saved to ~/installed-apps.json unless --outfile)
  --csv                CSV  (saved to ~/installed-apps.csv unless --outfile)
  --outfile PATH       Custom output path

FILTERING:
  --search TERM        Filter by name (case-insensitive, e.g. --search discord)
  --sources LIST       repo,aur,flatpak,snap,appimage,local,pip,docker,podman,ollama,llms,nix,cargo,npm,brew,go,pipx,systemd
  --managers LIST      pacman,apt,dnf,yum,zypper or "all"
  --orphans-only       show only packages marked as orphaned (pacman only)

DIFF:
  --diff old.tsv

OTHER:
  --show-managers
  --run-binaries       allow executing detected binaries for version info (unsafe; may run arbitrary/GUI code)
  --all-packages       include runtimes/dependencies (currently pacman + Flatpak only)
  --apps-only          reverse of --all-packages (default)
  --non-interactive    disable menus and prompts (or set APP_INVENTORY_NONINTERACTIVE=1)
  --verbose, -v
  --quiet
  --no-color
  --no-banner
  --help, -h
  --version, -V

PERFORMANCE NOTES:
  Scanning all sources can be slow on large systems (especially with AUR and local binaries).

  Examples:
    Fast (repos + popular app stores):
      app-inventory --sources repo,aur,flatpak,snap

    Faster (repos + stores, skip local binaries):
      app-inventory --sources repo,aur,flatpak,snap,pip

    Fastest (distro repos only):
      app-inventory --sources repo

REQUIREMENTS:
  - bash 4.3+ (for associative arrays/namerefs)
  - python3 (for --json and --csv output)
EOF
}

show_version() {
  echo "app-inventory version $VERSION"
  echo "GitHub: $GITHUB_URL"
}

show_usage_with_pager() {
  if command_exists less; then
    show_usage | less -R
  elif [[ -n "${PAGER:-}" ]]; then
    show_usage | "${PAGER}"
  else
    show_usage
  fi
}

show_usage_modal() {
  echo
  show_usage
  echo
  if [[ -t 0 ]]; then
    local resp
    read -rp "Return to menu? [Y/n]: " resp
    resp="${resp:-Y}"
    resp="${resp^^}"
    if [[ "$resp" == "N" ]]; then
      exit 0
    fi
  fi
}

# ---------- Arg parsing ----------
SHOW_MANAGERS=0
CLI_ARGS_PROVIDED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) CLI_ARGS_PROVIDED=1; OUTPUT_FORMAT="json"; shift ;;
    --csv) CLI_ARGS_PROVIDED=1; OUTPUT_FORMAT="csv"; shift ;;
    --diff)
      CLI_ARGS_PROVIDED=1
      if [[ $# -lt 2 || "$2" == -* ]]; then
        log_error "--diff requires a value"
        exit 1
      fi
      DIFF_FILE="$2"; shift 2 ;;
    --outfile)
      CLI_ARGS_PROVIDED=1
      if [[ $# -lt 2 || "$2" == -* ]]; then
        log_error "--outfile requires a value"
        exit 1
      fi
      OUTFILE="$2"; shift 2 ;;
    --search)
      CLI_ARGS_PROVIDED=1
      if [[ $# -lt 2 || "$2" == -* ]]; then
        log_error "--search requires a value"
        exit 1
      fi
      SEARCH_TERM="$2"; shift 2 ;;
    --sources)
      CLI_ARGS_PROVIDED=1
      if [[ $# -lt 2 || "$2" == -* ]]; then
        log_error "--sources requires a comma-separated list"
        exit 1
      fi
      SOURCES_ARG="$2"; shift 2 ;;
    --managers)
      CLI_ARGS_PROVIDED=1
      if [[ $# -lt 2 || "$2" == -* ]]; then
        log_error "--managers requires a value (e.g. pacman,apt or all)"
        exit 1
      fi
      MANAGERS_ARG="$2"; shift 2 ;;
    --run-binaries) CLI_ARGS_PROVIDED=1; RUN_BINARIES=1; shift ;;
    --all-packages) CLI_ARGS_PROVIDED=1; INCLUDE_ALL_PACKAGES=1; shift ;;
    --apps-only) CLI_ARGS_PROVIDED=1; INCLUDE_ALL_PACKAGES=0; shift ;;
    --non-interactive) CLI_ARGS_PROVIDED=1; NON_INTERACTIVE=1; shift ;;
    --no-color) CLI_ARGS_PROVIDED=1; NO_COLOR=1; shift ;;
    --no-banner) CLI_ARGS_PROVIDED=1; SHOW_BANNER=0; shift ;;
    --verbose|-v) CLI_ARGS_PROVIDED=1; VERBOSE=1; shift ;;
    --quiet) CLI_ARGS_PROVIDED=1; QUIET=1; shift ;;
    --show-managers) CLI_ARGS_PROVIDED=1; SHOW_MANAGERS=1; shift ;;
    --orphans-only) CLI_ARGS_PROVIDED=1; SHOW_ONLY_ORPHANS=1; shift ;;
    --version|-V) show_version; exit 0 ;;
    --help|-h) show_usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$OUTPUT_FORMAT" == "json" || "$OUTPUT_FORMAT" == "csv" ]]; then
  if ! command_exists python3; then
    log_error "python3 is required for $OUTPUT_FORMAT output"
    exit 1
  fi
fi

setup_colors
init_color_helpers

# ---------- Validate diff file ----------
if [[ -n "${DIFF_FILE:-}" && ! -f "$DIFF_FILE" ]]; then
  log_error "Diff file not found: $DIFF_FILE"
  exit 1
fi

# ---------- Fix OUTFILE extension ----------
if [[ -n "$OUTFILE" ]]; then
  case "$OUTFILE" in
    *.tsv|*.csv|*.json) OUTFILE_BASE="${OUTFILE%.*}" ;;
    *) OUTFILE_BASE="$OUTFILE" ;;
  esac
  case "$OUTPUT_FORMAT" in
    json) OUTFILE="${OUTFILE_BASE}.json" ;;
    csv) OUTFILE="${OUTFILE_BASE}.csv" ;;
  esac
fi

TMPFILE="$(mktemp "${TMPDIR:-/tmp}/app-inventory.XXXXXX")"
TSV_FILE="$(mktemp "${TMPDIR:-/tmp}/app-inventory-tsv.XXXXXX")"
trap 'rm -f "$TMPFILE" "$TSV_FILE"' EXIT

# ---------- Source configuration ----------
INCLUDE_REPO=1
INCLUDE_AUR=1
INCLUDE_FLATPAK=1
INCLUDE_SNAP=1
INCLUDE_APPIMAGE=1
INCLUDE_LOCAL=0
INCLUDE_PIP=0
INCLUDE_DOCKER=1
INCLUDE_PODMAN=1
INCLUDE_OLLAMA=1
INCLUDE_NIX=1
INCLUDE_CARGO=1
INCLUDE_NPM=1
INCLUDE_BREW=1
INCLUDE_GO=1
INCLUDE_PIPX=1
INCLUDE_SYSTEMD_USER=1
DEFAULT_OUTPUT_BASENAME="$HOME/installed-apps"

NAME_FILTER="$SEARCH_TERM"

declare -A SOURCE_PRESETS=(
  [1]="repo"
  [2]="repo flatpak appimage"
  [3]="repo aur flatpak appimage local docker podman"
  [4]="repo aur flatpak snap appimage local pip docker podman ollama nix cargo npm brew go pipx systemd"
  [5]="flatpak snap appimage local pip docker podman ollama nix cargo npm brew go pipx systemd"
)

declare -A SOURCE_PRESET_LABELS=(
  [1]="Minimal (Repo only)"
  [2]="Desktop Store (Repo + Flatpak + AppImage)"
  [3]="Arch Desktop + Containers (Repo + AUR + Flatpak + AppImage + Local + Docker/Podman)"
  [4]="Full Scan (Repo + AUR + stores + Dev + Containers + Pip)"
  [5]="Everything Except Repo (stores + Dev + Containers)"
)

FOREIGN_TYPE_LABEL="Foreign"

refresh_source_presets() {
  local have_pacman=0
  if command_exists pacman; then
    have_pacman=1
    FOREIGN_TYPE_LABEL="AUR/Foreign"
  else
    FOREIGN_TYPE_LABEL="Foreign"
  fi

  SOURCE_PRESETS[1]="repo"
  SOURCE_PRESET_LABELS[1]="Minimal (Repo only)"

  local have_flatpak=0 have_snap=0 have_docker=0 have_podman=0 have_ollama=0
  local have_nix=0 have_cargo=0 have_npm=0 have_brew=0 have_go=0 have_pipx=0 have_systemd=0
  command_exists flatpak && have_flatpak=1
  command_exists snap && have_snap=1
  command_exists docker && have_docker=1
  command_exists podman && have_podman=1
  command_exists ollama && have_ollama=1
  command_exists nix-env && have_nix=1
  command_exists cargo && have_cargo=1
  command_exists npm && have_npm=1
  command_exists brew && have_brew=1
  command_exists go && have_go=1
  command_exists pipx && have_pipx=1
  command_exists systemctl && have_systemd=1

  local preset2_sources="repo"
  (( have_pacman )) && preset2_sources+=" aur"
  (( have_flatpak )) && preset2_sources+=" flatpak"
  preset2_sources+=" appimage"
  SOURCE_PRESETS[2]="$preset2_sources"
  if (( have_pacman )); then
    SOURCE_PRESET_LABELS[2]="Desktop Store (Repo + AUR + Flatpak + AppImage)"
  else
    SOURCE_PRESET_LABELS[2]="Desktop Store (Repo + Flatpak + AppImage)"
  fi

  local preset3_sources="repo"
  (( have_pacman )) && preset3_sources+=" aur"
  preset3_sources+=" flatpak appimage local"
  (( have_docker )) && preset3_sources+=" docker"
  (( have_podman )) && preset3_sources+=" podman"
  SOURCE_PRESETS[3]="$preset3_sources"
  if (( have_pacman )); then
    SOURCE_PRESET_LABELS[3]="Arch Desktop + Containers"
  else
    SOURCE_PRESET_LABELS[3]="Workstation + Containers"
  fi

  local preset4_sources="repo"
  (( have_pacman )) && preset4_sources+=" aur"
  (( have_flatpak )) && preset4_sources+=" flatpak"
  (( have_snap )) && preset4_sources+=" snap"
  preset4_sources+=" appimage local pip"
  (( have_docker )) && preset4_sources+=" docker"
  (( have_podman )) && preset4_sources+=" podman"
  (( have_ollama )) && preset4_sources+=" ollama"
  (( have_nix )) && preset4_sources+=" nix"
  (( have_cargo )) && preset4_sources+=" cargo"
  (( have_npm )) && preset4_sources+=" npm"
  (( have_brew )) && preset4_sources+=" brew"
  (( have_go )) && preset4_sources+=" go"
  (( have_pipx )) && preset4_sources+=" pipx"
  (( have_systemd )) && preset4_sources+=" systemd"
  SOURCE_PRESETS[4]="$preset4_sources"
  SOURCE_PRESET_LABELS[4]="Full Scan (Repo + stores + Dev + Containers + Services)"

  local preset5_sources=""
  (( have_flatpak )) && preset5_sources+=" flatpak"
  (( have_snap )) && preset5_sources+=" snap"
  preset5_sources+=" appimage local pip"
  (( have_docker )) && preset5_sources+=" docker"
  (( have_podman )) && preset5_sources+=" podman"
  (( have_ollama )) && preset5_sources+=" ollama"
  (( have_nix )) && preset5_sources+=" nix"
  (( have_cargo )) && preset5_sources+=" cargo"
  (( have_npm )) && preset5_sources+=" npm"
  (( have_brew )) && preset5_sources+=" brew"
  (( have_go )) && preset5_sources+=" go"
  (( have_pipx )) && preset5_sources+=" pipx"
  (( have_systemd )) && preset5_sources+=" systemd"
  SOURCE_PRESETS[5]="$preset5_sources"
  SOURCE_PRESET_LABELS[5]="Everything Except Repo (stores + Dev + Containers)"
}

configure_sources() {
  if [[ -n "$SOURCES_ARG" ]]; then
    INCLUDE_REPO=0
    INCLUDE_AUR=0
    INCLUDE_FLATPAK=0
    INCLUDE_SNAP=0
    INCLUDE_APPIMAGE=0
    INCLUDE_LOCAL=0
    INCLUDE_PIP=0
    INCLUDE_DOCKER=0
    INCLUDE_PODMAN=0
    INCLUDE_OLLAMA=0
    INCLUDE_NIX=0
    INCLUDE_CARGO=0
    INCLUDE_NPM=0
    INCLUDE_BREW=0
    INCLUDE_GO=0
    INCLUDE_PIPX=0
    INCLUDE_SYSTEMD_USER=0

    local IFS=','
    local -a S=()
    read -ra S <<< "${SOURCES_ARG,,}"
    for s in "${S[@]}"; do
      s="$(trim_whitespace "$s")"
      [[ -z "$s" ]] && continue
      case "$s" in
        repo) INCLUDE_REPO=1 ;;
        aur) INCLUDE_AUR=1 ;;
        flatpak) INCLUDE_FLATPAK=1 ;;
        snap) INCLUDE_SNAP=1 ;;
        appimage) INCLUDE_APPIMAGE=1 ;;
        local) INCLUDE_LOCAL=1 ;;
        pip) INCLUDE_PIP=1 ;;
        docker) INCLUDE_DOCKER=1 ;;
        podman) INCLUDE_PODMAN=1 ;;
        ollama|llms) INCLUDE_OLLAMA=1 ;;
        nix) INCLUDE_NIX=1 ;;
        cargo) INCLUDE_CARGO=1 ;;
        npm) INCLUDE_NPM=1 ;;
        brew|homebrew|linuxbrew) INCLUDE_BREW=1 ;;
        go) INCLUDE_GO=1 ;;
        pipx) INCLUDE_PIPX=1 ;;
        systemd) INCLUDE_SYSTEMD_USER=1 ;;
        *) log_warn "Unknown source: $s" ;;
      esac
    done
  fi
}

configure_sources

log_verbose "Sources set: repo=$INCLUDE_REPO aur=$INCLUDE_AUR flatpak=$INCLUDE_FLATPAK snap=$INCLUDE_SNAP appimage=$INCLUDE_APPIMAGE local=$INCLUDE_LOCAL pip=$INCLUDE_PIP docker=$INCLUDE_DOCKER podman=$INCLUDE_PODMAN ollama=$INCLUDE_OLLAMA nix=$INCLUDE_NIX cargo=$INCLUDE_CARGO npm=$INCLUDE_NPM brew=$INCLUDE_BREW go=$INCLUDE_GO pipx=$INCLUDE_PIPX systemd=$INCLUDE_SYSTEMD_USER"

refresh_source_presets

if [[ -n "$OUTFILE" ]]; then
  :
elif [[ "$OUTPUT_FORMAT" == "csv" ]]; then
  OUTFILE="${DEFAULT_OUTPUT_BASENAME}.csv"
elif [[ "$OUTPUT_FORMAT" == "json" ]]; then
  OUTFILE="${DEFAULT_OUTPUT_BASENAME}.json"
else
  OUTFILE=""
fi

if [[ -n "$OUTFILE" ]]; then
  mkdir -p "$(dirname "$OUTFILE")"
fi

maybe_run_interactive_menu() {
  [[ ! -t 0 || "$NON_INTERACTIVE" -eq 1 ]] && return
  [[ "$CLI_ARGS_PROVIDED" -eq 1 ]] && return
  [[ -n "$MANAGERS_ARG" || -n "$SEARCH_TERM" || -n "$SOURCES_ARG" || "$SHOW_MANAGERS" -eq 1 ]] && return
  run_interactive_menu
}

ensure_orphan_sources_available() {
  (( SHOW_ONLY_ORPHANS )) || return 0
  if ! command_exists pacman; then
    log_error "--orphans-only requires pacman to be installed"
    exit 1
  fi
  if (( ! INCLUDE_REPO && ! INCLUDE_AUR )); then
    log_error "--orphans-only requires pacman repo or AUR sources"
    exit 1
  fi
}

format_checkbox_row() {
  local prefix="${1:-}"
  local mark="$2"
  local label="$3"
  local value="${4:-}"
  local note="${5:-}"
  [[ -z "$prefix" ]] && prefix=" "
  printf '  %-4s[%s] %-24s %-24s %s\n' "$prefix" "$mark" "$label" "$value" "$note"
}

run_interactive_menu() {
  MENU_CONFIRMED=0
  detect_all_pkg_managers
  refresh_source_presets

  INCLUDE_REPO=0
  INCLUDE_AUR=0
  INCLUDE_FLATPAK=0
  INCLUDE_SNAP=0
  INCLUDE_APPIMAGE=0
  INCLUDE_LOCAL=0
  INCLUDE_PIP=0

  local include_repo=0
  local include_aur=0
  local include_flatpak=0
  local include_snap=0
  local include_appimage=0
  local include_local=0
  local include_pip=0
  local include_docker=0
  local include_podman=0
  local include_ollama=0
  local include_nix=0
  local include_cargo=0
  local include_npm=0
  local include_brew=0
  local include_go=0
  local include_pipx=0
  local include_systemd=0

  local repo_available=0 aur_available=0 mgr
  (( ${#PKG_MGR_IDS[@]} > 0 )) && repo_available=1
  for mgr in "${PKG_MGR_IDS[@]}"; do
    if [[ "$mgr" == "pacman" ]]; then
      aur_available=1
      break
    fi
  done

  local repo_version_label=""
  local aur_version_label=""
  for idx in "${!PKG_MGR_IDS[@]}"; do
    local label="${PKG_MGR_LABELS[$idx]}"
    local ver="${PKG_MGR_VERSIONS[$idx]}"
    local combo="$label"
    [[ -n "$ver" && "$ver" != "unknown" ]] && combo+=" $ver"
    repo_version_label+="$combo, "
    if [[ "${PKG_MGR_IDS[$idx]}" == "pacman" ]]; then
      aur_version_label="$combo"
    fi
  done
  repo_version_label="${repo_version_label%, }"

  local flatpak_ok=0 snap_ok=0 pip_ok=0 docker_ok=0 podman_ok=0 ollama_ok=0 nix_ok=0 cargo_ok=0 npm_ok=0 brew_ok=0 go_ok=0 pipx_ok=0 systemd_ok=0
  local flatpak_version="" snap_version="" pip_version="" docker_version="" podman_version="" ollama_version="" nix_version="" cargo_version="" npm_version="" brew_version="" go_version="" pipx_version="" systemd_version=""
  if command_exists flatpak; then
    flatpak_ok=1
    flatpak_version="$(flatpak --version 2>/dev/null | sed -n '1p' | tr -d '\r')"
  fi
  if command_exists snap; then
    snap_ok=1
    snap_version="$(snap version 2>/dev/null | sed -n '1p' | tr -d '\r')"
  fi
  if command_exists docker; then
    docker_ok=1
    docker_version="$(docker --version 2>/dev/null | head -n1 | tr -d '\r')"
  fi
  if command_exists podman; then
    podman_ok=1
    podman_version="$(podman --version 2>/dev/null | head -n1 | tr -d '\r')"
  fi
  if command_exists ollama; then
    ollama_ok=1
    ollama_version="$(ollama --version 2>/dev/null | head -n1 | tr -d '\r')"
  fi
  if command_exists nix-env; then
    nix_ok=1
    nix_version="$(nix-env --version 2>/dev/null | head -n1 | tr -d '\r')"
  fi
  if command_exists cargo; then
    cargo_ok=1
    cargo_version="$(cargo --version 2>/dev/null | head -n1 | tr -d '\r')"
  fi
  if command_exists npm; then
    npm_ok=1
    npm_version="$(npm --version 2>/dev/null | head -n1 | tr -d '\r')"
  fi
  if command_exists brew; then
    brew_ok=1
    brew_version="$(brew --version 2>/dev/null | head -n1 | tr -d '\r')"
  fi
  if command_exists go; then
    go_ok=1
    go_version="$(go version 2>/dev/null | head -n1 | tr -d '\r')"
  fi
  if command_exists pipx; then
    pipx_ok=1
    pipx_version="$(pipx --version 2>/dev/null | head -n1 | tr -d '\r')"
  fi
  if command_exists systemctl; then
    systemd_ok=1
    systemd_version="$(systemctl --version 2>/dev/null | head -n1 | tr -d '\r')"
  fi
  local pip_cmd=""
  if pip_cmd=$(command -v pip3 2>/dev/null); then
    :
  elif pip_cmd=$(command -v pip 2>/dev/null); then
    :
  else
    pip_cmd=""
  fi
  if [[ -n "$pip_cmd" ]]; then
    pip_ok=1
    pip_version="$("$pip_cmd" --version 2>/dev/null | sed -n '1p' | tr -d '\r')"
  fi

  (( repo_available )) || include_repo=0
  (( aur_available )) || include_aur=0
  (( flatpak_ok )) || include_flatpak=0
  (( snap_ok )) || include_snap=0
  (( pip_ok )) || include_pip=0
  (( docker_ok )) || include_docker=0
  (( podman_ok )) || include_podman=0
  (( ollama_ok )) || include_ollama=0
  (( nix_ok )) || include_nix=0
  (( cargo_ok )) || include_cargo=0
  (( npm_ok )) || include_npm=0
  (( brew_ok )) || include_brew=0
  (( go_ok )) || include_go=0
  (( pipx_ok )) || include_pipx=0
  (( systemd_ok )) || include_systemd=0

  local -a option_targets=()
  local -a option_labels=()
  local -a option_notes=()
  local -a missing_sources=()
  local -a missing_notes=()

  if (( repo_available )); then
    option_targets+=("repo")
    option_labels+=("Repo")
    option_notes+=("")
  else
    missing_sources+=("Repo")
    missing_notes+=("no supported package managers detected")
  fi
  if (( aur_available )); then
    option_targets+=("aur")
    option_labels+=("AUR")
    option_notes+=("")
  else
    missing_sources+=("AUR")
    missing_notes+=("requires pacman")
  fi
  if (( flatpak_ok )); then
    option_targets+=("flatpak")
    option_labels+=("Flatpak")
    option_notes+=("")
  else
    missing_sources+=("Flatpak")
    missing_notes+=("flatpak command missing")
  fi
  if (( snap_ok )); then
    option_targets+=("snap")
    option_labels+=("Snap")
    option_notes+=("")
  else
    missing_sources+=("Snap")
    missing_notes+=("snap command missing")
  fi
  option_targets+=("appimage")
  option_labels+=("AppImage")
  option_notes+=("")
  option_targets+=("local")
  option_labels+=("Local binaries")
  option_notes+=("")
  if (( pip_ok )); then
    option_targets+=("pip")
    option_labels+=("Pip")
    option_notes+=("")
  else
    missing_sources+=("Pip")
    missing_notes+=("pip command missing")
  fi
  if (( docker_ok )); then
    option_targets+=("docker")
    option_labels+=("Docker")
    option_notes+=("")
  else
    missing_sources+=("Docker")
    missing_notes+=("docker command missing")
  fi
  if (( podman_ok )); then
    option_targets+=("podman")
    option_labels+=("Podman")
    option_notes+=("")
  else
    missing_sources+=("Podman")
    missing_notes+=("podman command missing")
  fi
  if (( ollama_ok )); then
    option_targets+=("ollama")
    option_labels+=("Ollama models")
    option_notes+=("")
  else
    missing_sources+=("Ollama")
    missing_notes+=("ollama command missing")
  fi
  if (( nix_ok )); then
    option_targets+=("nix")
    option_labels+=("Nix")
    option_notes+=("")
  else
    missing_sources+=("Nix")
    missing_notes+=("nix-env command missing")
  fi
  if (( cargo_ok )); then
    option_targets+=("cargo")
    option_labels+=("Cargo")
    option_notes+=("")
  else
    missing_sources+=("Cargo")
    missing_notes+=("cargo command missing")
  fi
  if (( npm_ok )); then
    option_targets+=("npm")
    option_labels+=("npm (global)")
    option_notes+=("")
  else
    missing_sources+=("npm")
    missing_notes+=("npm command missing")
  fi
  if (( brew_ok )); then
    option_targets+=("brew")
    option_labels+=("Homebrew/Linuxbrew")
    option_notes+=("")
  else
    missing_sources+=("Homebrew/Linuxbrew")
    missing_notes+=("brew command missing")
  fi
  if (( go_ok )); then
    option_targets+=("go")
    option_labels+=("Go binaries")
    option_notes+=("")
  else
    missing_sources+=("Go binaries")
    missing_notes+=("go command missing")
  fi
  if (( pipx_ok )); then
    option_targets+=("pipx")
    option_labels+=("pipx apps")
    option_notes+=("")
  else
    missing_sources+=("pipx")
    missing_notes+=("pipx command missing")
  fi
  if (( systemd_ok )); then
    option_targets+=("systemd")
    option_labels+=("systemd user services")
    option_notes+=("")
  else
    missing_sources+=("systemd user services")
    missing_notes+=("systemctl command missing")
  fi

  declare -A INSTALLED_MGR=()
  declare -A MGR_VERSION_MAP=()
  for i in "${!PKG_MGR_IDS[@]}"; do
    INSTALLED_MGR["${PKG_MGR_IDS[$i]}"]=1
    MGR_VERSION_MAP["${PKG_MGR_IDS[$i]}"]="${PKG_MGR_VERSIONS[$i]}"
  done
  local -a SUPPORTED_MANAGERS=(
    "pacman:Pacman (Arch)"
    "apt:APT (Debian/Ubuntu)"
    "dnf:DNF (Fedora/RHEL)"
    "yum:YUM (Old RHEL)"
    "zypper:Zypper (openSUSE)"
  )

  local -a helper_entries=()
  local -a helper_candidates=(
    "yay|Yay"
    "paru|Paru"
    "pikaur|Pikaur"
    "trizen|Trizen"
    "aura|Aura"
  )
  local candidate
  for candidate in "${helper_candidates[@]}"; do
    local helper label version_line
    local IFS='|'
    read -r helper label <<< "$candidate"
    if command_exists "$helper"; then
      version_line="$("$helper" --version 2>/dev/null | head -n1 | tr -d '\r')"
      local helper_ver
      helper_ver="$(extract_version_number "$version_line")"
      [[ -z "$helper_ver" ]] && helper_ver="n/a"
      helper_entries+=("$label|$helper_ver")
    fi
  done

  local docker_running="" podman_running=""
  if (( docker_ok )); then
    docker_running="$(docker ps --format '{{.Names}} ({{.Image}})' 2>/dev/null || true)"
  fi
  if (( podman_ok )); then
    podman_running="$(podman ps --format '{{.Names}} ({{.Image}})' 2>/dev/null || true)"
  fi

  local include_all_packages=$INCLUDE_ALL_PACKAGES
  local exit_menu=0
  local status_line=""
  while (( ! exit_menu )); do
    echo
    draw_menu_header
    echo

    echo "${BOLD}Package managers:${RESET}"
    for entry in "${SUPPORTED_MANAGERS[@]}"; do
      local mgr_id mgr_label
      local IFS=':'
      read -r mgr_id mgr_label <<< "$entry"
      local mark=" "
      local ver_hint=""
      if [[ -n "${INSTALLED_MGR[$mgr_id]:-}" ]]; then
        mark="✓"
        local version="${MGR_VERSION_MAP[$mgr_id]:-}"
        if [[ -n "$version" && "$version" != "n/a" ]]; then
          ver_hint="$version"
        fi
      fi
      format_checkbox_row "" "$mark" "$mgr_label" "$ver_hint" ""
    done

    if (( ${#helper_entries[@]} > 0 )); then
      echo
      echo "${BOLD}Helper tools:${RESET}"
      for entry in "${helper_entries[@]}"; do
        local helper_label helper_version version_suffix=""
        local IFS='|'
        read -r helper_label helper_version <<< "$entry"
        [[ -n "$helper_version" && "$helper_version" != "n/a" ]] && version_suffix="$helper_version"
        format_checkbox_row "" "✓" "$helper_label" "$version_suffix" ""
      done
    fi

    if (( docker_ok || podman_ok )); then
      echo
      echo "${BOLD}Running containers:${RESET}"
      if (( docker_ok )); then
        if [[ -n "$docker_running" ]]; then
          echo "  Docker:"
          while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf '    %s\n' "$line"
          done <<< "$docker_running"
        else
          echo "  Docker: (none)"
        fi
      fi
      if (( podman_ok )); then
        if [[ -n "$podman_running" ]]; then
          echo "  Podman:"
          while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf '    %s\n' "$line"
          done <<< "$podman_running"
        else
          echo "  Podman: (none)"
        fi
      fi
    fi

    echo
    echo "${BOLD}Sources:${RESET}"
    if (( ${#option_labels[@]} == 0 )); then
      echo "  (none available)"
    else
      for idx in "${!option_labels[@]}"; do
        local target="${option_targets[$idx]}"
        local enabled=0
        local version_hint=""
        case "$target" in
          repo)
            enabled=$include_repo
            version_hint="$repo_version_label"
            ;;
          aur)
            enabled=$include_aur
            version_hint="$aur_version_label"
            ;;
          flatpak)
            enabled=$include_flatpak
            version_hint="$flatpak_version"
            ;;
          snap)
            enabled=$include_snap
            version_hint="$snap_version"
            ;;
          appimage)
            enabled=$include_appimage
            ;;
          local)
            enabled=$include_local
            ;;
          pip)
            enabled=$include_pip
            version_hint="$pip_version"
            ;;
          docker)
            enabled=$include_docker
            version_hint="$docker_version"
            ;;
          podman)
            enabled=$include_podman
            version_hint="$podman_version"
            ;;
          ollama)
            enabled=$include_ollama
            version_hint="$ollama_version"
            ;;
          nix)
            enabled=$include_nix
            version_hint="$nix_version"
            ;;
          cargo)
            enabled=$include_cargo
            version_hint="$cargo_version"
            ;;
          npm)
            enabled=$include_npm
            version_hint="$npm_version"
            ;;
          brew)
            enabled=$include_brew
            version_hint="$brew_version"
            ;;
          go)
            enabled=$include_go
            version_hint="$go_version"
            ;;
          pipx)
            enabled=$include_pipx
            version_hint="$pipx_version"
            ;;
          systemd)
            enabled=$include_systemd
            version_hint="$systemd_version"
            ;;
        esac
        local mark=" "
        (( enabled )) && mark="✓"
        local note_text="${option_notes[$idx]}"
        note_text="$(trim_whitespace "$note_text")"
        local version_value="$version_hint"
        [[ -n "$version_value" ]] && version_value="($version_value)"
        local prefix
        prefix=$(printf '%2d)' "$((idx+1))")
        format_checkbox_row "$prefix" "$mark" "${option_labels[$idx]}" "$version_value" "$note_text"
      done
    fi

  if (( ${#missing_sources[@]} > 0 )); then
    echo
    printf '  %s\n' "${BOLD}Unavailable:${RESET}"
    for idx in "${!missing_sources[@]}"; do
      printf '    - %-24s %s\n' "${missing_sources[$idx]}" "(${missing_notes[$idx]})"
    done
  fi

    echo
    printf '  %s\n' "${BOLD}Presets:${RESET}"
    for preset_id in 1 2 3 4 5; do
      printf '    P%-2d %s\n' "$preset_id" "${SOURCE_PRESET_LABELS[$preset_id]}"
    done

    local search_display="${SEARCH_TERM:-<none>}"
    if [[ -n "$SEARCH_TERM" ]]; then
      search_display="${YELLOW}${SEARCH_TERM}${RESET}"
    fi
    echo
    printf '  %s\n' "${BOLD}Current config:${RESET}"
    printf '    Sources:'
    (( include_repo ))     && printf ' Repo'
    (( include_aur ))      && printf ' AUR'
    (( include_flatpak ))  && printf ' Flatpak'
    (( include_snap ))     && printf ' Snap'
    (( include_appimage )) && printf ' AppImage'
    (( include_local ))    && printf ' Local'
    (( include_pip ))      && printf ' Pip'
    (( include_docker ))   && printf ' Docker'
    (( include_podman ))   && printf ' Podman'
    (( include_ollama ))   && printf ' Ollama'
    (( include_nix ))      && printf ' Nix'
    (( include_cargo ))    && printf ' Cargo'
    (( include_npm ))      && printf ' npm'
    (( include_brew ))     && printf ' Brew'
    (( include_go ))       && printf ' Go'
    (( include_pipx ))     && printf ' Pipx'
    (( include_systemd ))  && printf ' systemd'
    printf '\n'
    printf '    Search: %s\n' "$search_display"
    local mode_label
    if (( include_all_packages )); then
      mode_label="${GREEN}Everything${RESET}"
    else
      mode_label="${CYAN}Apps only${RESET}"
    fi
    printf '    Mode: %s\n' "$mode_label"
    local orphan_display="Off"
    (( SHOW_ONLY_ORPHANS )) && orphan_display="${YELLOW}On${RESET}"
    printf '    Orphans only: %s\n' "$orphan_display"

    echo
    printf '  %s\n' "${BOLD}Commands:${RESET}"
    printf '    %-26s %-26s\n' "[numbers] Toggle source" "[P#] Apply preset"
    printf '    %-26s %-26s\n' "[A] Enable all sources" "[D] Disable all sources"
    printf '    %-26s %-26s\n' "[O] Toggle orphans-only" "[S] Set search term"
    printf '    %-26s %-26s\n' "[X] Toggle apps/all" "[H] Help / usage"
    printf '    %-26s %-26s\n' "[R] or [Enter] Run scan" "[Q] Quit"
    if [[ -n "$status_line" ]]; then
      echo
      echo "$status_line"
      status_line=""
    fi

    local input
    read -rp "> " input
    [[ -z "$input" ]] && input="R"
    local run_requested=0
    # Intentional splitting: treat whitespace-separated tokens (e.g. "1 3 A") as separate commands
    for token in $input; do
      local token_upper="${token^^}"
      case "$token_upper" in
        A)
          include_repo=$repo_available
          include_aur=$aur_available
          include_flatpak=$flatpak_ok
          include_snap=$snap_ok
          include_appimage=1
          include_local=1
          include_pip=$pip_ok
          include_docker=$docker_ok
          include_podman=$podman_ok
          include_ollama=$ollama_ok
          include_nix=$nix_ok
          include_cargo=$cargo_ok
          include_npm=$npm_ok
          include_brew=$brew_ok
          include_go=$go_ok
          include_pipx=$pipx_ok
          include_systemd=$systemd_ok
          status_line="${GREEN}All sources enabled${RESET}"
          ;;
        D)
          include_repo=0
          include_aur=0
          include_flatpak=0
          include_snap=0
          include_appimage=0
          include_local=0
          include_pip=0
          include_docker=0
          include_podman=0
          include_ollama=0
          include_nix=0
          include_cargo=0
          include_npm=0
          include_brew=0
          include_go=0
          include_pipx=0
          include_systemd=0
          status_line="${GREEN}All sources disabled${RESET}"
          ;;
        S)
          read -rp "Enter search term (blank to clear, current: ${SEARCH_TERM:-<none>}): " SEARCH_TERM
          NAME_FILTER="$SEARCH_TERM"
          ;;
        O)
          if (( SHOW_ONLY_ORPHANS )); then
            SHOW_ONLY_ORPHANS=0
            status_line="${GREEN}Orphans filter:${RESET} Off"
          else
            SHOW_ONLY_ORPHANS=1
            status_line="${GREEN}Orphans filter:${RESET} On (pacman only)"
          fi
          ;;
        R)
          run_requested=1
          ;;
        Q)
          exit 0
          ;;
        H)
          show_usage_modal
          ;;
        X)
          if (( include_all_packages )); then
            include_all_packages=0
            status_line="${GREEN}Mode:${RESET} Apps only (explicit packages)"
          else
            include_all_packages=1
            status_line="${GREEN}Mode:${RESET} Everything (all repositories)"
          fi
          ;;
        P*)
          local preset_choice="${token_upper#P}"
          if [[ -z "$preset_choice" ]]; then
            read -rp "Preset number: " preset_choice
            preset_choice="${preset_choice^^}"
            preset_choice="${preset_choice#P}"
          fi
          if [[ -z "${SOURCE_PRESETS[$preset_choice]:-}" ]]; then
            status_line="${YELLOW}[WARN]${RESET} Unknown preset: ${preset_choice}"
            continue
          fi
          include_repo=0
          include_aur=0
          include_flatpak=0
          include_snap=0
          include_appimage=0
          include_local=0
          include_pip=0
          local skipped=()
          local src
          local preset_sources=()
          local IFS=' '
          read -ra preset_sources <<< "${SOURCE_PRESETS[$preset_choice]}"
          for src in "${preset_sources[@]}"; do
            case "$src" in
              repo)
                if (( repo_available )); then include_repo=1; else skipped+=("Repo"); fi ;;
              aur)
                if (( aur_available )); then include_aur=1; else skipped+=("AUR"); fi ;;
              flatpak)
                if (( flatpak_ok )); then include_flatpak=1; else skipped+=("Flatpak"); fi ;;
              snap)
                if (( snap_ok )); then include_snap=1; else skipped+=("Snap"); fi ;;
              appimage) include_appimage=1 ;;
              local) include_local=1 ;;
              pip)
                if (( pip_ok )); then include_pip=1; else skipped+=("Pip"); fi ;;
              docker)
                if (( docker_ok )); then include_docker=1; else skipped+=("Docker"); fi ;;
              podman)
                if (( podman_ok )); then include_podman=1; else skipped+=("Podman"); fi ;;
              ollama)
                if (( ollama_ok )); then include_ollama=1; else skipped+=("Ollama"); fi ;;
              nix)
                if (( nix_ok )); then include_nix=1; else skipped+=("Nix"); fi ;;
              cargo)
                if (( cargo_ok )); then include_cargo=1; else skipped+=("Cargo"); fi ;;
              npm)
                if (( npm_ok )); then include_npm=1; else skipped+=("npm"); fi ;;
              brew)
                if (( brew_ok )); then include_brew=1; else skipped+=("Brew"); fi ;;
              go)
                if (( go_ok )); then include_go=1; else skipped+=("Go"); fi ;;
              pipx)
                if (( pipx_ok )); then include_pipx=1; else skipped+=("pipx"); fi ;;
              systemd)
                if (( systemd_ok )); then include_systemd=1; else skipped+=("systemd"); fi ;;
            esac
          done
          status_line="${GREEN}[INFO]${RESET} Applied preset: ${SOURCE_PRESET_LABELS[$preset_choice]}"
          if (( ${#skipped[@]} > 0 )); then
            status_line+=" ${YELLOW}(skipped: ${skipped[*]})${RESET}"
          fi
          ;;
        *)
          if [[ "$token" =~ ^[0-9]+$ ]]; then
            local idx=$((token - 1))
            if (( idx >= 0 && idx < ${#option_targets[@]} )); then
              case "${option_targets[$idx]}" in
                repo)     include_repo=$((include_repo ? 0 : 1)) ;;
                aur)      include_aur=$((include_aur ? 0 : 1)) ;;
                flatpak)  include_flatpak=$((include_flatpak ? 0 : 1)) ;;
                snap)     include_snap=$((include_snap ? 0 : 1)) ;;
                appimage) include_appimage=$((include_appimage ? 0 : 1)) ;;
                local)    include_local=$((include_local ? 0 : 1)) ;;
                pip)      include_pip=$((include_pip ? 0 : 1)) ;;
                docker)   include_docker=$((include_docker ? 0 : 1)) ;;
                podman)   include_podman=$((include_podman ? 0 : 1)) ;;
                ollama)   include_ollama=$((include_ollama ? 0 : 1)) ;;
                nix)      include_nix=$((include_nix ? 0 : 1)) ;;
                cargo)    include_cargo=$((include_cargo ? 0 : 1)) ;;
                npm)      include_npm=$((include_npm ? 0 : 1)) ;;
                brew)     include_brew=$((include_brew ? 0 : 1)) ;;
                go)       include_go=$((include_go ? 0 : 1)) ;;
                pipx)     include_pipx=$((include_pipx ? 0 : 1)) ;;
                systemd)  include_systemd=$((include_systemd ? 0 : 1)) ;;
              esac
            else
              status_line="${YELLOW}[WARN]${RESET} Invalid source number: $token"
            fi
          else
            status_line="${YELLOW}[WARN]${RESET} Unknown selection: $token"
          fi
          ;;
      esac
    done
    if (( run_requested )); then
      if (( ! include_repo && ! include_aur && ! include_flatpak && ! include_snap && ! include_appimage && ! include_local && ! include_pip && ! include_docker && ! include_podman && ! include_ollama && ! include_nix && ! include_cargo && ! include_npm && ! include_brew && ! include_go && ! include_pipx && ! include_systemd )); then
        status_line="${YELLOW}[WARN]${RESET} Select at least one source before running."
        continue
      fi
      INCLUDE_REPO=$include_repo
      INCLUDE_AUR=$include_aur
      INCLUDE_FLATPAK=$include_flatpak
      INCLUDE_SNAP=$include_snap
      INCLUDE_APPIMAGE=$include_appimage
      INCLUDE_LOCAL=$include_local
      INCLUDE_PIP=$include_pip
      INCLUDE_DOCKER=$include_docker
      INCLUDE_PODMAN=$include_podman
      INCLUDE_OLLAMA=$include_ollama
      INCLUDE_NIX=$include_nix
      INCLUDE_CARGO=$include_cargo
      INCLUDE_NPM=$include_npm
      INCLUDE_BREW=$include_brew
      INCLUDE_GO=$include_go
      INCLUDE_PIPX=$include_pipx
      INCLUDE_SYSTEMD_USER=$include_systemd
      INCLUDE_ALL_PACKAGES=$include_all_packages
      MANAGERS_ARG="all"
      MENU_CONFIRMED=1
      exit_menu=1
    fi
  done
  return
}

# ---------- Orphaned for pacman ----------
declare -A ORPHANED_PKGS
if command_exists pacman; then
  while read -r p; do
    [[ -n "$p" ]] && ORPHANED_PKGS["$p"]=1
  done < <(pacman -Qtdq 2>/dev/null || true)
fi

# ---------- Add entry ----------
add_entry() {
  local name="$1" type="$2" source="$3" details="$4"
  local version="${5:-}" size="${6:-}" orphaned="${7:-no}"

  if (( SHOW_ONLY_ORPHANS )) && [[ "$orphaned" != "yes" ]]; then
    return 0
  fi

  if [[ -n "$NAME_FILTER" ]]; then
    local n_lower="${name,,}"
    local f_lower="${NAME_FILTER,,}"
    [[ "$n_lower" == *"$f_lower"* ]] || return 0
  fi

  TYPE_COUNTS["$type"]=$(( ${TYPE_COUNTS["$type"]:-0} + 1 ))

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(safe_print "$name")" \
    "$(safe_print "$type")" \
    "$(safe_print "$source")" \
    "$(safe_print "$details")" \
    "$(safe_print "$version")" \
    "$(safe_print "$size")" \
    "$(safe_print "$orphaned")" >> "$TMPFILE"
}

# ---------- Header ----------
echo -e "Name\tType\tSource\tDetails\tVersion\tSize\tOrphaned" > "$TMPFILE"

# ---------- Repo gatherers ----------

gather_pacman_repo_and_aur() {
  (( ! INCLUDE_REPO && ! INCLUDE_AUR )) && return 0
  command_exists pacman || return 0

  local have_expac=0
  declare -A PACMAN_SIZE_BYTES=()
  if command_exists expac; then
    have_expac=1
    while IFS=$'\t' read -r pkg size_bytes; do
      [[ -z "$pkg" ]] && continue
      PACMAN_SIZE_BYTES["$pkg"]="$size_bytes"
    done < <(expac -Q '%n\t%m' 2>/dev/null || true)
  fi

  local -a repo_cmd=(-Qen)
  if (( INCLUDE_ALL_PACKAGES )); then
    repo_cmd=(-Qn)
  fi

  if (( INCLUDE_REPO )); then
    pacman "${repo_cmd[@]}" 2>/dev/null | \
    while read -r name ver; do
      [[ -z "$name" ]] && continue
      local size="-"
      if (( have_expac )); then
        local size_bytes="${PACMAN_SIZE_BYTES[$name]:-}"
        if [[ -n "$size_bytes" && "$size_bytes" != "0" ]]; then
          size=$(format_size "$size_bytes")
        fi
      fi
      local orphaned="no"
      [[ -n "${ORPHANED_PKGS[$name]:-}" ]] && orphaned="yes"
      local details="Official repository"
      (( have_expac )) || details+=" (expac unavailable)"
      add_entry "$name" "Repo" "pacman/repo" "$details" "$ver" "$size" "$orphaned"
    done
  fi

  if (( INCLUDE_AUR )); then
    local -a aur_cmd=(-Qm)
    pacman "${aur_cmd[@]}" 2>/dev/null | \
    while read -r name ver; do
      [[ -z "$name" ]] && continue
      local size="-"
      if (( have_expac )); then
        local size_bytes="${PACMAN_SIZE_BYTES[$name]:-}"
        if [[ -n "$size_bytes" && "$size_bytes" != "0" ]]; then
          size=$(format_size "$size_bytes")
        fi
      fi
      local orphaned="no"
      [[ -n "${ORPHANED_PKGS[$name]:-}" ]] && orphaned="yes"
      local details="Foreign (AUR or manual)"
      (( have_expac )) || details+=" (expac unavailable)"
      add_entry "$name" "$FOREIGN_TYPE_LABEL" "pacman/foreign" "$details" "$ver" "$size" "$orphaned"
    done
  fi
}

gather_apt_repo() {
  (( INCLUDE_REPO )) || return 0
  command_exists dpkg-query || return 0

  dpkg-query -W -f='${Package}\t${Version}\t${Installed-Size}\n' 2>/dev/null | \
  while IFS=$'\t' read -r name ver kb; do
    [[ -z "$name" ]] && continue
    local size="-"
    if [[ -n "$kb" && "$kb" != "0" ]]; then
      size=$(format_size "$((kb * 1024))")
    fi
    add_entry "$name" "Repo" "apt" "dpkg/apt package" "$ver" "$size" "no"
  done
}

gather_dnf_repo() {
  (( INCLUDE_REPO )) || return 0
  local DNF
  DNF=$(command -v dnf || command -v yum || true)
  [[ -z "$DNF" ]] && return

  "$DNF" list installed 2>/dev/null | tail -n +2 | \
  while read -r pkg ver repo; do
    [[ -z "$pkg" ]] && continue
    add_entry "$pkg" "Repo" "${DNF##*/}/$repo" "dnf/yum package" "$ver" "-" "no"
  done
}

gather_zypper_repo() {
  (( INCLUDE_REPO )) || return 0
  command_exists zypper || return 0

  zypper search -i --type package 2>/dev/null | \
  awk 'NR>2 && $1 ~ /^[ips]/ {print $3"\t"$4}' | \
  while IFS=$'\t' read -r name ver; do
    [[ -z "$name" ]] && continue
    add_entry "$name" "Repo" "zypper" "Zypper package" "$ver" "-" "no"
  done
}

# ---------- Non-repo sources ----------
gather_flatpak() {
  (( INCLUDE_FLATPAK )) || return 0
  command_exists flatpak || return 0

  local -a flatpak_args=(list "--columns=application,name,branch,installation,version,size,ref")
  (( INCLUDE_ALL_PACKAGES )) || flatpak_args=(list --app "--columns=application,name,branch,installation,version,size,ref")

  flatpak "${flatpak_args[@]}" 2>/dev/null | \
  while IFS=$'\t' read -r id n branch inst ver size ref; do
    [[ -z "$id" || "$id" == "Application ID" ]] && continue
    [[ -z "$size" || "$size" == "0" ]] && size="-"
    local ref_type=""
    if [[ -n "$ref" ]]; then
      ref_type="${ref%%/*}"
    fi
    local details="ID: $id, Branch: $branch, Installation: $inst"
    [[ -n "$ref_type" ]] && details+=", Type: $ref_type"
    [[ -n "$ref" ]] && details+=", Ref: $ref"
    add_entry "${n:-$id}" "Flatpak" "flatpak/$inst" "$details" "$ver" "$size" "no"
  done
}

gather_snap() {
  (( INCLUDE_SNAP )) || return 0
  command_exists snap || return 0

  snap list 2>/dev/null | tail -n +2 | \
  while read -r name ver _rev track pub notes; do
    [[ -z "$name" ]] && continue
    local details="Publisher: $pub"
    [[ -n "$notes" ]] && details+=", Notes: $notes"
    add_entry "$name" "Snap" "snap/$track" "$details" "$ver" "-" "no"
  done
}

gather_appimages() {
  (( INCLUDE_APPIMAGE )) || return 0

  declare -a search_dirs=(
    "$HOME/Applications"
    "$HOME/.local/share/applications"
    "$HOME/AppImages"
    "$HOME/Downloads"
    "$HOME/.local/bin"
    "$HOME/bin"
    "/opt"
  )

  declare -a appimage_files=()
  for d in "${search_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r -d '' f; do
      [[ -f "$f" ]] && appimage_files+=("$f")
    done < <(find "$d" -maxdepth 2 -iname "*.appimage" -type f -print0 2>/dev/null)
  done

  for f in "${appimage_files[@]}"; do
    local name size ver
    name="$(basename "$f")"
    name="${name%.[Aa][Pp][Pp][Ii][Mm][Aa][Gg][Ee]}"
    size=$(du -h "$f" 2>/dev/null | cut -f1 || echo "-")
    ver="$(extract_version "$f")"
    add_entry "$name" "AppImage" "appimage" "Location: $f" "$ver" "$size" "no"
  done
}

gather_local_binaries() {
  (( INCLUDE_LOCAL )) || return 0

  declare -a dirs=("$HOME/.local/bin" "$HOME/bin" "/usr/local/bin")

  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue
    find "$d" -maxdepth 1 -type f -executable -print0 2>/dev/null | \
    while IFS= read -r -d '' f; do
      [[ -x "$f" ]] || continue
      local name
      name="$(basename "$f")"
      local size="-"
      local size_bytes
      if size_bytes=$(stat -c%s "$f" 2>/dev/null); then
        size=$(format_size "$size_bytes")
      else
        size=$(du -h "$f" 2>/dev/null | cut -f1 || echo "-")
      fi
      local ver="-"
      if (( RUN_BINARIES )); then
        ver="$(extract_version "$f")"
      fi
      add_entry "$name" "Local Binary" "filesystem" "Path: $f" "$ver" "$size" "no"
    done
  done
}

gather_pip_global() {
  (( INCLUDE_PIP )) || return 0

  declare -a pip_candidates=()
  declare -A pip_paths_seen=()
  local candidate
  for candidate in pip3 pip; do
    local cmd_path
    cmd_path=$(command -v "$candidate" 2>/dev/null) || continue
    local resolved="$cmd_path"
    if command_exists readlink; then
      resolved="$(readlink -f "$cmd_path" 2>/dev/null || echo "$cmd_path")"
    fi
    if [[ -n "${pip_paths_seen[$resolved]:-}" ]]; then
      continue
    fi
    pip_paths_seen[$resolved]=1
    pip_candidates+=("$candidate")
  done

  (( ${#pip_candidates[@]} )) || return 0

  local pip_cmd
  for pip_cmd in "${pip_candidates[@]}"; do
    local source_label="pip/$pip_cmd"
    while IFS= read -r line; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      local name version details
      details="Installed via $pip_cmd"
      if [[ "$line" == *" @ "* ]]; then
        name="${line%% @ *}"
        version="${line#* @ }"
      elif [[ "$line" == *"==="* ]]; then
        name="${line%%===*}"
        version="${line#*===}"
      elif [[ "$line" == *"=="* ]]; then
        name="${line%%==*}"
        version="${line#*==}"
      else
        name="$line"
        version="-"
      fi
      [[ -z "$name" ]] && continue
      [[ -z "$version" ]] && version="-"
      add_entry "$name" "Python Package" "$source_label" "$details" "$version" "-" "no"
    done < <("$pip_cmd" list --format=freeze 2>/dev/null)
  done
}

gather_docker() {
  (( INCLUDE_DOCKER )) || return 0
  command_exists docker || return 0

  local images_output="" containers_output=""
  if ! images_output="$(docker images --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}' 2>/dev/null)"; then
    log_warn "Failed to query Docker images (is the daemon running and do you have permission?)"
  else
    while IFS=$'\t' read -r repo tag img_id size; do
      [[ -z "$repo" ]] && continue
      local name="$repo"
      [[ -n "$tag" && "$tag" != "<none>" ]] && name+=":$tag"
      local details="Image ID: $img_id"
      add_entry "$name" "Container Image" "docker/image" "$details" "$tag" "$size" "no"
    done <<< "$images_output"
  fi

  if ! containers_output="$(docker ps -a --size --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Size}}' 2>/dev/null)"; then
    log_warn "Failed to query Docker containers (is the daemon running and do you have permission?)"
  else
    while IFS=$'\t' read -r cname image status size; do
      [[ -z "$cname" ]] && continue
      local details="Image: $image, Status: $status"
      add_entry "$cname" "Container" "docker/container" "$details" "-" "${size:-"-"}" "no"
    done <<< "$containers_output"
  fi
}

gather_podman() {
  (( INCLUDE_PODMAN )) || return 0
  command_exists podman || return 0

  local images_output="" containers_output=""
  if ! images_output="$(podman images --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}' 2>/dev/null)"; then
    log_warn "Failed to query Podman images (is podman running and permissions ok?)"
  else
    while IFS=$'\t' read -r repo tag img_id size; do
      [[ -z "$repo" ]] && continue
      local name="$repo"
      [[ -n "$tag" && "$tag" != "<none>" ]] && name+=":$tag"
      local details="Image ID: $img_id"
      add_entry "$name" "Container Image" "podman/image" "$details" "$tag" "$size" "no"
    done <<< "$images_output"
  fi

  if ! containers_output="$(podman ps -a --size --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Size}}' 2>/dev/null)"; then
    log_warn "Failed to query Podman containers (is podman running and permissions ok?)"
  else
    while IFS=$'\t' read -r cname image status size; do
      [[ -z "$cname" ]] && continue
      local details="Image: $image, Status: $status"
      add_entry "$cname" "Container" "podman/container" "$details" "-" "${size:-"-"}" "no"
    done <<< "$containers_output"
  fi
}

gather_ollama() {
  (( INCLUDE_OLLAMA )) || return 0

  local -a list_cmd=()
  local source_label="ollama"
  local container_id="" container_name=""

  if command_exists ollama; then
    list_cmd=(ollama list)
  elif command_exists docker; then
    (( INCLUDE_DOCKER )) || return 0
    while IFS=$'\t' read -r cid img name; do
      [[ -z "$cid" ]] && continue
      local img_lc="${img,,}"
      local name_lc="${name,,}"
      if [[ "$img_lc" == *ollama* || "$name_lc" == *ollama* ]]; then
        container_id="$cid"
        container_name="$name"
        break
      fi
    done < <(docker ps --format '{{.ID}}\t{{.Image}}\t{{.Names}}' 2>/dev/null || true)
    if [[ -n "$container_id" ]]; then
      list_cmd=(docker exec "$container_id" ollama list)
      source_label="docker/${container_name:-$container_id}"
    else
      return 0
    fi
  else
    return 0
  fi

  local json_output=""
  local api_json=""
  local -a ollama_json_sources=()
  local has_python=0
  command_exists python3 && has_python=1
  if (( has_python )); then
    json_output="$("${list_cmd[@]}" --format json 2>/dev/null || "${list_cmd[@]}" --json 2>/dev/null || true)"
    [[ -n "$json_output" ]] && ollama_json_sources+=("$json_output")
  fi

  # If CLI/json output is empty, try querying the Ollama HTTP API directly.
  if (( has_python )) && [[ -z "$json_output" ]] && command_exists curl; then
    api_json="$(curl -fsSL "${OLLAMA_HOST:-http://127.0.0.1:11434}/api/tags" 2>/dev/null || true)"
    [[ -n "$api_json" ]] && ollama_json_sources+=("$api_json")
  fi

  # If running under Docker, try querying each detected Ollama container directly for models.
  if command_exists docker && (( INCLUDE_DOCKER )); then
    while IFS=$'\t' read -r cid img name; do
      [[ -z "$cid" ]] && continue
      local img_lc="${img,,}"
      local name_lc="${name,,}"
      if [[ "$img_lc" != *ollama* && "$name_lc" != *ollama* ]]; then
        continue
      fi
      if (( has_python )); then
        local container_json=""
        container_json="$(docker exec "$cid" ollama list --format json 2>/dev/null || docker exec "$cid" ollama list --json 2>/dev/null || true)"
        if [[ -z "$container_json" ]]; then
          container_json="$(docker exec "$cid" curl -fsSL http://127.0.0.1:11434/api/tags 2>/dev/null || true)"
        fi
        [[ -n "$container_json" ]] && ollama_json_sources+=("$container_json")
      fi
    done < <(docker ps --format '{{.ID}}\t{{.Image}}\t{{.Names}}' 2>/dev/null || true)
  fi

  if (( has_python )) && (( ${#ollama_json_sources[@]} > 0 )); then
    while IFS=$'\t' read -r name size digest; do
      [[ -z "$name" ]] && continue
      local details="Digest: ${digest:-unknown}"
      add_entry "$name" "Ollama Model" "$source_label" "$details" "-" "$size" "no"
    done < <(
      printf '%s\0' "${ollama_json_sources[@]}" | python3 2>/dev/null -c 'import json, sys
data = sys.stdin.buffer.read().split(b"\0")
for blob in data:
    if not blob.strip():
        continue
    try:
        obj = json.loads(blob.decode("utf-8", "replace"))
    except Exception:
        continue
    items = []
    if isinstance(obj, dict) and "models" in obj:
        items = obj.get("models") or []
    elif isinstance(obj, list):
        items = obj
    for item in items:
        if not isinstance(item, dict):
            continue
        name = item.get("name") or ""
        size = item.get("size") or item.get("bytes") or "-"
        digest = item.get("digest") or item.get("id") or ""
        if name:
            print(f"{name}\t{size}\t{digest}")
'
    )
  else
    ( "${list_cmd[@]}" 2>/dev/null || true ) | awk 'NR>1 {print $1"\t"$3"\t"$2}' | while IFS=$'\t' read -r name size digest; do
      [[ -z "$name" ]] && continue
      local details="Digest: ${digest:-unknown}"
      add_entry "$name" "Ollama Model" "$source_label" "$details" "-" "$size" "no"
    done
  fi
}

gather_nix_packages() {
  (( INCLUDE_NIX )) || return 0
  command_exists nix-env || return 0

  local json_output
  if command_exists python3 && json_output="$(nix-env -q --installed --json 2>/dev/null)"; then
    while IFS=$'\t' read -r name ver; do
      [[ -z "$name" ]] && continue
      local details="nix-env installed package"
      add_entry "$name" "Nix Package" "nix-env" "$details" "$ver" "-" "no"
    done < <(
      printf '%s\n' "$json_output" | python3 -c 'import json, sys
raw = sys.stdin.read()
try:
    items = json.loads(raw)
except Exception:
    sys.exit(0)
def pick_version(entry):
    return entry.get("version") or entry.get("meta", {}).get("version") or "-"
if isinstance(items, list):
    iterable = items
elif isinstance(items, dict):
    iterable = items.values()
else:
    iterable = []
for item in iterable:
    name = item.get("name") or item.get("pname") or item.get("attrPath") or ""
    if not name:
        continue
    version = pick_version(item)
    print(f"{name}\t{version}")'
    )
  else
    nix-env -q --installed 2>/dev/null | while read -r name; do
      [[ -z "$name" ]] && continue
      add_entry "$name" "Nix Package" "nix-env" "nix-env installed package" "-" "-" "no"
    done
  fi
}

gather_cargo_global() {
  (( INCLUDE_CARGO )) || return 0
  command_exists cargo || return 0

  cargo install --list 2>/dev/null | \
  grep -E '^[^ ]+ v[0-9]' | while read -r line; do
    local name ver
    name="${line%% v*}"
    ver="${line#* v}"
    ver="${ver%% *}"
    add_entry "$name" "Rust Binary" "cargo" "cargo install --list" "$ver" "-" "no"
  done
}

gather_npm_global() {
  (( INCLUDE_NPM )) || return 0
  command_exists npm || return 0

  if command_exists python3; then
    npm list -g --depth=0 --json 2>/dev/null | \
    python3 -c 'import json, sys
try:
    deps = json.load(sys.stdin).get("dependencies", {})
except Exception:
    sys.exit(0)
for name, meta in deps.items():
    ver = meta.get("version", "-")
    print(f"{name}\t{ver}")' 2>/dev/null | \
    while IFS=$'\t' read -r name ver; do
      [[ -z "$name" ]] && continue
      add_entry "$name" "Node Package" "npm/global" "npm -g package" "$ver" "-" "no"
    done
  else
    npm list -g --depth=0 2>/dev/null | tail -n +2 | sed 's/^[^a-zA-Z0-9@]*//' | while read -r line; do
      [[ -z "$line" ]] && continue
      local name ver
      if [[ "$line" == *@* ]]; then
        name="${line%@*}"
        ver="${line#*@}"
      else
        name="$line"
        ver="-"
      fi
      add_entry "$name" "Node Package" "npm/global" "npm -g package" "$ver" "-" "no"
    done
  fi
}

gather_brew_packages() {
  (( INCLUDE_BREW )) || return 0
  command_exists brew || return 0

  brew list --versions 2>/dev/null | while read -r name ver _rest; do
    [[ -z "$name" ]] && continue
    add_entry "$name" "Homebrew Package" "brew" "brew installed package" "$ver" "-" "no"
  done
}

gather_go_binaries() {
  (( INCLUDE_GO )) || return 0
  command_exists go || return 0

  local -a bin_dirs=()
  local gobin
  gobin="$(go env GOBIN 2>/dev/null || true)"
  [[ -n "$gobin" ]] && bin_dirs+=("$gobin")
  local gopath
  gopath="$(go env GOPATH 2>/dev/null || true)"
  if [[ -n "$gopath" ]]; then
    bin_dirs+=("$gopath/bin")
  fi
  bin_dirs+=("$HOME/go/bin")

  declare -A seen_dirs=()
  local d
  for d in "${bin_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    [[ -n "${seen_dirs[$d]:-}" ]] && continue
    seen_dirs["$d"]=1
    find "$d" -maxdepth 1 -type f -executable -print0 2>/dev/null | \
    while IFS= read -r -d '' f; do
      local name size_bytes size_fmt="-"
      name="$(basename "$f")"
      if size_bytes=$(stat -c%s "$f" 2>/dev/null); then
        size_fmt=$(format_size "$size_bytes")
      fi
      add_entry "$name" "Go Binary" "go/bin" "Path: $f" "-" "$size_fmt" "no"
    done
  done
}

gather_pipx_apps() {
  (( INCLUDE_PIPX )) || return 0
  command_exists pipx || return 0

  pipx list --short 2>/dev/null | while read -r name ver_rest; do
    [[ -z "$name" ]] && continue
    local ver="-"
    if [[ "$ver_rest" =~ ([0-9][^[:space:]]*) ]]; then
      ver="${BASH_REMATCH[1]}"
    fi
    add_entry "$name" "Pipx Package" "pipx" "pipx installed app" "$ver" "-" "no"
  done
}

gather_systemd_user_services() {
  (( INCLUDE_SYSTEMD_USER )) || return 0
  command_exists systemctl || return 0

  { SYSTEMD_PAGER='' SYSTEMD_COLORS='' systemctl --user list-unit-files --type=service --no-legend --no-pager 2>/dev/null || true; } | \
  while read -r unit state rest; do
    [[ -z "$unit" ]] && continue
    local name="${unit%.service}"
    local details="State: ${state:-unknown}"
    add_entry "$name" "User Service" "systemd/user" "$details" "-" "-" "no"
  done
}

# ---------- Select package managers ----------
PKG_MGR_IDS=()
PKG_MGR_LABELS=()
PKG_MGR_VERSIONS=()
SELECTED_PKG_MGRS=()
declare -A PKG_MGR_SEEN=()

detect_pkg_manager() {
  local id="$1" label="$2" ver_cmd="$3"
  [[ -n "${PKG_MGR_SEEN[$id]:-}" ]] && return
  if command_exists "$id"; then
    PKG_MGR_IDS+=("$id")
    PKG_MGR_LABELS+=("$label")
    local raw_ver
    raw_ver="$(eval "$ver_cmd" 2>/dev/null | sed -n '/./{s/^[[:space:]]*//;p;q}' | tr -d '\r' || echo "")"
    raw_ver="$(trim_whitespace "$raw_ver")"
    local short_ver
    short_ver="$(extract_version_number "$raw_ver")"
    [[ -z "$short_ver" ]] && short_ver="n/a"
    PKG_MGR_VERSIONS+=("$short_ver")
    PKG_MGR_SEEN["$id"]=1
  fi
}

detect_all_pkg_managers() {
  detect_pkg_manager "pacman" "Pacman (Arch)" "pacman -V"
  detect_pkg_manager "apt" "APT (Debian/Ubuntu)" "apt --version"
  if command_exists dnf; then
    detect_pkg_manager "dnf" "DNF (Fedora/RHEL)" "dnf --version"
  elif command_exists yum; then
    detect_pkg_manager "yum" "YUM (Old RHEL)" "yum --version"
  fi
  detect_pkg_manager "zypper" "Zypper (openSUSE)" "zypper --version"
}

print_pkg_managers() {
  echo "Detected package managers:"
  for i in "${!PKG_MGR_IDS[@]}"; do
    echo "  [$((i+1))] ${PKG_MGR_LABELS[$i]} (${PKG_MGR_VERSIONS[$i]})"
  done
  echo "  [A] All"
}

show_managers() {
  detect_all_pkg_managers
  if (( ${#PKG_MGR_IDS[@]} == 0 )); then
    echo "No supported package managers detected."
  else
    print_pkg_managers
  fi
}

if (( SHOW_MANAGERS )); then
  show_managers
  exit 0
fi

ensure_orphan_manager_selected() {
  (( SHOW_ONLY_ORPHANS )) || return 0
  local pacman_selected=0
  for pm in "${SELECTED_PKG_MGRS[@]:-}"; do
    if [[ "$pm" == "pacman" ]]; then
      pacman_selected=1
      break
    fi
  done
  if (( ! pacman_selected )); then
    log_error "--orphans-only requires selecting pacman via --managers"
    exit 1
  fi
}

select_pkg_managers() {
  (( ! INCLUDE_REPO && ! INCLUDE_AUR )) && return

  SELECTED_PKG_MGRS=()
  detect_all_pkg_managers
  if ! command_exists pacman; then
    INCLUDE_AUR=0
  fi
  if (( ${#PKG_MGR_IDS[@]} == 0 )); then
    INCLUDE_REPO=0
    INCLUDE_AUR=0
    return
  fi

  if [[ -n "$MANAGERS_ARG" ]]; then
    local lower idx req
    local -a requested=()
    lower="${MANAGERS_ARG,,}"
    if [[ "$lower" == "all" ]]; then
      SELECTED_PKG_MGRS=("${PKG_MGR_IDS[@]}")
      return
    fi
    local IFS=','
    read -ra requested <<< "$lower"
    for req in "${requested[@]}"; do
      req="$(trim_whitespace "$req")"
      [[ -z "$req" ]] && continue
      for idx in "${!PKG_MGR_IDS[@]}"; do
        if [[ "${PKG_MGR_IDS[$idx]}" == "$req" ]]; then
          SELECTED_PKG_MGRS+=("${PKG_MGR_IDS[$idx]}")
          break
        fi
      done
    done
    (( ${#SELECTED_PKG_MGRS[@]} == 0 )) && { log_error "No valid managers specified via --managers"; exit 1; }
    return
  fi

  if (( ${#PKG_MGR_IDS[@]} == 1 )); then
    SELECTED_PKG_MGRS=("${PKG_MGR_IDS[0]}")
    return
  fi

  if (( QUIET )) || [[ ! -t 0 ]]; then
    SELECTED_PKG_MGRS=("${PKG_MGR_IDS[@]}")
    return
  fi

  echo
  print_pkg_managers
  read -rp "Select managers (e.g. 1 3 or A for all) [A]: " choice
  choice="${choice:-A}"
  choice="${choice^^}"

  if [[ "$choice" == "A" ]]; then
    SELECTED_PKG_MGRS=("${PKG_MGR_IDS[@]}")
    return
  fi

  # Intentional splitting: allow selections like "1 3" or "2 A" in a single response
  for token in $choice; do
    if [[ "$token" =~ ^[0-9]+$ ]]; then
      local idx=$((token - 1))
      if (( idx >= 0 && idx < ${#PKG_MGR_IDS[@]} )); then
        SELECTED_PKG_MGRS+=("${PKG_MGR_IDS[$idx]}")
      fi
    fi
  done

  (( ${#SELECTED_PKG_MGRS[@]} == 0 )) && { log_error "No valid managers selected"; exit 1; }
}

# ---------- Main scanning ----------
if (( SHOW_ONLY_ORPHANS )); then
  ensure_orphan_sources_available
fi

if (( INCLUDE_REPO || INCLUDE_AUR )); then
  maybe_run_interactive_menu
  if (( MENU_CONFIRMED )); then
    show_pre_scan_loading
    MENU_CONFIRMED=0
  fi
  ensure_orphan_sources_available
  select_pkg_managers
  if (( (INCLUDE_REPO || INCLUDE_AUR) && ${#PKG_MGR_IDS[@]} == 0 )); then
    log_warn "Repo/AUR sources selected, but no package managers detected; disabling repo sources."
    INCLUDE_REPO=0
    INCLUDE_AUR=0
  fi
  if (( INCLUDE_REPO || INCLUDE_AUR )); then
    ensure_orphan_manager_selected
  fi
else
  if (( SHOW_ONLY_ORPHANS )); then
    log_error "--orphans-only requires pacman repo or AUR sources"
    exit 1
  fi
  SELECTED_PKG_MGRS=()
fi

if (( INCLUDE_REPO || INCLUDE_AUR )); then
  for pm in "${SELECTED_PKG_MGRS[@]}"; do
    case "$pm" in
      pacman) run_step "Pacman packages" gather_pacman_repo_and_aur ;;
      apt)    run_step "APT packages" gather_apt_repo ;;
      dnf)    run_step "DNF packages" gather_dnf_repo ;;
      yum)    run_step "YUM packages" gather_dnf_repo ;;
      zypper) run_step "Zypper packages" gather_zypper_repo ;;
    esac
  done
fi

if (( INCLUDE_FLATPAK )); then
  run_step "Flatpak apps" gather_flatpak
fi
if (( INCLUDE_SNAP )); then
  run_step "Snap apps" gather_snap
fi
if (( INCLUDE_APPIMAGE )); then
  run_step "AppImages" gather_appimages
fi
if (( INCLUDE_LOCAL )); then
  run_step "Local binaries" gather_local_binaries
fi
if (( INCLUDE_PIP )); then
  run_step "Python packages" gather_pip_global
fi
if (( INCLUDE_DOCKER )); then
  run_step "Docker images/containers" gather_docker
fi
if (( INCLUDE_PODMAN )); then
  run_step "Podman images/containers" gather_podman
fi
if (( INCLUDE_OLLAMA )); then
  run_step "Ollama models" gather_ollama
fi
if (( INCLUDE_NIX )); then
  run_step "Nix packages" gather_nix_packages
fi
if (( INCLUDE_CARGO )); then
  run_step "Cargo binaries" gather_cargo_global
fi
if (( INCLUDE_NPM )); then
  run_step "npm global packages" gather_npm_global
fi
if (( INCLUDE_BREW )); then
  run_step "Homebrew packages" gather_brew_packages
fi
if (( INCLUDE_GO )); then
  run_step "Go binaries" gather_go_binaries
fi
if (( INCLUDE_PIPX )); then
  run_step "pipx apps" gather_pipx_apps
fi
if (( INCLUDE_SYSTEMD_USER )); then
  run_step "systemd user services" gather_systemd_user_services
fi

# ---------- Sort ----------
{
  head -n1 "$TMPFILE"
  tail -n +2 "$TMPFILE" | awk -F'\t' -v OFS=$'\t' '
    function rank(type) { return (type == "Repo") ? 1 : 2 }
    {
      src=$3
      gsub(/[[:space:]]+$/, "", src)
      print rank($2), tolower(src), $1, $0
    }
  ' | LC_ALL=C sort -t$'\t' -k1,1n -k2,2 -k4,4 | cut -f4-
} > "$TSV_FILE"

TOTAL=$(tail -n +2 "$TSV_FILE" | wc -l | awk '{print $1}')
if ! ORPHANED_COUNT=$(tail -n +2 "$TSV_FILE" | cut -f7 | grep -c "^yes$" 2>/dev/null); then
  ORPHANED_COUNT=0
fi

# Rebuild TYPE_COUNTS from final TSV (not from during-scan counts)
declare -A TYPE_COUNTS=()
declare -A ORPHAN_COUNTS=()
while IFS=$'\t' read -r name type source details version size orphaned; do
  TYPE_COUNTS["$type"]=$(( ${TYPE_COUNTS["$type"]:-0} + 1 ))
  if [[ "$orphaned" == "yes" ]]; then
    ORPHAN_COUNTS["$type"]=$(( ${ORPHAN_COUNTS["$type"]:-0} + 1 ))
  fi
done < <(tail -n +2 "$TSV_FILE")

SCAN_DURATION=$(( $(date +%s) - SCAN_START_TIME ))

# ---------- Output formatting ----------
convert_to_csv() {
  if ! command_exists python3; then
    log_error "python3 is required for CSV output"
    return 1
  fi

  local tsv_path="$TSV_FILE"

  # Use Python's csv module for RFC-compliant CSV
  python3 - "$tsv_path" > "$OUTFILE" <<'PY3'
import csv, sys
tsv_path = sys.argv[1]
with open(tsv_path, newline='') as tsv_file:
    reader = csv.reader(tsv_file, delimiter='\t')
    writer = csv.writer(sys.stdout)
    for row in reader:
        writer.writerow(row)
PY3
}

convert_to_json() {
  if ! command_exists python3; then
    log_error "python3 is required for JSON output"
    return 1
  fi

  local tsv_path="$TSV_FILE"

  {
    echo '{"packages":['
    python3 - "$tsv_path" << 'PYEOF'
import csv, json, sys
tsv_path = sys.argv[1]

with open(tsv_path, newline="") as f:
    reader = csv.reader(f, delimiter="\t")
    # skip header row
    next(reader, None)
    first = True
    for row in reader:
        if len(row) < 7:
            continue
        name, typ, source, details, ver, size, orph = row
        obj = {
            "name": name,
            "type": typ,
            "source": source,
            "details": details,
            "version": ver,
            "size": size,
            "orphaned": (orph == "yes")
        }
        if not first:
            sys.stdout.write(",")
        first = False
        sys.stdout.write(json.dumps(obj))
PYEOF
    echo ']}'
  } > "$OUTFILE"
}

write_output_file() {
  local target="$1"
  case "$OUTPUT_FORMAT" in
    tsv)
      if ! cp "$TSV_FILE" "$target"; then
        return 1
      fi
      ;;
    csv)
      local backup="$OUTFILE"
      OUTFILE="$target"
      if ! convert_to_csv; then
        OUTFILE="$backup"
        return 1
      fi
      OUTFILE="$backup"
      ;;
    json)
      local backup="$OUTFILE"
      OUTFILE="$target"
      if ! convert_to_json; then
        OUTFILE="$backup"
        return 1
      fi
      OUTFILE="$backup"
      ;;
    *) log_error "Unknown output format: $OUTPUT_FORMAT"; return 1 ;;
  esac
}

SYSTEM_HOST_INFO=""
SYSTEM_CPU_INFO=""
SYSTEM_RAM_INFO=""
SYSTEM_TIME_INFO=""
SYSTEM_GPU_INFO=""
SYSTEM_USER_INFO=""
SYSTEM_UPTIME_INFO=""

collect_system_info() {
  local host kernel
  if command_exists hostnamectl; then
    host="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || uname -n 2>/dev/null || echo "unknown")"
  else
    host="$(hostname 2>/dev/null || uname -n 2>/dev/null || echo "unknown")"
  fi
  kernel="$(uname -sr 2>/dev/null || echo "unknown")"
  SYSTEM_HOST_INFO="${host} (${kernel})"

  local current_user="${USER:-}"
  [[ -z "$current_user" ]] && current_user="$(whoami 2>/dev/null || echo "unknown")"
  SYSTEM_USER_INFO="$current_user"

  local cpu_model=""
  if command_exists lscpu; then
    cpu_model="$(LC_ALL=C lscpu | awk -F: '/^Model name:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}')"
  fi
  if [[ -z "$cpu_model" && -r /proc/cpuinfo ]]; then
    cpu_model="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^[[:space:]]*//')" || true
  fi
  [[ -z "$cpu_model" ]] && cpu_model="Unknown CPU"

  local sockets cores_per_socket threads_per_core total_cpus physical_cores thread_count
  if command_exists lscpu; then
    sockets="$(LC_ALL=C lscpu | awk -F':' '/^Socket\(s\):/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    cores_per_socket="$(LC_ALL=C lscpu | awk -F':' '/^Core\(s\) per socket:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    threads_per_core="$(LC_ALL=C lscpu | awk -F':' '/^Thread\(s\) per core:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    total_cpus="$(LC_ALL=C lscpu | awk -F':' '/^CPU\(s\):/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
  fi
  if [[ -n "$cores_per_socket" && -n "$sockets" ]]; then
    physical_cores=$(( cores_per_socket * sockets ))
  elif [[ -n "$total_cpus" && -n "$threads_per_core" && "$threads_per_core" -ne 0 ]]; then
    physical_cores=$(( total_cpus / threads_per_core ))
  fi
  thread_count="$(nproc 2>/dev/null || true)"
  if [[ -z "$thread_count" && -r /proc/cpuinfo ]]; then
    thread_count="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
  fi
  [[ -z "$thread_count" ]] && thread_count="?"
  if [[ -z "$physical_cores" ]]; then
    if [[ "$thread_count" =~ ^[0-9]+$ ]]; then
      physical_cores="$thread_count"
    else
      physical_cores="?"
    fi
  fi
  local cpu_label="$cpu_model"
  if [[ -n "$sockets" && "$sockets" -gt 1 ]]; then
    cpu_label+=" x${sockets}"
  fi
  SYSTEM_CPU_INFO="${cpu_label} (${physical_cores}c/${thread_count}t)"

  local -a gpu_entries=()
  if command_exists lspci; then
    while IFS= read -r line; do
      line="${line#*: }"
      gpu_entries+=("$line")
    done < <(LC_ALL=C lspci | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)
  fi
  if (( ${#gpu_entries[@]} == 0 )) && command_exists nvidia-smi; then
    while IFS= read -r gpu_line; do
      [[ -z "$gpu_line" ]] && continue
      gpu_entries+=("$gpu_line (nvidia-smi)")
    done < <(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || true)
  fi
  (( ${#gpu_entries[@]} == 0 )) && gpu_entries+=("Unknown GPU")
  SYSTEM_GPU_INFO="$(IFS=', '; echo "${gpu_entries[*]}")"

  local ram_bytes=""
  if command_exists free; then
    ram_bytes="$(LC_ALL=C free -b 2>/dev/null | awk '/^Mem:/ {print $2; exit}')"
  fi
  if [[ -z "$ram_bytes" && -r /proc/meminfo ]]; then
    local mem_kb
    mem_kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
    if [[ -n "$mem_kb" ]]; then
      ram_bytes=$(( mem_kb * 1024 ))
    fi
  fi
  if [[ -n "$ram_bytes" ]]; then
    SYSTEM_RAM_INFO="$(awk -v bytes="$ram_bytes" 'BEGIN {printf "%.2f GB", bytes/1000000000}')"
  else
    SYSTEM_RAM_INFO="Unknown RAM"
  fi

  if command_exists uptime; then
    SYSTEM_UPTIME_INFO="$(uptime -p 2>/dev/null || true)"
    SYSTEM_UPTIME_INFO="${SYSTEM_UPTIME_INFO#up }"
    SYSTEM_UPTIME_INFO="${SYSTEM_UPTIME_INFO:-unknown}"
  fi
  if [[ -z "$SYSTEM_UPTIME_INFO" || "$SYSTEM_UPTIME_INFO" == "unknown" ]]; then
    if [[ -r /proc/uptime ]]; then
      local total_seconds
      total_seconds="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "")"
      if [[ -n "$total_seconds" ]]; then
        local days=$((total_seconds / 86400))
        local hours=$(((total_seconds % 86400) / 3600))
        local minutes=$(((total_seconds % 3600) / 60))
        local -a up_parts=()
        (( days > 0 )) && up_parts+=("${days}d")
        (( hours > 0 )) && up_parts+=("${hours}h")
        (( minutes > 0 )) && up_parts+=("${minutes}m")
        SYSTEM_UPTIME_INFO="${up_parts[*]:-0m}"
      fi
    fi
  fi
  [[ -z "$SYSTEM_UPTIME_INFO" ]] && SYSTEM_UPTIME_INFO="unknown"

  SYSTEM_TIME_INFO="$(date '+%Y-%m-%d %I:%M:%S %P' 2>/dev/null || date)"
  return 0
}

build_source_counts_line() {
  local -a entries=()
  add_count_entry() {
    local label="$1" type_key="$2" include_flag="$3" orphan_capable="$4"
    (( include_flag )) || return 0
    local count=${TYPE_COUNTS["$type_key"]:-0}
    local color="${TYPE_COLOR_MAP[$type_key]:-$RESET}"
    local entry="${label}: ${color}${count}${RESET}"
    if (( orphan_capable )); then
      local ocount=${ORPHAN_COUNTS["$type_key"]:-0}
      if (( ocount > 0 )); then
        entry+="(${ORPHAN_COLOR}${ocount}${RESET})"
      fi
    fi
    entries+=("$entry")
  }

  add_count_entry "Repo" "Repo" "$INCLUDE_REPO" 1
  add_count_entry "$FOREIGN_TYPE_LABEL" "$FOREIGN_TYPE_LABEL" "$INCLUDE_AUR" 1
  add_count_entry "Flatpak" "Flatpak" "$INCLUDE_FLATPAK" 0
  add_count_entry "Snap" "Snap" "$INCLUDE_SNAP" 0
  add_count_entry "AppImage" "AppImage" "$INCLUDE_APPIMAGE" 0
  add_count_entry "Local" "Local Binary" "$INCLUDE_LOCAL" 0
  add_count_entry "Pip" "Python Package" "$INCLUDE_PIP" 0
  add_count_entry "Container Images" "Container Image" "$(( INCLUDE_DOCKER || INCLUDE_PODMAN ))" 0
  add_count_entry "Containers" "Container" "$(( INCLUDE_DOCKER || INCLUDE_PODMAN ))" 0
  add_count_entry "LLMs" "Ollama Model" "$INCLUDE_OLLAMA" 0
  add_count_entry "Nix" "Nix Package" "$INCLUDE_NIX" 0
  add_count_entry "Cargo" "Rust Binary" "$INCLUDE_CARGO" 0
  add_count_entry "npm" "Node Package" "$INCLUDE_NPM" 0
  add_count_entry "Brew" "Homebrew Package" "$INCLUDE_BREW" 0
  add_count_entry "Go" "Go Binary" "$INCLUDE_GO" 0
  add_count_entry "Pipx" "Pipx Package" "$INCLUDE_PIPX" 0
  add_count_entry "systemd" "User Service" "$INCLUDE_SYSTEMD_USER" 0

  if (( ${#entries[@]} > 0 )); then
    local output=""
    for entry in "${entries[@]}"; do
      [[ -n "$output" ]] && output+=" | "
      output+="$entry"
    done
    printf '%s' "$output"
  fi
}

print_run_summary() {
  echo -e "\n${BOLD}=== Scan Summary ===${RESET}"
  collect_system_info || true
  printf 'User: %s\n' "${SYSTEM_USER_INFO:-unknown}"
  printf 'Host: %s\n' "${SYSTEM_HOST_INFO:-unknown}"
  printf 'CPU : %s\n' "${SYSTEM_CPU_INFO:-unknown}"
  printf 'GPU : %s\n' "${SYSTEM_GPU_INFO:-unknown}"
  printf 'RAM : %s\n' "${SYSTEM_RAM_INFO:-unknown}"
  printf 'Uptime: %s\n' "${SYSTEM_UPTIME_INFO:-unknown}"
  printf 'Time: %s\n' "${SYSTEM_TIME_INFO:-unknown}"
  local summary_mode
  if (( INCLUDE_ALL_PACKAGES )); then
    summary_mode="${GREEN}Everything${RESET}"
  else
    summary_mode="${CYAN}Apps only${RESET}"
  fi
  printf 'Mode: %s\n' "$summary_mode"
  local filter_txt="Off"
  (( SHOW_ONLY_ORPHANS )) && filter_txt="${YELLOW}On${RESET}"
  printf 'Orphans-only: %s\n' "$filter_txt"
  local duration_formatted
  duration_formatted=$(format_duration "$SCAN_DURATION")
  printf 'Scan time: %s\n' "$duration_formatted"
  echo
  local counts_line
  counts_line="$(build_source_counts_line)"
  if [[ -n "$counts_line" ]]; then
    echo "$counts_line"
  else
    echo "No sources scanned."
  fi
  printf 'Total: %s%s%s\n' "$TOTAL_COLOR" "$TOTAL" "$RESET"
  printf 'Orphans: %s%s%s\n' "$ORPHAN_SUMMARY_COLOR" "$ORPHANED_COUNT" "$RESET"
}

print_save_destination() {
  if [[ -n "$OUTPUT_SAVED_PATH" ]]; then
    echo -e "${BOLD}Saved to:${RESET} $OUTPUT_SAVED_PATH"
  else
    echo -e "${BOLD}Saved to:${RESET} (not saved; displayed above)"
  fi
}

save_primary_output() {
  OUTPUT_SAVED_PATH=""
  [[ -z "$OUTFILE" ]] && return

  local alt_ext fallback_path
  if ! write_output_file "$OUTFILE"; then
    alt_ext="$OUTPUT_FORMAT"
    if [[ "$alt_ext" != "tsv" && "$alt_ext" != "csv" && "$alt_ext" != "json" ]]; then
      alt_ext="tsv"
    fi
    fallback_path="$(mktemp "${TMPDIR:-/tmp}/app-inventory.XXXXXX.$alt_ext")"
    log_warn "Failed to write to $OUTFILE; using fallback $fallback_path"
    OUTFILE="$fallback_path"
    write_output_file "$OUTFILE" || { log_error "Could not write output to $OUTFILE"; exit 1; }
  fi
  OUTPUT_SAVED_PATH="$OUTFILE"
}

save_primary_output

maybe_offer_manual_save() {
  [[ -z "$OUTPUT_SAVED_PATH" ]] || return 0
  [[ ! -t 0 || "$NON_INTERACTIVE" -eq 1 ]] && return

  echo
  read -rp "Save this output to a file? [y/N]: " save_answer
  save_answer="${save_answer^^}"
  [[ "$save_answer" == "Y" ]] || return 0

  local format_choice target_format default_ext
  while true; do
    read -rp "Choose format [T]SV/[C]SV/[J]SON [T]: " format_choice
    format_choice="${format_choice^^}"
    [[ -z "$format_choice" ]] && format_choice="T"
    case "$format_choice" in
      T) target_format="tsv"; default_ext="tsv"; break ;;
      C) target_format="csv"; default_ext="csv"; break ;;
      J) target_format="json"; default_ext="json"; break ;;
      *) echo "Invalid choice. Enter T, C, or J." ;;
    esac
  done

  local default_path="${DEFAULT_OUTPUT_BASENAME}.${default_ext}"
  local target_path=""
  read -rp "Save path [$default_path]: " target_path
  [[ -z "$target_path" ]] && target_path="$default_path"
  mkdir -p "$(dirname "$target_path")" 2>/dev/null || true

  local old_format="$OUTPUT_FORMAT"
  local old_outfile="$OUTFILE"
  OUTPUT_FORMAT="$target_format"
  OUTFILE="$target_path"

  if write_output_file "$OUTFILE"; then
    OUTPUT_SAVED_PATH="$OUTFILE"
    echo "Saved to: $OUTPUT_SAVED_PATH"
  else
    log_error "Failed to save output to $OUTFILE"
  fi

  OUTPUT_FORMAT="$old_format"
  OUTFILE="$old_outfile"
}

# ---------- Diff (TSV only) ----------
if [[ -n "${DIFF_FILE:-}" ]]; then
  if [[ "$OUTPUT_FORMAT" != "tsv" ]]; then
    log_info "Diff mode only available in TSV output format"
  else
    log_info "Computing differences from $DIFF_FILE..."
    echo
    echo "=== Added packages (by name) ==="
    comm -13 <(tail -n +2 "$DIFF_FILE" | cut -f1 | LC_ALL=C sort) \
             <(tail -n +2 "$TSV_FILE"   | cut -f1 | LC_ALL=C sort) | \
      sed 's/^/+ /'
    echo
    echo "=== Removed packages (by name) ==="
    comm -23 <(tail -n +2 "$DIFF_FILE" | cut -f1 | LC_ALL=C sort) \
             <(tail -n +2 "$TSV_FILE"   | cut -f1 | LC_ALL=C sort) | \
      sed 's/^/- /'
  fi
fi

# ---------- Empty results check ----------
if (( TOTAL == 0 )); then
  log_warn "No packages found after filtering"
fi

# ---------- Table display ----------
print_aligned_line() {
  local display_name="$1"
  local plain_name="$2"
  local widths_name="$3"
  local spacing="${4:-2}"

  local -n _display_ref="$display_name"
  local -n _plain_ref="$plain_name"
  local -n _widths_ref="$widths_name"

  local last_index=$(( ${#_display_ref[@]} - 1 ))
  local idx
  for idx in "${!_display_ref[@]}"; do
    local pad=0
    local printable="${_plain_ref[idx]:-}"
    local target_width="${_widths_ref[idx]:-0}"
    local printable_len=${#printable}
    (( target_width > printable_len )) && pad=$(( target_width - printable_len ))
    if (( idx == last_index )); then
      printf '%s\n' "${_display_ref[idx]}"
    else
      printf '%s%*s' "${_display_ref[idx]}" $((pad + spacing)) ""
    fi
  done
}

render_aligned_table() {
  local header_plain_name="$1"
  local header_display_name="$2"
  local plain_rows_name="$3"
  local display_rows_name="$4"
  local spacing="${5:-2}"

  local -n _header_plain_ref="$header_plain_name"
  local -n _header_display_ref="$header_display_name"
  local -n _plain_rows_ref="$plain_rows_name"
  local -n _display_rows_ref="$display_rows_name"

  local -a widths=()
  local idx
  for idx in "${!_header_plain_ref[@]}"; do
    widths[idx]=${#_header_plain_ref[idx]}
  done

  local row
  for row in "${_plain_rows_ref[@]}"; do
    IFS=$'\t' read -r -a plain_fields <<< "$row" || continue
    for idx in "${!plain_fields[@]}"; do
      local len=${#plain_fields[idx]}
      (( len > widths[idx] )) && widths[idx]=$len
    done
  done

  print_aligned_line "$header_display_name" "$header_plain_name" widths "$spacing"

  for idx in "${!_display_rows_ref[@]}"; do
    # shellcheck disable=SC2034
    IFS=$'\t' read -r -a display_fields <<< "${_display_rows_ref[idx]}" || continue
    IFS=$'\t' read -r -a plain_fields <<< "${_plain_rows_ref[idx]}" || continue
    print_aligned_line display_fields plain_fields widths "$spacing"
  done
}

print_table() {
  echo -e "\n${BOLD}=== Installed Applications ===${RESET}\n"
  [[ -s "$TSV_FILE" ]] || return 0

  local header_line
  IFS= read -r header_line < "$TSV_FILE" || return 0
  IFS=$'\t' read -r -a header_plain <<< "$header_line"

  local -a header_display=()
  for field in "${header_plain[@]}"; do
    header_display+=("${CYAN}${field}${RESET}")
  done

  local -a plain_rows=()
  local -a display_rows=()

  while IFS=$'\t' read -r n t s d v sz o; do
    [[ -z "$n" ]] && continue
    local detail_view
    # Keep plain and display widths in sync to preserve column alignment
    detail_view=$(truncate_field "$d" "$DETAIL_MAX_DISPLAY")
    local display_name_trunc
    display_name_trunc=$(truncate_field "$n" "$NAME_MAX_DISPLAY")

    local plain_row="$n"$'\t'"$t"$'\t'"$s"$'\t'"$detail_view"$'\t'"$v"$'\t'"$sz"$'\t'"$o"
    plain_rows+=("$plain_row")

    local type_color="${TYPE_COLOR_MAP[$t]:-$RESET}"
    local name_display="$display_name_trunc"
    local orphan_display="$o"
    if [[ "$o" == "yes" ]]; then
      name_display="${ORPHAN_SUMMARY_COLOR}${display_name_trunc}${RESET}"
      orphan_display="${RED}${o}${RESET}"
    fi
    local display_row="$name_display"$'\t'"${type_color}${t}${RESET}"$'\t'"$s"$'\t'"$detail_view"$'\t'"$v"$'\t'"$sz"$'\t'"$orphan_display"
    display_rows+=("$display_row")
  done < <(tail -n +2 "$TSV_FILE")

  render_aligned_table header_plain header_display plain_rows display_rows 2
}

if [[ "$OUTPUT_FORMAT" == "tsv" && -t 1 ]]; then
  print_table
fi

print_orphan_section() {
  local -a plain_rows=()
  local -a display_rows=()
  while IFS=$'\t' read -r n t s d v sz o; do
    [[ "$o" != "yes" ]] && continue
    local detail_view
    detail_view=$(truncate_field "$d" "$DETAIL_MAX_DISPLAY")
    local display_name_trunc
    display_name_trunc=$(truncate_field "$n" "$NAME_MAX_DISPLAY")
    local type_color="${TYPE_COLOR_MAP[$t]:-$RESET}"
    plain_rows+=("$n"$'\t'"$t"$'\t'"$s"$'\t'"$detail_view"$'\t'"$v"$'\t'"$sz")
    display_rows+=("${ORPHAN_SUMMARY_COLOR}${display_name_trunc}${RESET}"$'\t'"${type_color}${t}${RESET}"$'\t'"$s"$'\t'"$detail_view"$'\t'"$v"$'\t'"$sz")
  done < <(tail -n +2 "$TSV_FILE")

  (( ${#plain_rows[@]} )) || return 0

  echo -e "\n${BOLD}--- Orphaned Packages ---${RESET}\n"
  local header_plain=("Name" "Type" "Source" "Details" "Version" "Size")
  local header_display=(
    "${CYAN}Name${RESET}"
    "${CYAN}Type${RESET}"
    "${CYAN}Source${RESET}"
    "${CYAN}Details${RESET}"
    "${CYAN}Version${RESET}"
    "${CYAN}Size${RESET}"
  )
  render_aligned_table header_plain header_display plain_rows display_rows 2
}

# ---------- Summary ----------
print_run_summary
print_orphan_section
maybe_offer_manual_save
print_save_destination
log_success "Scan completed successfully"
exit 0
