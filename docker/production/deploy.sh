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
#   ./deploy.sh formulario    # crea el Web Form publico para tickets
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

# -------------------------------------------------------------------------
# Crea (idempotente) un Web Form publico para que clientes externos abran
# tickets sin loguearse. Lo monta en /nuevo-ticket. Si ya existe lo deja.
# Permiso de Guest: solo `create` sobre HD Ticket — NO read/write — para
# que un anonimo pueda crear pero no leer los tickets de otros.
# -------------------------------------------------------------------------
cmd_formulario() {
  require_env
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE}"; set +a
  local site="${SITE_NAME:?SITE_NAME no definida en .env}"

  # En Git Bash (MINGW64) los paths POSIX se convierten a Windows antes de
  # llegar al comando — `/home/...` se transforma a `C:/Program Files/Git/...`
  # y docker exec falla. Desactivamos esa conversión para esta invocación.
  if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
    export MSYS_NO_PATHCONV=1
  fi

  echo ">> Creando/actualizando Web Form publico de tickets en ${site}..."

  # Escribimos el script al backend via stdin del exec, despues lo corremos
  # con el python del bench. Heredoc 'PY' (con comillas) es 100% literal,
  # los valores van por env var SITE.
  ${COMPOSE} exec -T backend bash -c "cat > /tmp/setup_form.py" <<'PY'
import os
import logging.handlers

# Mismo monkey-patch que init.sh: aseguramos que existan los dirs de log
# antes de que frappe los abra (sin esto frappe.connect() puede fallar
# corriendo fuera del wrapper `bench`).
_orig = logging.handlers.RotatingFileHandler.__init__
def _safe(self, filename, *a, **kw):
    try:
        os.makedirs(os.path.dirname(filename), exist_ok=True)
    except Exception:
        pass
    _orig(self, filename, *a, **kw)
logging.handlers.RotatingFileHandler.__init__ = _safe

import frappe

frappe.init(
    site=os.environ["SITE"],
    sites_path="/home/frappe/frappe-bench/sites",
)
frappe.connect()

ROUTE = "mut-ticket"
TITLE = "MUT Ticket"

# 1) Web Form publico (idempotente por route).
existing = frappe.db.exists("Web Form", {"route": ROUTE})
if existing:
    print(f"[formulario] Web Form '{TITLE}' ya existe (name={existing}), salteo creacion.")
else:
    wf = frappe.get_doc({
        "doctype": "Web Form",
        "title": TITLE,
        "route": ROUTE,
        "doc_type": "HD Ticket",
        "module": "Helpdesk",
        "published": 1,
        "login_required": 0,
        "anonymous": 1,
        "allow_multiple": 1,
        "apply_document_permissions": 0,
        "success_message": "Tu ticket ha sido creado. Te contactaremos pronto.",
        "web_form_fields": [
            {"fieldname": "subject",     "label": "Asunto",      "fieldtype": "Data",        "reqd": 1},
            {"fieldname": "description", "label": "Descripcion", "fieldtype": "Text Editor", "reqd": 1},
            {"fieldname": "raised_by",   "label": "Tu correo",   "fieldtype": "Data",        "reqd": 1, "options": "Email"},
        ],
    })
    wf.insert(ignore_permissions=True)
    print(f"[formulario] Web Form '{TITLE}' creado en /{ROUTE}")

# 2) Permiso Guest sobre HD Ticket: SOLO create. Nada de read/write para
#    no exponer los tickets de otros usuarios anonimos.
existing_perm = frappe.db.exists(
    "Custom DocPerm",
    {"parent": "HD Ticket", "role": "Guest", "permlevel": 0},
)
if existing_perm:
    print(f"[formulario] DocPerm Guest sobre HD Ticket ya existe (name={existing_perm}).")
else:
    perm = frappe.get_doc({
        "doctype": "Custom DocPerm",
        "parent": "HD Ticket",
        "parenttype": "DocType",
        "parentfield": "permissions",
        "role": "Guest",
        "permlevel": 0,
        "create": 1,
        "read": 0,
        "write": 0,
    })
    perm.insert(ignore_permissions=True)
    print(f"[formulario] DocPerm Guest:create sobre HD Ticket anadido.")

frappe.db.commit()

host_name = frappe.db.get_single_value("Website Settings", "subdomain") or frappe.local.site
print(f"[formulario] Listo. Acceso publico en: /{ROUTE}  (sitio: {frappe.local.site})")
PY

  ${COMPOSE} exec -T -e SITE="${site}" backend /home/frappe/frappe-bench/env/bin/python /tmp/setup_form.py
  echo ">> Listo. Probalo en: http://${site}/nuevo-ticket"
}

main() {
  local action="${1:-}"
  case "${action}" in
    build)       cmd_build ;;
    init)        cmd_init ;;
    up)          cmd_up ;;
    down)        cmd_down ;;
    restart)     cmd_restart ;;
    logs)        shift; cmd_logs "$@" ;;
    backup)      cmd_backup ;;
    shell)       cmd_shell ;;
    upgrade)     cmd_upgrade ;;
    formulario)  cmd_formulario ;;
    check)       check_db_connection; check_s3_connection ;;
    *)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' | head -n 13
      exit 1
      ;;
  esac
}

main "$@"
