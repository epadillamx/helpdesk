#!/usr/bin/env bash
# =========================================================================
# Frappe Helpdesk - Script de despliegue en el HOST
# Uso:
#   ./deploy.sh build         # construye la imagen
#   ./deploy.sh init          # crea / migra el sitio
#   ./deploy.sh up            # arranca todos los servicios
#   ./deploy.sh down          # detiene todos los servicios
#   ./deploy.sh logs [svc]    # logs en vivo
#   ./deploy.sh backup        # backup manual a S3
#   ./deploy.sh shell         # consola dentro del backend
#   ./deploy.sh upgrade       # rebuild + migrate + restart
# =========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

COMPOSE="docker compose"
ENV_FILE=".env"

require_env() {
  if [ ! -f "${ENV_FILE}" ]; then
    echo "ERROR: no existe ${ENV_FILE}. Copia .env.example y edítalo." >&2
    exit 1
  fi
}

check_db_connection() {
  require_env
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE}"; set +a
  local db_type="${DB_TYPE:-mariadb}"

  # Si MariaDB corre como servicio del propio compose (DB_HOST=mariadb), no
  # podemos resolver ese nombre desde un `docker run` ad-hoc — solo desde la
  # red interna del compose. depends_on + healthcheck + wait_for_db en
  # init.sh se encargan del timing en ese caso.
  if [ "${db_type}" = "mariadb" ] && [ "${DB_HOST}" = "mariadb" ]; then
    echo ">> MariaDB local en compose, se omite verificación pre-flight."
    return
  fi

  echo ">> Verificando conexión a ${db_type} ${DB_HOST}:${DB_PORT}..."
  if [ "${db_type}" = "mariadb" ]; then
    if ! docker run --rm \
          mariadb:10.8 \
          mariadb -h "${DB_HOST}" -P "${DB_PORT}" \
                  -u "${DB_ROOT_USER:-root}" \
                  -p"${DB_ROOT_PASSWORD}" \
                  -e "SELECT VERSION();" >/dev/null 2>&1; then
      echo "ERROR: no se pudo conectar a MariaDB. Revisa .env, firewall y credenciales." >&2
      exit 1
    fi
  else
    if ! docker run --rm \
          -e PGPASSWORD="${DB_PASSWORD}" \
          postgres:15-alpine \
          psql -h "${DB_HOST}" -p "${DB_PORT}" \
               -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT version();" >/dev/null 2>&1; then
      echo "ERROR: no se pudo conectar a PostgreSQL. Revisa .env, firewall y credenciales." >&2
      exit 1
    fi
  fi
  echo ">> Conexión OK."
}

check_s3_connection() {
  require_env
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE}"; set +a
  if [ -z "${S3_BUCKET:-}" ]; then
    echo ">> S3 no configurado, se omite verificación."
    return
  fi
  local aws_dir="${HOME}/.aws"
  if [ ! -d "${aws_dir}" ]; then
    echo "ERROR: no existe ${aws_dir}. Configura el perfil AWS con 'aws configure'." >&2
    exit 1
  fi
  # En Git Bash (MINGW64) hay que evitar la conversión de rutas POSIX→Windows al montar volúmenes en Docker.
  local mount_src="${aws_dir}"
  if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
    export MSYS_NO_PATHCONV=1
  fi
  # --endpoint-url solo si está definido (si no, aws-cli usa el endpoint AWS por defecto).
  local endpoint_args=()
  if [ -n "${S3_ENDPOINT_URL:-}" ]; then
    endpoint_args=(--endpoint-url "${S3_ENDPOINT_URL}")
  fi
  echo ">> Verificando acceso a bucket S3 '${S3_BUCKET}' (perfil=${AWS_PROFILE:-default})..."
  if ! docker run --rm \
        -v "${mount_src}:/root/.aws:ro" \
        -e AWS_PROFILE="${AWS_PROFILE:-default}" \
        -e AWS_DEFAULT_REGION="${S3_REGION:-us-east-1}" \
        amazon/aws-cli \
        "${endpoint_args[@]}" \
        s3 ls "s3://${S3_BUCKET}"; then
    echo "ERROR: no se pudo listar el bucket S3. Revisa el perfil AWS y los permisos." >&2
    exit 1
  fi
  echo ">> S3 accesible."
}

cmd_build() {
  require_env
  ${COMPOSE} build
}

cmd_init() {
  check_db_connection
  check_s3_connection
  # Levanta primero los servicios de soporte. mariadb solo si es local;
  # si DB_TYPE=postgres con DB_HOST externo, mariadb no se usa.
  local infra=(redis-cache redis-queue)
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE}"; set +a
  if [ "${DB_TYPE:-mariadb}" = "mariadb" ] && [ "${DB_HOST}" = "mariadb" ]; then
    infra+=(mariadb)
  fi
  ${COMPOSE} up -d "${infra[@]}"
  ${COMPOSE} run --rm site-creator
}

cmd_up() {
  require_env
  # Re-siembra automática del volumen `assets` en cada `up`.
  #
  # Por qué: cada vez que `./deploy.sh build` produce nuevos archivos en
  # /home/frappe/frappe-bench/sites/assets dentro de la imagen, el volumen
  # nombrado `production_assets` NO se re-siembra automáticamente porque
  # docker solo copia el contenido de la imagen al volumen la primera vez
  # que el volumen está vacío. Sin esto, el browser sigue pidiendo bundles
  # con hashes nuevos pero el volumen mantiene los viejos -> 404 en CSS/JS.
  #
  # Cómo: bajamos los contenedores que tienen el volumen montado (todos
  # menos los de soporte como mariadb/redis se levantan de cero igual),
  # nukeamos solo `production_assets` (NO sites, ni mariadb-data, ni logs),
  # y volvemos a subir. En la subida docker re-siembra desde la imagen.
  echo ">> Bajando servicios para re-sembrar el volumen assets..."
  ${COMPOSE} down --remove-orphans
  if docker volume rm production_assets 2>/dev/null; then
    echo ">> production_assets eliminado, se re-siembra desde la imagen."
  else
    echo ">> production_assets no existía o estaba vacío."
  fi
  ${COMPOSE} up -d
  ${COMPOSE} ps
}

cmd_down() {
  ${COMPOSE} down
}

cmd_restart() {
  ${COMPOSE} restart backend worker-default worker-short worker-long scheduler socketio nginx
}

cmd_logs() {
  ${COMPOSE} logs -f --tail=200 "${@:-}"
}

cmd_backup() {
  require_env
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE}"; set +a
  ${COMPOSE} exec backend bash -lc \
    "bench --site ${SITE_NAME} backup --with-files --backup-path-db /tmp/db.sql.gz --backup-path-files /tmp/files.tar"
  echo ">> Backup creado dentro del contenedor (subida a S3 vía Backup Settings)."
}

cmd_shell() {
  ${COMPOSE} exec backend bash
}

cmd_upgrade() {
  cmd_build
  ${COMPOSE} run --rm site-creator
  cmd_restart
}

main() {
  local action="${1:-}"
  case "${action}" in
    build)    cmd_build ;;
    init)     cmd_init ;;
    up)       cmd_up ;;
    down)     cmd_down ;;
    restart)  cmd_restart ;;
    logs)     shift; cmd_logs "$@" ;;
    backup)   cmd_backup ;;
    shell)    cmd_shell ;;
    upgrade)  cmd_upgrade ;;
    check)    check_db_connection; check_s3_connection ;;
    *)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' | head -n 12
      exit 1
      ;;
  esac
}

main "$@"
