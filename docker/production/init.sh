#!/usr/bin/env bash
# =========================================================================
# Entrypoint del contenedor Frappe (producción)
# Modos:
#   init                -> crea/migra el sitio (MariaDB o Postgres según DB_TYPE)
#   start               -> arranca gunicorn (servidor web)
#   worker <queue>      -> arranca un worker de la cola indicada
#   schedule            -> arranca el scheduler
#   socketio            -> arranca el servidor Socket.IO
# =========================================================================
set -euo pipefail

cd /home/frappe/frappe-bench

MODE="${1:-start}"
SITE="${SITE_NAME:?SITE_NAME no definida}"
SITE_PATH="sites/${SITE}"

# -------------------------------------------------------------------------
# Repara `sites/apps.txt` en cada arranque.
#
# El volumen nombrado `sites` se siembra con el contenido del directorio en
# la imagen la primera vez que se monta, y a partir de ahí persiste. Si
# alguna build dejó `apps.txt` mal formado (p.ej. `telephonyhelpdesk` en una
# sola línea por un append sin newline), el archivo defectuoso queda en el
# volumen y ningún `docker compose build` posterior lo corrige.
#
# Aquí lo reescribimos de forma determinística con las apps que esta imagen
# instala: frappe, telephony y helpdesk. Si añadís una app más al
# Dockerfile, agregala también a esta lista.
# -------------------------------------------------------------------------
ensure_apps_txt() {
  printf 'frappe\ntelephony\nhelpdesk\nfrappe_s3_attachment\n' > sites/apps.txt
}
ensure_apps_txt

# -------------------------------------------------------------------------
# Espera a que la base de datos esté disponible.
# Soporta MariaDB (default) y PostgreSQL según DB_TYPE.
# -------------------------------------------------------------------------
wait_for_db() {
  local db_type="${DB_TYPE:-mariadb}"
  echo ">> Esperando a ${db_type} en ${DB_HOST}:${DB_PORT}..."
  if [ "${db_type}" = "mariadb" ]; then
    # Probamos conexión como root para no depender de que el usuario aplicativo
    # ya exista (bench lo crea durante new-site).
    until mariadb -h "${DB_HOST}" -P "${DB_PORT}" \
                  -u "${DB_ROOT_USER:-root}" \
                  -p"${DB_ROOT_PASSWORD}" \
                  -e "SELECT 1" >/dev/null 2>&1; do
      sleep 2
    done
  else
    until PGPASSWORD="${DB_PASSWORD}" psql \
          -h "${DB_HOST}" -p "${DB_PORT}" \
          -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1" >/dev/null 2>&1; do
      sleep 2
    done
  fi
  echo ">> ${db_type} disponible."
}

# -------------------------------------------------------------------------
# Configuración global de bench (common_site_config)
# -------------------------------------------------------------------------
configure_common_site_config() {
  bench set-config -g db_type "${DB_TYPE:-mariadb}"
  bench set-config -g db_host "${DB_HOST}"
  bench set-config -gp db_port "${DB_PORT}"
  bench set-config -g redis_cache "${REDIS_CACHE}"
  bench set-config -g redis_queue "${REDIS_QUEUE}"
  bench set-config -g redis_socketio "${REDIS_SOCKETIO}"
  bench set-config -gp developer_mode "${DEVELOPER_MODE:-0}"
  # Credenciales root para que bench pueda crear el usuario aplicativo
  # durante new-site (MariaDB) o reutilizar la DB (Postgres).
  bench set-config -g root_login "${DB_ROOT_USER:-root}"
  bench set-config -g root_password "${DB_ROOT_PASSWORD}"
}

# -------------------------------------------------------------------------
# Crea el sitio si no existe; en caso contrario, migra
# -------------------------------------------------------------------------
init_site() {
  wait_for_db
  configure_common_site_config

  if [ ! -f "${SITE_PATH}/site_config.json" ]; then
    local db_type="${DB_TYPE:-mariadb}"
    echo ">> Creando sitio ${SITE} (db_type=${db_type})..."

    # Argumentos específicos por motor:
    #   - MariaDB: usa --mariadb-root-* y --mariadb-user-host-login-scope='%'
    #     (reemplaza la deprecada --no-mariadb-socket).
    #   - Postgres: usa --db-root-* (Frappe rechaza las flags de mariadb si
    #     db_type=postgres).
    local extra_args=()
    if [ "${db_type}" = "mariadb" ]; then
      extra_args+=(
        --mariadb-root-username "${DB_ROOT_USER:-root}"
        --mariadb-root-password "${DB_ROOT_PASSWORD}"
        --mariadb-user-host-login-scope='%'
      )
    else
      extra_args+=(
        --db-root-username "${DB_ROOT_USER:-${DB_USER}}"
        --db-root-password "${DB_ROOT_PASSWORD:-${DB_PASSWORD}}"
      )
    fi

    bench new-site "${SITE}" \
      --db-type "${db_type}" \
      --db-host "${DB_HOST}" \
      --db-port "${DB_PORT}" \
      --db-name "${DB_NAME}" \
      --db-password "${DB_PASSWORD}" \
      --admin-password "${ADMIN_PASSWORD}" \
      "${extra_args[@]}" \
      --install-app helpdesk

    bench --site "${SITE}" set-config mute_emails 0
    bench --site "${SITE}" set-config server_script_enabled 1
  else
    echo ">> Sitio ${SITE} ya existe. Ejecutando migración..."
    bench --site "${SITE}" migrate
  fi

  # configure_s3 y configure_smtp son nice-to-have. Si fallan (cred AWS,
  # SES caído, doctype con campos distintos, etc.) NO queremos que mate el
  # init completo y nos deje sin `bench use`, porque eso rompe el routing
  # del sitio en nginx ("does not exist"). Los wrap-eamos en || true y
  # dejamos un aviso para revisar el log.
  configure_s3       || echo ">> AVISO: configure_s3 falló — revisar log; continúa el init."
  configure_smtp     || echo ">> AVISO: configure_smtp falló — revisar log; continúa el init."
  configure_host_url || echo ">> AVISO: configure_host_url falló — los links de emails podrían quedar con :8000."

  bench use "${SITE}"
  bench --site "${SITE}" clear-cache
  echo ">> Init completado para ${SITE}."
}

# -------------------------------------------------------------------------
# Resuelve AWS access key / secret desde el perfil por defecto si no están
# definidos explícitamente en el .env. Requiere ~/.aws/credentials montado.
# -------------------------------------------------------------------------
resolve_aws_credentials() {
  if [ -n "${S3_ACCESS_KEY_ID:-}" ] && [ -n "${S3_SECRET_ACCESS_KEY:-}" ]; then
    return
  fi
  local profile="${AWS_PROFILE:-default}"
  echo ">> Resolviendo credenciales AWS desde perfil '${profile}'..."
  local creds
  creds=$(./env/bin/python - <<PY
import sys
try:
    import boto3
    session = boto3.Session(profile_name="${profile}")
    c = session.get_credentials()
    if c is None:
        sys.exit(2)
    print(c.access_key)
    print(c.secret_key)
except Exception as e:
    sys.stderr.write(str(e) + "\n")
    sys.exit(1)
PY
)
  if [ -z "${creds}" ]; then
    echo ">> AVISO: no se pudieron resolver credenciales del perfil '${profile}'." >&2
    return
  fi
  S3_ACCESS_KEY_ID=$(echo "${creds}" | sed -n 1p)
  S3_SECRET_ACCESS_KEY=$(echo "${creds}" | sed -n 2p)
  export S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY
}

# -------------------------------------------------------------------------
# Configura S3 para almacenamiento de archivos y backups
# -------------------------------------------------------------------------
configure_s3() {
  if [ -z "${S3_BUCKET:-}" ]; then
    echo ">> S3 no configurado (S3_BUCKET vacío), se omite."
    return
  fi
  echo ">> Configurando S3 (bucket=${S3_BUCKET})..."

  resolve_aws_credentials

  # Configuración para backups automáticos (S3 Backup Settings).
  # OJO: NO usar `-p` aquí. `-p` hace `ast.literal_eval(value)`, lo cual sirve
  # para números/bool/listas pero falla con strings desnudos (ej.: una access
  # key se interpreta como identificador Python y truena). `set-config` sin
  # `-p` ya graba el valor como string en site_config.json, que es lo correcto.
  if [ -n "${S3_ACCESS_KEY_ID:-}" ] && [ -n "${S3_SECRET_ACCESS_KEY:-}" ]; then
    bench --site "${SITE}" set-config aws_access_key_id "${S3_ACCESS_KEY_ID}"
    bench --site "${SITE}" set-config aws_secret_access_key "${S3_SECRET_ACCESS_KEY}"
  fi
  bench --site "${SITE}" set-config aws_s3_bucket_name "${S3_BUCKET}"
  bench --site "${SITE}" set-config aws_s3_region "${S3_REGION}"
  bench --site "${SITE}" set-config aws_s3_endpoint_url "${S3_ENDPOINT_URL}"
  bench --site "${SITE}" set-config aws_s3_folder_name "${S3_FOLDER_NAME:-helpdesk}"
  bench --site "${SITE}" set-config aws_s3_signature_version "${S3_SIGNATURE_VERSION:-s3v4}"

  # Si la app frappe_s3_attachment está disponible, instálala y configúrala
  if [ -d "apps/frappe_s3_attachment" ]; then
    if ! bench --site "${SITE}" list-apps | grep -q "frappe_s3_attachment"; then
      echo ">> Instalando frappe_s3_attachment en el sitio..."
      bench --site "${SITE}" install-app frappe_s3_attachment
    fi
    configure_s3_attachment_doctype
  else
    echo ">> AVISO: La app frappe_s3_attachment no está instalada en bench."
    echo "          Si querés que los attachments suban a S3, agregá al Dockerfile:"
    echo "          RUN bench get-app --branch master frappe_s3_attachment \\"
    echo "                  https://github.com/zerodha/frappe_s3_attachment"
  fi
}

# -------------------------------------------------------------------------
# Auto-config del singleton S3 File Attachment.
#
# La app `frappe_s3_attachment` define un doctype singleton donde van las
# credenciales y el bucket. Como los nombres de los campos pueden cambiar
# entre versiones de la app, hacemos esto defensivo: solo seteamos campos
# que realmente existen en el doctype actual. Si la app no tiene ese
# doctype (o cambia el nombre), no rompe el init — solo loggea y sigue.
# -------------------------------------------------------------------------
configure_s3_attachment_doctype() {
  if [ -z "${S3_BUCKET:-}" ]; then
    return
  fi
  if [ -z "${S3_ACCESS_KEY_ID:-}" ] || [ -z "${S3_SECRET_ACCESS_KEY:-}" ]; then
    echo ">> AVISO: sin credenciales AWS resueltas, salteando auto-config de S3 attachment."
    return
  fi

  echo ">> Configurando doctype S3 File Attachment..."
  # Frappe escribe logs en dos lugares: bench-level (/home/frappe/logs/) y
  # site-level (sites/<site>/logs/). `bench` los crea en startup; nuestro
  # ./env/bin/python directo no, así que los aseguramos acá.
  mkdir -p /home/frappe/logs
  mkdir -p "/home/frappe/frappe-bench/sites/${SITE}/logs"

  # Escribimos el script a un archivo (en vez de heredoc directo a `python -`)
  # para evitar cualquier expansión de shell sobre el contenido. Los valores
  # van por env vars; el heredoc 'PY' (con comillas) es 100% literal.
  cat > /tmp/s3_attach_setup.py <<'PY'
import os
import logging.handlers

# Monkey-patch RotatingFileHandler para crear el dir padre si falta.
# Frappe arma algunas rutas de log relativas y no siempre coinciden con
# donde estamos parados. Asegurar la existencia del dir al abrir el archivo
# es lo más robusto entre versiones de Frappe.
_orig_init = logging.handlers.RotatingFileHandler.__init__
def _safe_init(self, filename, *a, **kw):
    try:
        os.makedirs(os.path.dirname(filename), exist_ok=True)
    except Exception:
        pass
    _orig_init(self, filename, *a, **kw)
logging.handlers.RotatingFileHandler.__init__ = _safe_init

import frappe

frappe.init(
    site=os.environ["S3_SITE"],
    sites_path="/home/frappe/frappe-bench/sites",
)
frappe.connect()

# Probamos los nombres de doctype mas comunes que ha tenido la app a lo
# largo de su historia. Nos quedamos con el primero que exista.
candidates = ["S3 File Attachment", "S3 File Settings", "S3 Settings"]
target = next(
    (c for c in candidates if frappe.db.exists("DocType", c)),
    None,
)
if not target:
    print("[s3-attach] ningun doctype singleton encontrado, salteo auto-config")
    raise SystemExit(0)

doc = frappe.get_single(target)
fields = {df.fieldname for df in doc.meta.fields}

def first_match(*names):
    return next((n for n in names if n in fields), None)

writes = {
    first_match("aws_key", "access_key_id", "aws_access_key_id"):
        os.environ["S3_KEY"],
    first_match("aws_secret", "secret_access_key", "aws_secret_access_key"):
        os.environ["S3_SECRET"],
    first_match("bucket_name", "bucket"):
        os.environ["S3_BUCKET_VAR"],
    first_match("region_name", "region"):
        os.environ["S3_REGION_VAR"],
    first_match("folder_name", "folder"):
        os.environ["S3_FOLDER_VAR"],
    first_match("signature_version"):
        os.environ["S3_SIG_VAR"],
    first_match("endpoint_url", "aws_s3_endpoint_url"):
        os.environ["S3_ENDPOINT_VAR"],
}
for fieldname, value in writes.items():
    if fieldname and value:
        setattr(doc, fieldname, value)

doc.save(ignore_permissions=True)
frappe.db.commit()
applied = [fn for fn in writes if fn]
print("[s3-attach] " + target + " configurado: " + ", ".join(applied))
PY

  S3_SITE="${SITE}" \
  S3_KEY="${S3_ACCESS_KEY_ID}" \
  S3_SECRET="${S3_SECRET_ACCESS_KEY}" \
  S3_BUCKET_VAR="${S3_BUCKET}" \
  S3_REGION_VAR="${S3_REGION:-us-east-1}" \
  S3_FOLDER_VAR="${S3_FOLDER_NAME:-helpdesk}" \
  S3_ENDPOINT_VAR="${S3_ENDPOINT_URL:-}" \
  S3_SIG_VAR="${S3_SIGNATURE_VERSION:-s3v4}" \
  ./env/bin/python /tmp/s3_attach_setup.py
}

# -------------------------------------------------------------------------
# Configura `host_name` del sitio.
#
# Frappe usa `host_name` para construir URLs absolutas cuando NO hay
# contexto de request (típicamente al renderizar emails desde workers).
# Sin esto, cae al `webserver_port` del common_site_config (8000), y los
# links de invitaciones / reset password salen con `:8000`.
#
# Tomamos PUBLIC_URL del .env (ej. `http://developticket.local` o
# `https://helpdesk.midominio.com`). Si no está definido, derivamos
# `http://${SITE}` como fallback razonable.
#
# IMPORTANTE: si PUBLIC_URL no trae puerto explícito, le agregamos el
# default del scheme (:80 para http, :443 para https). Sin esto, Frappe
# v15 le pega el webserver_port (8000) al host_name al armar URLs y los
# emails de invitación salen con `http://host:8000/...`. Con un puerto
# explícito Frappe no agrega el suyo, y los browsers omiten 80/443 al
# mostrar la URL así que el link sigue viéndose limpio.
# -------------------------------------------------------------------------
configure_host_url() {
  local url="${PUBLIC_URL:-http://${SITE}}"
  url="${url%/}"  # quitar trailing slash

  # ¿el URL ya tiene `:NNNN` después del host? Si no, lo inyectamos.
  if ! echo "$url" | grep -qE '^https?://[^/]+:[0-9]+'; then
    if [[ "$url" == https://* ]]; then
      url=$(echo "$url" | sed -E 's|^(https://[^/]+)|\1:443|')
    else
      url=$(echo "$url" | sed -E 's|^(http://[^/]+)|\1:80|')
    fi
  fi

  echo ">> Seteando host_name del sitio a ${url} ..."
  bench --site "${SITE}" set-config host_name "${url}"
}

# -------------------------------------------------------------------------
# Configura SMTP saliente vía AWS SES
# -------------------------------------------------------------------------
configure_smtp() {
  # Soporta variables nuevas (SES_*) y legacy (MAIL_*) por compatibilidad.
  local server="${SES_SMTP_ENDPOINT:-${MAIL_SERVER:-}}"
  local port="${SES_SMTP_PORT:-${MAIL_PORT:-587}}"
  local login="${SES_SMTP_USER:-${MAIL_LOGIN:-}}"
  local password="${SES_SMTP_PASSWORD:-${MAIL_PASSWORD:-}}"

  if [ -z "${server}" ]; then
    echo ">> SMTP no configurado (SES_SMTP_ENDPOINT vacío), se omite."
    return
  fi
  echo ">> Configurando SMTP (server=${server}, user=${SES_IAM_USER_NAME:-${login}})..."
  bench --site "${SITE}" set-config mail_server "${server}"
  bench --site "${SITE}" set-config -p mail_port "${port}"
  bench --site "${SITE}" set-config mail_login "${login}"
  bench --site "${SITE}" set-config mail_password "${password}"
  bench --site "${SITE}" set-config auto_email_id "${AUTO_EMAIL_ID}"
  bench --site "${SITE}" set-config -p use_tls "${USE_TLS:-1}"
}

# -------------------------------------------------------------------------
# Routing
# -------------------------------------------------------------------------
case "${MODE}" in
  init)
    init_site
    ;;
  start)
    configure_common_site_config
    # Frappe en cada request hace `frappe.init(site, sites_path=".")` — busca
    # el sitio relativo a cwd. `bench serve` corre gunicorn con cwd=sites/;
    # acá replicamos eso con --chdir, que es la forma estándar y no rompe el
    # resto del script. Sin esto, Frappe busca ./developticket.local/ desde
    # el bench y devuelve 404 "does not exist" aunque el sitio exista en
    # sites/developticket.local/.
    echo ">> Lanzando gunicorn (chdir=sites/) ..."
    exec ./env/bin/gunicorn \
      --chdir /home/frappe/frappe-bench/sites \
      --bind 0.0.0.0:8000 \
      --workers "${GUNICORN_WORKERS:-4}" \
      --threads "${GUNICORN_THREADS:-2}" \
      --timeout 120 \
      --worker-class gthread \
      --access-logfile - \
      --error-logfile - \
      frappe.app:application
    ;;
  worker)
    QUEUE="${2:-default}"
    configure_common_site_config
    exec bench worker --queue "${QUEUE}"
    ;;
  schedule)
    configure_common_site_config
    exec bench schedule
    ;;
  socketio)
    exec node apps/frappe/socketio.js
    ;;
  *)
    echo "Modo desconocido: ${MODE}" >&2
    exit 1
    ;;
esac
