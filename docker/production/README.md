# Frappe Helpdesk — Despliegue en Docker (Producción)

Despliegue de **Frappe Helpdesk** en Docker con:

- **MariaDB 10.8** como motor de DB (servicio local del propio compose). Es la
  combinación oficialmente soportada por Frappe v15. También se puede
  apuntar a **PostgreSQL externo** cambiando `DB_TYPE=postgres` y `DB_HOST`
  a tu RDS — pero v15 dejó de mantener fixes para PG, úsalo bajo tu cuenta.
- **Almacenamiento en S3** (AWS o compatible: MinIO, DO Spaces, Wasabi).
- **Redis** local (cache + queue + socketio) en contenedores.
- **Nginx** como reverse proxy.
- Workers, scheduler y socketio separados.

## Estructura

```
docker/production/
├── Dockerfile          # Imagen de Frappe + Helpdesk + libs PG/S3
├── docker-compose.yml  # Servicios (sin DB local)
├── .env.example        # Plantilla de variables (copia a .env)
├── init.sh             # Entrypoint del contenedor (init/start/worker/...)
├── deploy.sh           # Script CLI de despliegue en el host
├── nginx.conf          # Config del reverse proxy
└── README.md
```

> **Build con código LOCAL**: el `docker-compose.yml` apunta `context: ../..`
> (la raíz del repo) y el `Dockerfile` instala Helpdesk con `pip install -e`
> sobre la fuente copiada desde el checkout actual. Es decir: lo que
> construyas con `./deploy.sh build` es exactamente lo que tengas en tu
> árbol de trabajo (incluyendo cambios sin commitear). Telephony se sigue
> clonando desde GitHub porque es una dependencia externa. El
> `.dockerignore` de la raíz excluye `.git`, `node_modules`, `dist/`, etc.

## Requisitos

- Docker 24+ y Docker Compose v2 en el host.
- (Default MariaDB) Nada — el servicio `mariadb` se levanta dentro del
  compose y `bench new-site` crea la DB y el usuario aplicativo solo.
  Definí `DB_ROOT_PASSWORD` en `.env` (es el password root del contenedor).
- (Alternativa Postgres externo) Acceso de red al servidor PG y la DB +
  usuario aplicativo ya creados; ver sección "Postgres externo".
- Bucket S3 ya creado y un **perfil AWS** en `~/.aws/credentials` con permisos `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` (ver más abajo).
- Identidad SMTP verificada en **AWS SES** y un usuario IAM SES con sus credenciales SMTP (CSV).

## Pasos rápidos

```bash
cd docker/production

# 1. Configura variables
cp .env.example .env
$EDITOR .env

# 2. Verifica conectividad a PG y S3
./deploy.sh check

# 3. Construye la imagen
./deploy.sh build

# 4. Crea el sitio (ejecuta init.sh dentro del contenedor)
./deploy.sh init

# 5. Levanta todos los servicios
./deploy.sh up

# 6. Logs
./deploy.sh logs
```

El sitio quedará accesible en `http://<host>:${HTTP_PORT:-80}` con el nombre definido en `SITE_NAME`. Asegúrate de que el DNS apunte al host o de añadirlo a `/etc/hosts` para pruebas.

Credenciales iniciales:

- Usuario: `Administrator`
- Password: el valor de `ADMIN_PASSWORD`

## PostgreSQL externo

Frappe v15 soporta PostgreSQL nativamente con `--db-type postgres`. El script `init.sh` ya lo configura. Este despliegue **no usa usuario root**: la DB y el usuario aplicativo deben crearse de antemano. En el servidor de DB:

```sql
-- Como superusuario (una sola vez):
CREATE USER administrator WITH PASSWORD 'cambiame_db';
CREATE DATABASE fliiper_helpdesk OWNER administrator ENCODING 'UTF8';
GRANT ALL PRIVILEGES ON DATABASE fliiper_helpdesk TO administrator;
```

> `bench new-site` se invoca con `--db-root-username` / `--db-root-password` apuntando al **mismo** `DB_USER`/`DB_PASSWORD`. Como la DB ya existe, Frappe la reutiliza en lugar de intentar crearla. Esto es ideal en RDS u otros DBaaS donde no quieres entregar credenciales de superusuario al contenedor.

### Migraciones

`./deploy.sh init` es idempotente: si el sitio ya existe, ejecuta `bench --site $SITE migrate` en lugar de crear uno nuevo. Úsalo después de cada `pull` para aplicar cambios.

## Credenciales AWS (perfil por defecto)

Las credenciales AWS para S3 (y cualquier otro servicio AWS que use boto3) **no** se ponen en el `.env`. Se toman del perfil configurado en el host con `aws configure` (archivo `~/.aws/credentials`). El compose monta ese directorio en cada contenedor en modo solo lectura:

```yaml
volumes:
  - ${HOME}/.aws:/home/frappe/.aws:ro
```

En el `.env` solo necesitas:

```env
AWS_PROFILE=default
AWS_REGION=us-east-1
```

Si `AWS_PROFILE` apunta a un perfil distinto al `default`, asegúrate de que exista en `~/.aws/credentials` del host. En init, `init.sh` resuelve `aws_access_key_id` y `aws_secret_access_key` desde ese perfil con boto3 y los inyecta en `site_config.json` (necesario para **S3 Backup Settings**, que aún requiere las claves explícitas).

> En entornos con IAM Role asociado al host (EC2, ECS, EKS), boto3 los descubre automáticamente: deja `AWS_PROFILE=default` y omite `~/.aws/credentials` — el rol del host basta para S3, pero los **backups automáticos** seguirán necesitando claves explícitas en `site_config.json`. En ese caso define `S3_ACCESS_KEY_ID` y `S3_SECRET_ACCESS_KEY` en el `.env`.

## Almacenamiento S3

Hay dos casos de uso:

### a) Backups automáticos a S3 (incluido)

Los nombres en `site_config.json` que entiende `frappe.integrations.doctype.s3_backup_settings`:

- `aws_access_key_id`, `aws_secret_access_key` (resueltos desde el perfil AWS)
- `aws_s3_bucket_name`, `aws_s3_region`
- `aws_s3_endpoint_url` (compatibilidad con S3 no-AWS)

Para activar backups periódicos: en el sitio, ve a **S3 Backup Settings** y marca *Enabled*.

### b) Almacenamiento de archivos adjuntos en S3

Frappe **no** sirve archivos desde S3 de forma nativa. Para que cada subida vaya a S3 hace falta la app comunitaria [`frappe_s3_attachment`](https://github.com/zerodha/frappe_s3_attachment):

```bash
# En el contenedor backend:
./deploy.sh shell
bench get-app https://github.com/zerodha/frappe_s3_attachment
bench --site $SITE_NAME install-app frappe_s3_attachment
```

`init.sh` detecta automáticamente si la app está disponible y la instala. Después configura **S3 File Attachment** en la UI del sitio con las mismas credenciales.

> Si prefieres no añadir esa app, puedes montar un volumen en NFS/EFS o usar un bucket S3 vía `s3fs` montado en `/home/frappe/frappe-bench/sites/<site>/private/files`.

## Email saliente (AWS SES vía SMTP)

El despliegue está cableado a AWS SES por SMTP. SES expone dos juegos de credenciales que **no** son intercambiables:

- **AWS API** (access key / secret) — se resuelven desde el perfil AWS (ver sección anterior).
- **SMTP de SES** — un usuario y contraseña SMTP propios, generados al crear el usuario IAM de SES y descargados en el CSV. Son los que van en `SES_SMTP_USER` y `SES_SMTP_PASSWORD`.

Variables en `.env`:

```env
SES_SMTP_ENDPOINT=email-smtp.us-east-1.amazonaws.com
SES_SMTP_PORT=587
SES_IAM_USER_NAME=ses-smtp-user.20260504-193508
SES_SMTP_USER=                # del CSV de SES
SES_SMTP_PASSWORD=            # del CSV de SES
AUTO_EMAIL_ID=helpdesk@midominio.com
USE_TLS=1
```

`init.sh` las traduce a `mail_server`, `mail_port`, `mail_login`, `mail_password`, `auto_email_id` y `use_tls` en `site_config.json`. Recuerda:

- En SES "Sandbox" solo puedes enviar a direcciones verificadas. Solicita salir del sandbox para producción.
- La identidad usada en `AUTO_EMAIL_ID` debe estar verificada (dominio o email) en la región de `SES_SMTP_ENDPOINT`.
- El endpoint SMTP cambia por región: `email-smtp.<region>.amazonaws.com`.

## Comandos útiles

```bash
./deploy.sh build       # rebuild imagen
./deploy.sh init        # crear sitio o migrar
./deploy.sh up          # arrancar todo
./deploy.sh down        # detener todo
./deploy.sh restart     # reiniciar app sin tocar redis
./deploy.sh logs backend
./deploy.sh shell       # bash dentro del backend
./deploy.sh backup      # backup manual (sube a S3 si hay Backup Settings)
./deploy.sh upgrade     # build + migrate + restart
./deploy.sh check       # comprueba conectividad a PG y S3
```

## Servicios del compose

| Servicio          | Rol                                          |
|-------------------|----------------------------------------------|
| `redis-cache`     | Caché de Frappe                              |
| `redis-queue`     | Cola de RQ + bus Socket.IO                   |
| `site-creator`    | Job one-shot que crea/migra el sitio         |
| `backend`         | Gunicorn (puerto 8000)                       |
| `worker-default`  | Worker RQ cola `default`                     |
| `worker-short`    | Worker RQ cola `short`                       |
| `worker-long`     | Worker RQ cola `long`                        |
| `scheduler`       | Cron interno de Frappe                       |
| `socketio`        | Socket.IO (puerto 9000)                      |
| `nginx`           | Reverse proxy (publica `HTTP_PORT`)          |

## TLS / HTTPS

`nginx.conf` está en HTTP plano. Para HTTPS, la opción más simple es poner un proxy/CDN delante (Cloudflare, Caddy, Traefik) o añadir un sidecar `certbot` con LetsEncrypt. Si necesitas un compose con Traefik avalado por LetsEncrypt, indícalo y lo añadimos.

## Escalado horizontal

- Para alta disponibilidad, replica `backend`, `worker-*` y `socketio` con `--scale` o detrás de un orquestador (ECS, K8s, Swarm).
- El volumen `sites` debe ser compartido entre todas las réplicas que sirvan el mismo sitio (NFS, EFS) **o** delegar todos los archivos a S3 vía `frappe_s3_attachment`.
- PostgreSQL ya es externo: úsalo en su modo HA (RDS Multi-AZ, Patroni, etc.).

## Troubleshooting

- **`could not connect to server`**: revisa firewall, `pg_hba.conf` y que `DB_HOST` sea accesible desde el contenedor (no `localhost`).
- **`role "postgres" does not exist`**: en algunos DBaaS el superusuario no es `postgres`. Ajusta `DB_ROOT_USER`.
- **Archivos suben pero no aparecen**: si esperas almacenamiento en S3 verifica que `frappe_s3_attachment` esté instalada **en el sitio** (`bench --site $SITE list-apps`).
- **`502 Bad Gateway` en Nginx**: el backend aún no terminó `init`. Revisa `./deploy.sh logs site-creator`.
