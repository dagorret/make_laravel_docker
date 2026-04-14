#!/usr/bin/env bash

SERVICE="clinic_app"

case "$1" in
  # ------------------------
  # PODMAN / COMPOSE
  # ------------------------
  up|down|restart|logs|ps)
    podman compose "$@"
    ;;

  build)
    podman compose build
    ;;

  # ------------------------
  # SHELL
  # ------------------------
  shell)
    podman exec -it $SERVICE sh
    ;;

  bash)
    podman exec -it $SERVICE bash || podman exec -it $SERVICE sh
    ;;

  # ------------------------
  # LARAVEL (ARTISAN)
  # ------------------------
  artisan)
    shift
    podman exec -it $SERVICE sh -lc "cd /var/www && php artisan $*"
    ;;

  tinker)
    podman exec -it $SERVICE sh -lc "cd /var/www && php artisan tinker"
    ;;

  migrate)
    podman exec -it $SERVICE sh -lc "cd /var/www && php artisan migrate"
    ;;

  fresh)
    podman exec -it $SERVICE sh -lc "cd /var/www && php artisan migrate:fresh --seed"
    ;;

  seed)
    podman exec -it $SERVICE sh -lc "cd /var/www && php artisan db:seed"
    ;;

  rollback)
    podman exec -it $SERVICE sh -lc "cd /var/www && php artisan migrate:rollback"
    ;;

  cache-clear)
    podman exec -it $SERVICE sh -lc "cd /var/www && php artisan optimize:clear"
    ;;

  route-list)
    podman exec -it $SERVICE sh -lc "cd /var/www && php artisan route:list"
    ;;

  make)
    shift
    podman exec -it $SERVICE sh -lc "cd /var/www && php artisan make:$*"
    ;;

  test)
    podman exec -it $SERVICE sh -lc "cd /var/www && php artisan test"
    ;;

  # ------------------------
  # NPM / NODE
  # ------------------------
  npm)
    shift
    podman exec -it $SERVICE sh -lc "cd /var/www && npm $*"
    ;;

  vite)
    podman exec -it $SERVICE sh -lc "cd /var/www && npm run dev"
    ;;

  build-front)
    podman exec -it $SERVICE sh -lc "cd /var/www && npm run build"
    ;;

  # ------------------------
  # UTILIDADES
  # ------------------------
  php)
    shift
    podman exec -it $SERVICE php "$@"
    ;;

  composer)
    shift
    podman exec -it $SERVICE composer "$@"
    ;;

  *)
    echo ""
    echo "Available commands:"
    echo ""
    echo "  ./p up -d             Start containers"
    echo "  ./p down              Stop containers"
    echo "  ./p logs -f           View logs"
    echo "  ./p shell             Enter container"
    echo ""
    echo "  Laravel:"
    echo "  ./p artisan migrate"
    echo "  ./p migrate"
    echo "  ./p fresh"
    echo "  ./p seed"
    echo "  ./p rollback"
    echo "  ./p tinker"
    echo "  ./p route-list"
    echo "  ./p make controller UserController"
    echo "  ./p test"
    echo ""
    echo "  Frontend:"
    echo "  ./p npm install"
    echo "  ./p vite"
    echo "  ./p build-front"
    echo ""
    echo "  Utils:"
    echo "  ./p composer install"
    echo "  ./p php -v"
    echo ""
    ;;
esac
