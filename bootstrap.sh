#!/usr/bin/env bash
set -Eeuo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

trap 'echo -e "\n${RED}❌ Error at line ${LINENO}. Aborting.${NC}"' ERR

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo -e "${RED}Missing required command: $1${NC}"
    exit 1
  }
}

choose_option() {
  local title="$1"
  local default="$2"
  shift 2
  local options=("$@")
  local input

  echo
  echo -e "${BLUE}${title}${NC}"
  echo "Available options: ${options[*]}"
  read -r -p "Enter value [${default}]: " input
  input="${input:-$default}"

  for opt in "${options[@]}"; do
    if [[ "$opt" == "$input" ]]; then
      echo "$input"
      return 0
    fi
  done

  echo -e "${YELLOW}Invalid value: '${input}'. Using default: ${default}.${NC}" >&2
  echo "$default"
}

choose_yes_no() {
  local title="$1"
  local default="$2"
  local input

  read -r -p "$title [$default]: " input
  input="${input:-$default}"

  case "$input" in
    y|Y|yes|YES) echo "y" ;;
    n|N|no|NO) echo "n" ;;
    *) echo "$default" ;;
  esac
}

safe_env() {
  local key="$1"
  local value="$2"

  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    echo "${key}=${value}" >> .env
  fi
}

clear
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   🚀 Laravel Podman Bootstrap         ${NC}"
echo -e "${BLUE}========================================${NC}"

require_cmd podman
require_cmd curl
require_cmd sed
