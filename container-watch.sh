# container-watch.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPO_ROOT="$(pwd)"
LOCK_FILE="/tmp/container-watch.lock"

FORCE_ALL=false
FORCE_RUN=false
CHECK_IMAGES=false
PRUNE_IMAGES=false
QUIET=false

CONFIG_FILE="container-watch.conf"

IGNORE_IMAGES=()
IGNORE_PROJECTS=()

show_help() {
  cat <<EOF
Usage:
  ./container-watch.sh [options]

Options:
  -q, --quiet
  -f, --force-run
  -a, --force-all
  -i, --check-images
  -p, --prune-images
  -c, --config FILE
  --ignore-images IMG...
  --ignore-project PROJ...
  -h, --help
EOF
}

log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[DONE]${NC} $*"
}

check_dependencies() {
  local deps=("git" "docker" "flock" "jq")

  for dep in "${deps[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      log_error "Missing dependency: $dep"
      exit 1
    fi
  done

  if ! docker compose version >/dev/null 2>&1; then
    log_error "Docker Compose plugin not available"
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|--quiet)
      QUIET=true
      shift
      ;;

    -f|--force-run)
      FORCE_RUN=true
      shift
      ;;

    -a|--force-all)
      FORCE_ALL=true
      shift
      ;;

    -i|--check-images)
      CHECK_IMAGES=true
      shift
      ;;

    -p|--prune-images)
      PRUNE_IMAGES=true
      shift
      ;;

    -c|--config)
      shift
      CONFIG_FILE="$1"
      shift
      ;;

    --ignore-images)
      shift
      while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
        IGNORE_IMAGES+=("$1")
        shift
      done
      ;;

    --ignore-project)
      shift
      while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
        IGNORE_PROJECTS+=("$1")
        shift
      done
      ;;

    -h|--help)
      show_help
      exit 0
      ;;

    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

acquire_lock() {
  exec 200>"$LOCK_FILE"

  if [[ "$FORCE_RUN" == true ]]; then
    log_warn "Bypassing lock"
    return
  fi

  if ! flock -n 200; then
    log_error "Another instance is already running"
    exit 1
  fi
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    if [[ ! -r "$CONFIG_FILE" ]]; then
      log_error "Cannot read config file"
      exit 1
    fi

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  else
    log_warn "Config file not found"
  fi
}

sync_git() {
  git fetch origin

  local upstream
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null || true)"

  if [[ -z "$upstream" ]]; then
    log_error "No upstream tracking branch"
    exit 1
  fi

  git reset --hard "$upstream"
}

array_contains() {
  local seeking="$1"
  shift

  local item

  for item in "$@"; do
    [[ "$item" == "$seeking" ]] && return 0
  done

  return 1
}

load_project_env_options() {
  local compose_dir="$1"

  COMPOSE_DOWN_OPTIONS=()
  COMPOSE_UP_OPTIONS=()

  local env_file="$compose_dir/.env"

  if [[ ! -f "$env_file" ]]; then
    return
  fi

  local down_opts
  local up_opts

  down_opts="$(grep '^CW_COMPOSE_DOWN_OPTIONS=' "$env_file" | cut -d '=' -f2- || true)"
  up_opts="$(grep '^CW_COMPOSE_UP_OPTIONS=' "$env_file" | cut -d '=' -f2- || true)"

  if [[ -n "$down_opts" ]]; then
    read -r -a COMPOSE_DOWN_OPTIONS <<< "$down_opts"
  fi

  if [[ -n "$up_opts" ]]; then
    read -r -a COMPOSE_UP_OPTIONS <<< "$up_opts"
  fi
}

discover_projects() {
  find . -type f \( \
    -name "docker-compose.yml" -o \
    -name "docker-compose.yaml" -o \
    -name "compose.yml" -o \
    -name "compose.yaml" \
  \)
}

get_changed_projects() {
  local changed_files
  changed_files="$(git diff --name-only HEAD@{1} HEAD || true)"

  local changed_projects=()

  while read -r file; do
    [[ -z "$file" ]] && continue

    local dir
    dir="$(dirname "$file")"

    changed_projects+=("$dir")
  done <<< "$changed_files"

  printf '%s\n' "${changed_projects[@]}" | sort -u
}

project_running() {
  local compose_file="$1"

  docker compose -f "$compose_file" ps --status running 2>/dev/null | grep -q .
}

verify_health() {
  local compose_file="$1"

  local unhealthy

  unhealthy=$(
    docker compose -f "$compose_file" ps --format json 2>/dev/null | \
      jq -r '.[] | select(.Health == "unhealthy") | .Name' || true
  )

  if [[ -n "$unhealthy" ]]; then
    log_error "Unhealthy containers detected"
    echo "$unhealthy"
    return 1
  fi

  return 0
}

redeploy_project() {
  local compose_file="$1"
  local project_name="$2"

  local compose_dir
  compose_dir="$(dirname "$compose_file")"

  load_project_env_options "$compose_dir"

  log_info "Updating project: $project_name"

  (
    cd "$compose_dir"

    if ! docker compose pull; then
      log_error "Image pull failed"
      exit 1
    fi

    if [[ ${#COMPOSE_DOWN_OPTIONS[@]} -gt 0 ]]; then
      docker compose down "${COMPOSE_DOWN_OPTIONS[@]}"
    fi

    docker compose up -d \
      --remove-orphans \
      --pull always \
      "${COMPOSE_UP_OPTIONS[@]}"

    sleep 5

    if ! verify_health "$compose_file"; then
      log_error "Health verification failed"
      exit 1
    fi
  )

  log_success "Updated $project_name"
}

check_images() {
  log_info "Checking image consistency"

  while read -r compose_file; do
    local dir
    dir="$(dirname "$compose_file")"

    local project_name
    project_name="$(basename "$dir")"

    if array_contains "$project_name" "${IGNORE_PROJECTS[@]}"; then
      continue
    fi

    if ! project_running "$compose_file"; then
      continue
    fi

    local services
    services="$(docker compose -f "$compose_file" config --services)"

    while read -r svc; do
      [[ -z "$svc" ]] && continue

      local cid
      cid="$(docker compose -f "$compose_file" ps -q "$svc")"

      [[ -z "$cid" ]] && continue

      local expected
      expected="$(docker compose -f "$compose_file" config | awk -v svc="$svc" '
        $1 == svc ":" {found=1; next}
        found && $1 == "image:" {print $2; exit}
      ')"

      [[ -z "$expected" ]] && continue

      if array_contains "$expected" "${IGNORE_IMAGES[@]}"; then
        continue
      fi

      local actual
      actual="$(docker inspect --format '{{.Config.Image}}' "$cid")"

      if [[ "$expected" != "$actual" ]]; then
        echo -e "${RED}[MISMATCH]${NC} $svc"
        echo "expected: $expected"
        echo "actual:   $actual"

        if [[ "$QUIET" == true ]]; then
          redeploy_project "$compose_file" "$project_name"
        else
          read -rp "Redeploy project $project_name? [y/N] " yn

          case "$yn" in
            [Yy]*)
              redeploy_project "$compose_file" "$project_name"
              ;;
          esac
        fi

        break
      fi
    done <<< "$services"
  done < <(discover_projects)
}

main_update_flow() {
  local changed_projects=()

  if [[ "$FORCE_ALL" == false ]]; then
    mapfile -t changed_projects < <(get_changed_projects)

    if [[ ${#changed_projects[@]} -eq 0 ]]; then
      log_info "No changed compose projects detected"
      return
    fi
  fi

  local updated_any=false

  while read -r compose_file; do
    local dir
    dir="$(dirname "$compose_file")"

    local project_name
    project_name="$(basename "$dir")"

    if array_contains "$project_name" "${IGNORE_PROJECTS[@]}"; then
      continue
    fi

    if ! project_running "$compose_file"; then
      continue
    fi

    local should_update=false

    if [[ "$FORCE_ALL" == true ]]; then
      should_update=true
    else
      local changed

      for changed in "${changed_projects[@]}"; do
        if [[ "$changed" == "$dir" ]]; then
          should_update=true
          break
        fi
      done
    fi

    if [[ "$should_update" == true ]]; then
      redeploy_project "$compose_file" "$project_name"
      updated_any=true
    fi
  done < <(discover_projects)

  if [[ "$updated_any" == false ]]; then
    log_info "No services updated"
  fi
}

prune_images() {
  docker image prune -f
}

check_dependencies
acquire_lock
load_config
sync_git

main_update_flow

if [[ "$CHECK_IMAGES" == true ]]; then
  check_images
fi

if [[ "$PRUNE_IMAGES" == true ]]; then
  prune_images
fi

log_success "Completed successfully"
