#!/usr/bin/env bash
set -Eeuo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   🚀 Laravel Podman Bootstrap         ${NC}"
echo -e "${BLUE}========================================${NC}"

# ====== INPUTS ======

read -p "Nombre del proyecto [app]: " PROJ_NAME
PROJ_NAME=${PROJ_NAME:-app}

SAFE_NAME=$(echo "$PROJ_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')

read -p "Versión PHP [8.4]: " PHP_VER
PHP_VER=${PHP_VER:-8.4}

read -p "PostgreSQL [17]: " PG_VER
PG_VER=${PG_VER:-17}

read -p "Node (enter = no usar): " NODE_VER

read -p "¿Instalar PrimeVue? (y/N): " PRIMEVUE
PRIMEVUE=${PRIMEVUE:-n}

read -p "¿Usar Redis? (y/N): " USE_REDIS
USE_REDIS=${USE_REDIS:-n}

# ====== SETUP ======

mkdir -p "$SAFE_NAME"/docker/nginx
cd "$SAFE_NAME"

# ====== DOCKERFILE ======

cat > Dockerfile <<EOF
FROM php:${PHP_VER}-fpm

RUN apt-get update && apt-get install -y \\
    git curl unzip zip libpq-dev libpng-dev libzip-dev

RUN docker-php-ext-install pdo_pgsql pgsql gd zip

EOF

# Node opcional
if [[ -n "$NODE_VER" ]]; then
cat >> Dockerfile <<EOF
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VER}.x | bash - && \\
    apt-get install -y nodejs
EOF
fi

# Redis opcional
if [[ "$USE_REDIS" == "y" ]]; then
cat >> Dockerfile <<EOF
RUN pecl install redis && docker-php-ext-enable redis
EOF
fi

cat >> Dockerfile <<EOF

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www
EOF

# ====== DOCKER COMPOSE ======

cat > docker-compose.yml <<EOF
services:
  app:
    build: .
    volumes:
      - .:/var/www
    depends_on:
      - db

  db:
    image: postgres:${PG_VER}-alpine
    environment:
      POSTGRES_DB: ${SAFE_NAME}_db
      POSTGRES_USER: admin
      POSTGRES_PASSWORD: password
EOF

if [[ "$USE_REDIS" == "y" ]]; then
cat >> docker-compose.yml <<EOF

  redis:
    image: redis:alpine
EOF
fi

cat >> docker-compose.yml <<EOF

  nginx:
    image: nginx:alpine
    ports:
      - "8080:80"
    volumes:
      - .:/var/www
      - ./docker/nginx/default.conf:/etc/nginx/conf.d/default.conf
EOF

# ====== NGINX ======

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

# ====== LARAVEL ======

echo -e "${GREEN}Instalando Laravel...${NC}"

podman run --rm -v $(pwd):/app -w /app composer:2 \
    composer create-project laravel/laravel .

# ====== UP ======

podman compose up -d --build

# ====== ENV ======

sed -i "s/DB_CONNECTION=sqlite/DB_CONNECTION=pgsql/" .env
sed -i "s/DB_HOST=127.0.0.1/DB_HOST=db/" .env
sed -i "s/DB_DATABASE=laravel/DB_DATABASE=${SAFE_NAME}_db/" .env
sed -i "s/DB_USERNAME=root/DB_USERNAME=admin/" .env
sed -i "s/DB_PASSWORD=/DB_PASSWORD=password/" .env

# Redis opcional
if [[ "$USE_REDIS" == "y" ]]; then
sed -i "s/SESSION_DRIVER=database/SESSION_DRIVER=redis/" .env
sed -i "s/REDIS_HOST=127.0.0.1/REDIS_HOST=redis/" .env
fi

podman compose exec app php artisan key:generate

# ====== FRONTEND ======

if [[ -n "$NODE_VER" ]]; then
podman compose exec app npm install
podman compose exec app npm run build

if [[ "$PRIMEVUE" == "y" ]]; then
podman compose exec app npm install primevue @primevue/themes primeicons
fi
fi

echo -e "${GREEN}✅ Proyecto listo: http://localhost:8080${NC}"
