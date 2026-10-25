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
# Mint an MCP access token for an existing Superset user.
# Usage: sudo /opt/superset/mcp-token.sh <superset-username> [days-valid, default 30]
set -euo pipefail
user="${1:?usage: $0 <superset-username> [days]}"
days="${2:-30}"
cd /opt/superset
podman run --rm --pull=never --env-file .env -e MCP_TOKEN_USER="$user" -e MCP_TOKEN_DAYS="$days" \
  --entrypoint python localhost/superset-icrc:6.1.0 -c '
import datetime as dt, os, jwt
now = dt.datetime.now(dt.timezone.utc)
claims = {
    "sub": os.environ["MCP_TOKEN_USER"],
    "iss": os.environ.get("MCP_JWT_ISSUER", "superset-gvarslvdb04t"),
    "aud": os.environ.get("MCP_JWT_AUDIENCE", "superset-mcp"),
    "iat": now,
    "exp": now + dt.timedelta(days=int(os.environ["MCP_TOKEN_DAYS"])),
}
print(jwt.encode(claims, os.environ["MCP_JWT_SECRET"], algorithm="HS256"))
'
