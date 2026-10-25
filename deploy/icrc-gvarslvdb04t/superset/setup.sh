#!/usr/bin/env bash
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
# Run as root from /opt/superset. Idempotent: secrets, DB role, admin and TLS key are created only once.
set -euo pipefail
cd /opt/superset
FQDN=gvarslvdb04t.gva.icrc.priv

# Secrets are generated here so they never leave the VM.
if [ ! -f .env ]; then
  umask 077
  cat > .env <<EOF
SUPERSET_CONFIG_PATH=/app/pythonpath/superset_config.py
SUPERSET_SECRET_KEY=$(openssl rand -base64 42 | tr -d '\n')
DATABASE_HOST=127.0.0.1
DATABASE_PORT=5432
DATABASE_DB=superset
DATABASE_USER=superset
DATABASE_PASSWORD=$(openssl rand -hex 24)
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
SERVER_WORKER_AMOUNT=3
EOF
  printf 'username=admin\npassword=%s\n' "$(openssl rand -hex 12)" > admin-credentials.txt
fi
# Keys added after the first install.
add_env() { grep -q "^$1=" .env || echo "$1=$2" >> .env; }
add_env SUPERSET_BIND_ADDRESS 127.0.0.1
add_env SUPERSET_PUBLIC_URL "https://$FQDN"
add_env MCP_JWT_SECRET "$(openssl rand -hex 32)"
add_env MCP_JWT_ISSUER superset-gvarslvdb04t
add_env MCP_JWT_AUDIENCE superset-mcp
set -a; . ./.env; set +a

# Metadata database in the host PostgreSQL 17.
cd /tmp
if ! sudo -u postgres psql -XAtc "select 1 from pg_roles where rolname='superset'" | grep -q 1; then
  sudo -u postgres psql -Xv ON_ERROR_STOP=1 -v pw="$DATABASE_PASSWORD" <<'SQL'
CREATE ROLE superset LOGIN PASSWORD :'pw';
SQL
fi
if ! sudo -u postgres psql -XAtc "select 1 from pg_database where datname='superset'" | grep -q 1; then
  sudo -u postgres psql -Xv ON_ERROR_STOP=1 -c "CREATE DATABASE superset OWNER superset ENCODING 'UTF8'"
fi
cd /opt/superset

# The container runs as uid 1000; the config holds no secrets (those come from .env).
chmod 644 superset_config.py
# docker format keeps the base image's HEALTHCHECK.
podman build --pull=never --format docker -t localhost/superset-icrc:6.1.0 -f Containerfile .

run() { podman run --rm --pull=never --network host --env-file .env \
  -v ./superset_config.py:/app/pythonpath/superset_config.py:ro,z \
  localhost/superset-icrc:6.1.0 "$@"; }

run superset db upgrade
if [ ! -f .admin-created ]; then
  run superset fab create-admin --username admin --firstname Superset --lastname Admin \
    --email admin@localhost --password "$(sed -n 's/^password=//p' admin-credentials.txt)"
  touch .admin-created
fi
run superset init

podman-compose up -d --force-recreate
systemctl enable --now podman-restart.service

# TLS: private key + CSR for the ICRC CA; self-signed certificate until the CA-issued one replaces it.
KEY=/etc/pki/tls/private/superset.key CRT=/etc/pki/tls/certs/superset.crt CSR=/etc/pki/tls/superset.csr
if [ ! -f "$KEY" ]; then
  openssl req -new -newkey rsa:2048 -nodes -keyout "$KEY" -out "$CSR" \
    -subj "/C=CH/L=Geneva/O=International Committee of the Red Cross/CN=$FQDN" \
    -addext "subjectAltName=DNS:$FQDN,DNS:gvarslvdb04t"
  chmod 600 "$KEY"
  openssl x509 -req -in "$CSR" -signkey "$KEY" -days 397 -out "$CRT" \
    -copy_extensions copyall
fi

# nginx reverse proxy.
rpm -q nginx >/dev/null || dnf -y -q install nginx
install -m 644 nginx-superset.conf /etc/nginx/conf.d/superset.conf
# RHEL's stock nginx.conf also declares a port-80 server; ours is the default_server, so drop that flag there.
sed -i 's/listen\(\s\+\S*80\)\s\+default_server;/listen\1;/' /etc/nginx/nginx.conf
setsebool -P httpd_can_network_connect 1
nginx -t
systemctl enable nginx
systemctl reload-or-restart nginx

podman-compose ps
