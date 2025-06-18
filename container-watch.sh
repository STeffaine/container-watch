#!/bin/bash

# Auto-deploy and image-check for Docker Compose projects
# - Only restarts services where docker-compose.yml has changed
# - Only restarts if the project is already running
# - Optional: force update all currently running projects with --force-all
# - Optional: check-image consistency with --check-images (with colored output)
# - Optional: Ignore specific image(s) with --ignore-images
# - Optional: Ignore specific project(s) with --ignore-project
# - Optional: Prune images with --prune-images

set -u  # Abort on unset vars

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

REPO_ROOT="$(pwd)"
FORCE_ALL=false
FORCE_RUN=false
CHECK_IMAGES=false
IGNORE_IMAGES=()
IGNORE_PROJECTS=()
PRUNE_IMAGES=false

# Parse flags
while [[ ${1:-} != "" ]]; do
  case "$1" in
    --force-run)
      FORCE_RUN=true
      echo -e "${BLUE}[INFO] Running in FORCE RUN mode: will run no matter what.${NC}"
      shift
      ;;
    --force-all)
      FORCE_ALL=true
      echo -e "${BLUE}[INFO] Running in FORCE ALL mode: will update all currently running projects.${NC}"
      shift
      ;;
    --check-images)
      CHECK_IMAGES=true
      echo -e "${BLUE}[INFO] Running in CHECK IMAGES mode: will validate running container images against compose definitions.${NC}"
      shift
      ;;
    --ignore-images)
      shift
      while [[ ${1:-} != "" && ! "$1" =~ ^-- ]]; do
        IGNORE_IMAGES+=("$1")
        shift
      done
      echo -e "${BLUE}[INFO] Ignoring images: ${IGNORE_IMAGES[*]}${NC}"
      ;;
    --ignore-project)
      shift
      while [[ ${1:-} != "" && ! "$1" =~ ^-- ]]; do
        IGNORE_PROJECTS+=("$1")
        shift
      done
      echo -e "${BLUE}[INFO] Ignoring projects: ${IGNORE_PROJECTS[*]}${NC}"
      ;;
    --prune-images)
      PRUNE_IMAGES=true
      echo -e "${BLUE}[INFO] Running in PRUNE IMAGES mode: will prune images that are no longer referenced.${NC}"
      shift
      ;;
    *)
      break
      ;;
  esac
done

LOCK_FILE=".container-watch.lock"
LOCK_HELD=false

cleanup() {
  if [[ "$LOCK_HELD" == true ]]; then
    rm "$LOCK_FILE"
  fi
}
trap cleanup EXIT

# Check to see if .container-watch.lock exists
if [[ -f "$LOCK_FILE" && "$FORCE_RUN" == false ]]; then
  echo -e "${RED}[ERROR] Found .container-watch.lock. This script is probably already running. Exiting...${NC}"
  exit 1
fi

# Create lock file and record that we own it
touch "$LOCK_FILE"
LOCK_HELD=true

# Ensure we're on 'main' branch
current_branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$current_branch" != "main" ]]; then
  echo -e "${BLUE}[INFO] Switching from '$current_branch' to 'main'...${NC}"
  git checkout main || { echo -e "${RED}[ERROR] Failed to checkout main${NC}"; exit 1; }
fi

# Function: perform project redeploy
redeploy_project() {
  local proj_dir="$1"
  local proj_name="$2"
  echo -e "  ${BLUE}- Pulling latest images for redeploy...${NC}"
  docker compose -f "$proj_dir/docker-compose.yml" pull || echo -e "  ${YELLOW}[WARN] Failed to pull images in $proj_name${NC}"
  echo -e "  ${BLUE}- Shutting down old containers for redeploy...${NC}"
  docker compose -f "$proj_dir/docker-compose.yml" down --remove-orphans || echo -e "  ${YELLOW}[WARN] Failed to shut down $proj_name${NC}"
  echo -e "  ${BLUE}- Starting updated services for redeploy...${NC}"
  docker compose -f "$proj_dir/docker-compose.yml" up -d || echo -e "  ${RED}[ERROR] Failed to restart $proj_name${NC}"
}



# Default update flow
echo -e "${BLUE}[INFO] Fetching latest changes from origin/main...${NC}"
git fetch origin main || { echo -e "${RED}[ERROR] git fetch failed${NC}"; exit 1; }

changed_dirs=""
if [[ "$FORCE_ALL" == false ]]; then
  echo -e "${BLUE}[INFO] Fetching changes from origin/main...${NC}"
  git fetch origin main || { echo -e "${RED}[ERROR] git fetch failed${NC}"; exit 1; }

  changed_files=$(git diff --name-only HEAD..origin/main)
  compose_files=$(echo "$changed_files" | grep -E 'docker-compose\.ya?ml$' || true)

  if [[ -n "$compose_files" ]]; then
    changed_dirs=$(echo "$compose_files" \
      | xargs -n1 dirname \
      | sed 's|^\./||' \
      | sort -u)
  fi

  if [[ -z "$changed_dirs" ]]; then
    echo -e "${BLUE}[INFO] No compose file changes detected.${NC}"
    exit 0
  fi

  echo -e "${BLUE}[INFO] Pulling latest changes from origin/main...${NC}"
  git pull origin main || { echo -e "${RED}[ERROR] git pull failed${NC}"; exit 1; }
fi


# Find all immediate subdirectories with docker-compose.yml
mapfile -t all_dirs < <(find . -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
updated_any=false
for dir in "${all_dirs[@]}"; do
  # Skip ignored projects
  if [[ " ${IGNORE_PROJECTS[@]} " =~ " $dir " ]]; then
    continue
  fi
  project_dir="$REPO_ROOT/$dir"
  [[ -f "$project_dir/docker-compose.yml" ]] || continue
  project_name="$dir"
  run_update=false
  if [[ "$FORCE_ALL" == true ]]; then
    if docker compose -p "$project_name" -f "$project_dir/docker-compose.yml" ps | grep -q "Up"; then
      run_update=true
      echo -e "${YELLOW}[FORCE-ALL] Updating running project: $project_name${NC}"
    fi
  elif echo "$changed_dirs" | grep -q "^$dir$"; then
    if docker compose -p "$project_name" -f "$project_dir/docker-compose.yml" ps | grep -q "Up"; then
      run_update=true
      echo -e "${YELLOW}[CHANGED] Updating changed running project: $project_name${NC}"
    else
      echo -e "${YELLOW}[SKIP] $project_name changed but not running. Skipping.${NC}"
    fi
  fi
  if [[ "$run_update" == true ]]; then
    (
      cd "$project_dir" || { echo -e "${RED}[ERROR] Cannot cd into $project_dir${NC}"; exit 1; }
      echo -e "  ${BLUE}- Pulling latest images...${NC}"
      docker compose pull || echo -e "  ${YELLOW}[WARN] Failed to pull images in $project_name${NC}"

      echo -e "  ${BLUE}- Shutting down old containers...${NC}"
      docker compose down --remove-orphans || echo -e "  ${YELLOW}[WARN] Failed to shut down $project_name${NC}"

      echo -e "  ${BLUE}- Starting updated services...${NC}"
      docker compose up -d || echo -e "  ${RED}[ERROR] Failed to restart $project_name${NC}"
    )
    updated_any=true
    echo -e "${GREEN}[DONE] Updated $project_name${NC}"
    echo ""
  fi
done

# Function: check images consistency
check_images() {
  echo -e "${BLUE}[INFO] Checking images for all running compose projects...${NC}"
  # Find immediate subdirectories
  mapfile -t dirs < <(find . -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
  for dir in "${dirs[@]}"; do
    # Skip ignored projects
    if [[ " ${IGNORE_PROJECTS[@]} " =~ " $dir " ]]; then
      continue
    fi
    project_dir="$REPO_ROOT/$dir"
    compose_file="$project_dir/docker-compose.yml"
    [[ -f "$compose_file" ]] || continue
    # Check if any container is running
    if ! docker compose -p "$dir" -f "$compose_file" ps | grep -q "Up"; then
      continue
    fi
    echo -e "\n${YELLOW}[CHECK] Project: $dir${NC}"
    (
      cd "$project_dir" || exit 1
      redeployed=false
      # Iterate services and compare expected vs actual images
      for svc in $(docker compose -f "$compose_file" config --services); do
        # Get expected image for service
        expected=$(docker compose -f "$compose_file" config | \
          awk -v svc="$svc" '
            $1 == svc":" {flag=1; next} \
            flag && $1 == "image:" {print $2; exit}')
        # Check if image should be ignored
        if [[ " ${IGNORE_IMAGES[@]} " =~ " $expected " ]]; then
          echo -e "  ${BLUE}[SKIP] Ignoring image $expected for service '$svc'${NC}"
          continue
        fi
        # Get container ID
        cid=$(docker compose -p "$dir" -f "$compose_file" ps -q "$svc")
        if [[ -z "$cid" ]]; then
          echo -e "  ${YELLOW}[WARN] Service '$svc' is not running.${NC}"
          continue
        fi
        # Get actual image
        actual=$(docker inspect --format='{{.Config.Image}}' "$cid")
        # Compare
        if [[ "$expected" == "$actual" ]]; then
          echo -e "  ${GREEN}[MATCH]   $svc -> $actual${NC}"
        else
          echo -e "  ${RED}[MISMATCH] $svc expected '$expected' but running '$actual'${NC}"
          if [ "$redeployed" = false ]; then
            echo -e "  ${BLUE}[ACTION] Redeploying project $dir due to image mismatch...${NC}"
            redeploy_project "$project_dir" "$dir"
            redeployed=true
          fi
        fi
      done
    )
  done
}

if [[ "$CHECK_IMAGES" == true ]]; then
  check_images
fi

if [[ "$PRUNE_IMAGES" == true ]]; then
  echo -e "${BLUE}[INFO] Pruning images...${NC}"
  docker image prune -f
fi

if [[ "$FORCE_ALL" == false && -z "$changed_dirs" ]]; then
  echo -e "${BLUE}[INFO] No compose file changes detected.${NC}"
  exit 0
fi

if [[ "$updated_any" == false ]]; then
  echo -e "${BLUE}[INFO] No services were updated.${NC}"
fi
