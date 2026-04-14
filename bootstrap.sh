clear
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   🚀 Laravel Podman Bootstrap         ${NC}"
echo -e "${BLUE}========================================${NC}"

require_cmd podman
require_cmd curl
require_cmd sed

if podman compose version >/dev/null 2>&1; then
  COMPOSE="podman compose"
else
  COMPOSE="podman-compose"
fi

read -r -p "Project name to create [app]: " NAME
NAME=${NAME:-app}
SAFE=$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')

PHP=$(choose_option \
  "Select the PHP version for the application" \
  "8.4" \
  "8.4" "8.3" "8.2")

PG=$(choose_option \
  "Select the PostgreSQL version for the database container" \
  "17" \
  "18" "17" "16" "15" "14")

read -r -p "Node.js version for frontend tooling (leave blank to skip): " NODE

REDIS=$(choose_yes_no \
  "Enable Redis for cache, queues and sessions? (y/n)" \
  "n")

PRIME="n"
if [[ -n "$NODE" ]]; then
  PRIME=$(choose_yes_no \
    "Install PrimeVue UI components? (y/n)" \
    "n")
fi

mkdir -p "$SAFE"/docker/nginx
cd "$SAFE"

cat > Dockerfile <<EOF
FROM php:${PHP}-fpm

RUN apt-get update && apt-get install -y \\
    git curl unzip zip libpq-dev libpng-dev libzip-dev

RUN docker-php-ext-install pdo_pgsql pgsql gd zip
EOF

if [[ -n "$NODE" ]]; then
cat >> Dockerfile <<EOF
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE}.x | bash - && \\
    apt-get install -y nodejs
EOF
fi

if [[ "$REDIS" == "y" ]]; then
cat >> Dockerfile <<EOF
RUN pecl install redis && docker-php-ext-enable redis
EOF
fi

cat >> Dockerfile <<EOF
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
WORKDIR /var/www
EOF

cat > docker-compose.yml <<EOF
services:
  app:
    build: .
    volumes:
      - .:/var/www
    depends_on:
      - db

  db:
    image: postgres:${PG}-alpine
    environment:
      POSTGRES_DB: ${SAFE}_db
      POSTGRES_USER: admin
      POSTGRES_PASSWORD: password

  nginx:
    image: nginx:alpine
    ports:
      - "8080:80"
    volumes:
      - .:/var/www
      - ./docker/nginx/default.conf:/etc/nginx/conf.d/default.conf
EOF

if [[ "$REDIS" == "y" ]]; then
cat >> docker-compose.yml <<EOF

  redis:
    image: redis:alpine
EOF
fi

cat > docker/nginx/default.conf <<'EOF'
server {
    listen 80;
    root /var/www/public;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass app:9000;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
EOF

echo "Installing Laravel..."
podman run --rm -v "$(pwd):/app" -w /app docker.io/library/composer:2 \
  composer create-project laravel/laravel .

$COMPOSE up -d --build

safe_env DB_CONNECTION pgsql
safe_env DB_HOST db
safe_env DB_DATABASE ${SAFE}_db
safe_env DB_USERNAME admin
safe_env DB_PASSWORD password

if [[ "$REDIS" == "y" ]]; then
  safe_env SESSION_DRIVER redis
  safe_env REDIS_HOST redis
fi

$COMPOSE exec app php artisan key:generate

if [[ -n "$NODE" ]]; then
  $COMPOSE exec app npm install

  if [[ "$PRIME" == "y" ]]; then
    $COMPOSE exec app npm install primevue @primevue/themes primeicons
  fi

  $COMPOSE exec app npm run build
fi

echo -e "${GREEN}✅ Ready: http://localhost:8080${NC}"
