# =========================================================================
# Frappe Helpdesk - Production Image
# Base sobre frappe/bench con soporte para PostgreSQL externo + S3 storage.
# El código de Helpdesk se toma del CHECKOUT LOCAL (contexto = raíz del repo),
# no de GitHub. El docker-compose.yml ya apunta `context: ../..`.
# =========================================================================
FROM frappe/bench:latest

ARG FRAPPE_BRANCH=version-15
ARG PYTHON_VERSION=3.11

ENV FRAPPE_BRANCH=${FRAPPE_BRANCH} \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq-dev \
        postgresql-client \
        default-libmysqlclient-dev \
        mariadb-client \
        curl \
        ca-certificates \
        gettext-base \
    && rm -rf /var/lib/apt/lists/*

USER frappe
WORKDIR /home/frappe

RUN bench init \
        --skip-redis-config-generation \
        --skip-assets \
        --frappe-branch ${FRAPPE_BRANCH} \
        --python python${PYTHON_VERSION} \
        frappe-bench

WORKDIR /home/frappe/frappe-bench

# Telephony se sigue clonando desde GitHub (dependencia externa de helpdesk).
RUN bench get-app --branch develop telephony https://github.com/frappe/telephony

# Almacenamiento de attachments en S3 (no es parte de Frappe core).
# Reemplaza el handler por defecto del filesystem por uno que sube a S3.
# Ojo: el repo se llama `frappe-attachments-s3` (con guiones), pero el módulo
# Python interno se llama `frappe_s3_attachment` — ese es el nombre que va en
# apps.txt y `bench --site X install-app`.
RUN bench get-app --branch master https://github.com/zerodha/frappe-attachments-s3

# -------------------------------------------------------------------------
# Helpdesk: instala desde el código LOCAL.
#   - El contexto de build es la raíz del repo (ver docker-compose.yml).
#   - Se copia toda la fuente en apps/helpdesk y se registra como app del bench.
#   - Cualquier modificación local invalida esta capa y rehace lo siguiente.
# -------------------------------------------------------------------------
COPY --chown=frappe:frappe . /home/frappe/frappe-bench/apps/helpdesk

# Python: instala helpdesk en modo editable.
# --ignore-requires-python: el pyproject.toml de helpdesk/develop pide
# Python >=3.14 (apuntando a Frappe v16), pero esta imagen corre 3.11. El
# código es compatible en la práctica; la restricción es metadata aspiracional.
RUN ./env/bin/pip install --ignore-requires-python -e apps/helpdesk

# Node: instala deps del frontend de Helpdesk.
# El package.json raíz tiene un `postinstall` que también dispara
# `yarn install` dentro de desk/, así que un único yarn install cubre las
# deps de la SPA (vite, vue, frappe-ui, etc.). Sin esto, `bench build`
# falla con `vite: not found` al intentar compilar los assets.
RUN cd apps/helpdesk && yarn install --frozen-lockfile

# apps.txt determinístico: bench get-app no siempre cierra la línea con \n,
# lo que hacía que `echo "helpdesk" >> apps.txt` se concatenara como
# "telephonyhelpdesk" en una sola línea y Frappe fallara con
# ModuleNotFoundError. Lo reescribimos de cero con las apps que esta imagen
# realmente instala. Si añadís otra app, agrégala también aquí.
RUN printf 'frappe\ntelephony\nhelpdesk\nfrappe_s3_attachment\n' > sites/apps.txt

RUN ./env/bin/pip install \
        psycopg2-binary \
        boto3 \
        botocore

# Compila los assets de producción de TODAS las apps del bench.
# Quitamos el `|| true` que tenía antes: si la build de assets falla queremos
# enterarnos en build-time, no descubrirlo en runtime con un /helpdesk vacío.
RUN bench build --production

# Entrypoint del contenedor (también vive en el repo, lo copiamos a /home/frappe)
COPY --chown=frappe:frappe docker/production/init.sh /home/frappe/init.sh
RUN chmod +x /home/frappe/init.sh

EXPOSE 8000 9000

ENTRYPOINT ["/bin/bash", "/home/frappe/init.sh"]
