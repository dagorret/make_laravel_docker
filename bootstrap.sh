#!/usr/bin/env bash
set -Eeuo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

trap 'echo -e "\n${RED}Error at line ${LINENO}. Aborting.${NC}"' ERR

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

  echo >&2
  echo -e "${BLUE}${title}${NC}" >&2
  echo "Available options: ${options[*]}" >&2
  read -r -p "Enter value [${default}]: " input
  input="${input:-$default}"

  for opt in "${options[@]}"; do
    if [[ "$opt" == "$input" ]]; then
      printf '%s\n' "$input"
      return 0
    fi
  done

  echo -e "${YELLOW}Invalid value '${input}'. Using default '${default}'.${NC}" >&2
  printf '%s\n' "$default"
}

choose_yes_no() {
  local title="$1"
  local default="$2"
  local input

  read -r -p "$title [$default]: " input
  input="${input:-$default}"

  case "$input" in
    y|Y|yes|YES|s|S|si|SI) printf 'y\n' ;;
    n|N|no|NO) printf 'n\n' ;;
    *)
      echo -e "${YELLOW}Invalid value '${input}'. Using default '${default}'.${NC}" >&2
      printf '%s\n' "$default"
      ;;
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

container_exists() {
  local name="$1"
  podman container exists "$name" >/dev/null 2>&1
}

container_is_running() {
  local name="$1"
  podman inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -qx 'true'
}

remove_project_containers() {
  local project="$1"
  local names=(
    "${project}_app"
    "${project}_db"
    "${project}_nginx"
    "${project}_redis"
    "${project}_adminer"
  )

  for name in "${names[@]}"; do
    if container_exists "$name"; then
      echo -e "${YELLOW}Removing existing container: ${name}${NC}"
      podman rm -f "$name" >/dev/null 2>&1 || true
    fi
  done
}

wait_for_container_running() {
  local name="$1"
  local retries="${2:-30}"
  local delay="${3:-2}"
  local i

  for ((i=1; i<=retries; i++)); do
    if container_is_running "$name"; then
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

run_podman_stable() {
  local stable_dir="$1"
  shift
  (
    cd "$stable_dir"
    podman "$@"
  )
}

run_in_app() {
  local stable_dir="$1"
  local container_name="$2"
  shift 2

  run_podman_stable "$stable_dir" exec -i --workdir /var/www "$container_name" "$@"
}

main() {
  local BASE_PATH
  BASE_PATH="$(pwd -P)"

  clear
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}   Laravel Podman Bootstrap            ${NC}"
  echo -e "${BLUE}========================================${NC}"

  require_cmd podman
  require_cmd curl
  require_cmd sed
  require_cmd grep
  require_cmd tr
  require_cmd id
  require_cmd mkdir
  require_cmd cp
  require_cmd pwd

  local COMPOSE_CMD
  if podman compose version >/dev/null 2>&1; then
    COMPOSE_CMD="podman compose"
  elif command -v podman-compose >/dev/null 2>&1; then
    COMPOSE_CMD="podman-compose"
  else
    echo -e "${RED}Compose support is not installed for Podman.${NC}"
    echo "Install it with:"
    echo "  sudo apt update && sudo apt install podman-compose"
    exit 1
  fi

  echo -e "${GREEN}Using compose command: ${COMPOSE_CMD}${NC}"

  echo
  read -r -p "Project name to create [app]: " NAME
  NAME="${NAME:-app}"

  local SAFE_NAME
  SAFE_NAME="$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')"

  local CLEANUP_OLD
  CLEANUP_OLD="$(choose_yes_no \
    "Remove old containers with the same project name if they exist? (y/n)" \
    "y")"

  local PHP_VER
  PHP_VER="$(choose_option \
    "Select the PHP version for the application (Debian 13 / trixie)" \
    "8.4" \
    "8.1" "8.2" "8.3" "8.4")"

  local PG_VER
  PG_VER="$(choose_option \
    "Select the PostgreSQL version for the database container" \
    "17" \
    "18" "17" "16" "15" "14")"

  local NODE_VER
  NODE_VER="$(choose_option \
    "Select the Node.js version for frontend tooling" \
    "none" \
    "none" "18" "20" "22" "24")"

  if [[ "$NODE_VER" == "none" ]]; then
    NODE_VER=""
  fi

  local USE_REDIS
  USE_REDIS="$(choose_yes_no \
    "Enable Redis for cache, queues and sessions? (y/n)" \
    "n")"

  local INSTALL_PRIMEVUE="n"
  if [[ -n "$NODE_VER" ]]; then
    INSTALL_PRIMEVUE="$(choose_yes_no \
      "Install PrimeVue UI components? (y/n)" \
      "n")"
  fi

  local DB_ADMIN
  DB_ADMIN="$(choose_option \
    "Select a database admin tool" \
    "adminer" \
    "adminer" "none")"

  local PROJECT_PATH="${BASE_PATH}/${SAFE_NAME}"

  if [[ "$CLEANUP_OLD" == "y" ]]; then
    remove_project_containers "$SAFE_NAME"
  fi

  if [[ -e "$PROJECT_PATH" ]]; then
    echo -e "${RED}Target directory already exists: ${PROJECT_PATH}${NC}"
    echo "Remove it or choose another project name."
    exit 1
  fi

  echo
  echo -e "${GREEN}Stage 1/5 - Creating project directory on host...${NC}"
  mkdir -p "$PROJECT_PATH"

  if [[ ! -w "$PROJECT_PATH" ]]; then
    echo -e "${RED}The target directory is not writable: ${PROJECT_PATH}${NC}"
    exit 1
  fi

  echo
  echo -e "${GREEN}Stage 2/5 - Bootstrapping Laravel in a temporary container directory...${NC}"
  run_podman_stable "$BASE_PATH" run --rm \
    --userns=keep-id \
    -v "${PROJECT_PATH}:/app" \
    -w /tmp \
    docker.io/library/composer:2 \
    sh -lc 'composer create-project laravel/laravel /tmp/laravel-src && cp -a /tmp/laravel-src/. /app/'

  mkdir -p "${PROJECT_PATH}/docker/nginx"

  echo
  echo -e "${GREEN}Stage 3/5 - Writing container configuration files...${NC}"

  cat > "${PROJECT_PATH}/Dockerfile" <<EOF
FROM docker.io/library/php:${PHP_VER}-fpm-trixie

RUN apt-get update && apt-get install -y --no-install-recommends \\
    git curl unzip zip libpq-dev libpng-dev libzip-dev libicu-dev libonig-dev \\
    libxml2-dev libjpeg62-turbo-dev libfreetype6-dev pkg-config build-essential \\
 && docker-php-ext-configure gd --with-freetype --with-jpeg \\
 && docker-php-ext-install -j"\$(nproc)" pdo_pgsql pgsql gd zip intl bcmath opcache \\
 && rm -rf /var/lib/apt/lists/*
EOF

  if [[ -n "$NODE_VER" ]]; then
    cat >> "${PROJECT_PATH}/Dockerfile" <<EOF
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VER}.x | bash - \\
 && apt-get update && apt-get install -y --no-install-recommends nodejs \\
 && command -v node \\
 && command -v npm \\
 && node --version \\
 && npm --version \\
 && rm -rf /var/lib/apt/lists/*
EOF
  fi

  if [[ "$USE_REDIS" == "y" ]]; then
    cat >> "${PROJECT_PATH}/Dockerfile" <<'EOF'
RUN pecl install redis && docker-php-ext-enable redis
EOF
  fi

  cat >> "${PROJECT_PATH}/Dockerfile" <<'EOF'
COPY --from=docker.io/library/composer:2 /usr/bin/composer /usr/bin/composer
WORKDIR /var/www
EOF

  cat > "${PROJECT_PATH}/docker-compose.yml" <<EOF
services:
  app:
    build: .
    container_name: ${SAFE_NAME}_app
    working_dir: /var/www
    volumes:
      - .:/var/www
    depends_on:
      - db
EOF

  if [[ "$USE_REDIS" == "y" ]]; then
    cat >> "${PROJECT_PATH}/docker-compose.yml" <<'EOF'
      - redis
EOF
  fi

  cat >> "${PROJECT_PATH}/docker-compose.yml" <<EOF

  db:
    image: docker.io/library/postgres:${PG_VER}-alpine
    container_name: ${SAFE_NAME}_db
    environment:
      POSTGRES_DB: ${SAFE_NAME}_db
      POSTGRES_USER: admin
      POSTGRES_PASSWORD: password
    ports:
      - "5432:5432"

  nginx:
    image: docker.io/library/nginx:alpine
    container_name: ${SAFE_NAME}_nginx
    ports:
      - "8080:80"
    volumes:
      - .:/var/www
      - ./docker/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - app
EOF

  if [[ "$USE_REDIS" == "y" ]]; then
    cat >> "${PROJECT_PATH}/docker-compose.yml" <<EOF

  redis:
    image: docker.io/library/redis:7-alpine
    container_name: ${SAFE_NAME}_redis
EOF
  fi

  if [[ "$DB_ADMIN" == "adminer" ]]; then
    cat >> "${PROJECT_PATH}/docker-compose.yml" <<EOF

  adminer:
    image: docker.io/library/adminer:latest
    container_name: ${SAFE_NAME}_adminer
    ports:
      - "8081:8080"
    depends_on:
      - db
EOF
  fi

  cat > "${PROJECT_PATH}/docker/nginx/default.conf" <<'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/public;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass app:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

  echo
  echo -e "${GREEN}Stage 4/5 - Starting containers...${NC}"
  (
    cd "$PROJECT_PATH"
    $COMPOSE_CMD up -d --build
  )

  echo
  echo -e "${GREEN}Stage 5/5 - Waiting for app container and configuring Laravel...${NC}"

  if ! wait_for_container_running "${SAFE_NAME}_app" 30 2; then
    echo -e "${RED}App container is not running: ${SAFE_NAME}_app${NC}"
    podman ps -a
    exit 1
  fi

  if ! run_podman_stable "$BASE_PATH" exec "${SAFE_NAME}_app" test -f /var/www/artisan; then
    echo -e "${RED}Laravel was not found inside the app container.${NC}"
    exit 1
  fi

  (
    cd "$PROJECT_PATH"
    safe_env DB_CONNECTION pgsql
    safe_env DB_HOST db
    safe_env DB_PORT 5432
    safe_env DB_DATABASE "${SAFE_NAME}_db"
    safe_env DB_USERNAME admin
    safe_env DB_PASSWORD password

    if [[ "$USE_REDIS" == "y" ]]; then
      safe_env REDIS_CLIENT phpredis
      safe_env REDIS_HOST redis
      safe_env REDIS_PORT 6379
      safe_env REDIS_PASSWORD null
      safe_env SESSION_DRIVER redis
      safe_env CACHE_STORE redis
      safe_env QUEUE_CONNECTION redis
    fi
  )

  echo
  echo -e "${GREEN}Generating application key...${NC}"
  run_in_app "$BASE_PATH" "${SAFE_NAME}_app" php artisan key:generate

  echo
  echo -e "${GREEN}Running database migrations...${NC}"
  run_in_app "$BASE_PATH" "${SAFE_NAME}_app" php artisan migrate

  if [[ -n "$NODE_VER" ]]; then
    echo
    echo -e "${GREEN}Installing frontend dependencies...${NC}"
    run_in_app "$BASE_PATH" "${SAFE_NAME}_app" npm install

    if [[ "$INSTALL_PRIMEVUE" == "y" ]]; then
      echo
      echo -e "${GREEN}Installing PrimeVue packages...${NC}"
      run_in_app "$BASE_PATH" "${SAFE_NAME}_app" npm install primevue @primevue/themes primeicons
    fi

    echo
    echo -e "${GREEN}Building frontend assets...${NC}"
    run_in_app "$BASE_PATH" "${SAFE_NAME}_app" npm run build
  fi

  cat > "${PROJECT_PATH}/p" <<'EOF'
#!/usr/bin/env bash
podman compose "$@"
EOF
  chmod +x "${PROJECT_PATH}/p"

  cat > "${PROJECT_PATH}/README-LOCAL.txt" <<EOF
Project: ${SAFE_NAME}

Useful commands:
  ${COMPOSE_CMD} up -d
  ${COMPOSE_CMD} down
  ${COMPOSE_CMD} logs -f
  podman exec -it ${SAFE_NAME}_app bash

Helper:
  ./p up -d
  ./p down
  ./p logs -f

Application URL:
  http://localhost:8080
EOF

  if [[ "$DB_ADMIN" == "adminer" ]]; then
    cat >> "${PROJECT_PATH}/README-LOCAL.txt" <<EOF

Adminer URL:
  http://localhost:8081

Database connection:
  System: PostgreSQL
  Server: db
  Database: ${SAFE_NAME}_db
  Username: admin
  Password: password
EOF
  fi

  echo
  echo -e "${BLUE}========================================${NC}"
  echo -e "${GREEN}Project created successfully${NC}"
  echo -e "Project folder: ${BLUE}${PROJECT_PATH}${NC}"
  echo -e "Application URL: ${BLUE}http://localhost:8080${NC}"
  if [[ "$DB_ADMIN" == "adminer" ]]; then
    echo -e "Adminer URL: ${BLUE}http://localhost:8081${NC}"
  fi
  echo -e "${BLUE}========================================${NC}"
}

main "$@"
