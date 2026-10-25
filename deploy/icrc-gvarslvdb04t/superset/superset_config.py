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
import os

from celery.schedules import crontab
from flask_caching.backends.rediscache import RedisCache

SECRET_KEY = os.environ["SUPERSET_SECRET_KEY"]

SQLALCHEMY_DATABASE_URI = (
    "postgresql+psycopg2://"
    f"{os.environ['DATABASE_USER']}:{os.environ['DATABASE_PASSWORD']}"
    f"@{os.environ.get('DATABASE_HOST', '127.0.0.1')}:{os.environ.get('DATABASE_PORT', '5432')}"
    f"/{os.environ['DATABASE_DB']}"
)

REDIS_HOST = os.environ.get("REDIS_HOST", "127.0.0.1")
REDIS_PORT = os.environ.get("REDIS_PORT", "6379")
REDIS_CELERY_DB = 0
REDIS_CACHE_DB = 1


def _cache(prefix: str, timeout: int = 300) -> dict:
    return {
        "CACHE_TYPE": "RedisCache",
        "CACHE_DEFAULT_TIMEOUT": timeout,
        "CACHE_KEY_PREFIX": prefix,
        "CACHE_REDIS_URL": f"redis://{REDIS_HOST}:{REDIS_PORT}/{REDIS_CACHE_DB}",
    }


CACHE_CONFIG = _cache("superset_")
DATA_CACHE_CONFIG = _cache("superset_data_", 86400)
FILTER_STATE_CACHE_CONFIG = _cache("superset_filter_", 86400)
EXPLORE_FORM_DATA_CACHE_CONFIG = _cache("superset_explore_", 86400)

RESULTS_BACKEND = RedisCache(
    host=REDIS_HOST, port=int(REDIS_PORT), db=REDIS_CACHE_DB, key_prefix="superset_results"
)


class CeleryConfig:
    broker_url = f"redis://{REDIS_HOST}:{REDIS_PORT}/{REDIS_CELERY_DB}"
    result_backend = f"redis://{REDIS_HOST}:{REDIS_PORT}/{REDIS_CELERY_DB}"
    imports = ("superset.sql_lab", "superset.tasks.scheduler")
    worker_prefetch_multiplier = 1
    task_acks_late = False
    beat_schedule = {
        "reports.scheduler": {
            "task": "reports.scheduler",
            "schedule": crontab(minute="*", hour="*"),
        },
        "reports.prune_log": {
            "task": "reports.prune_log",
            "schedule": crontab(minute=10, hour=0),
        },
    }


CELERY_CONFIG = CeleryConfig

# Dashboard access is granted per dashboard to roles (e.g. Gamma); those roles can view the
# dashboard's charts without dataset-level permissions, which `superset init` would reset.
FEATURE_FLAGS = {"DASHBOARD_RBAC": True}

# Shared rate-limit storage across gunicorn workers.
RATELIMIT_STORAGE_URI = f"redis://{REDIS_HOST}:{REDIS_PORT}/2"

# Served by nginx over HTTPS; gunicorn listens on 127.0.0.1 only.
PUBLIC_URL = os.environ["SUPERSET_PUBLIC_URL"]
ENABLE_PROXY_FIX = True
SESSION_COOKIE_SECURE = True

# MCP server (AI clients), proxied by nginx at /mcp. Tokens: /opt/superset/mcp-token.sh
MCP_SERVICE_HOST = "127.0.0.1"
MCP_SERVICE_PORT = 5008
MCP_SERVICE_URL = PUBLIC_URL
MCP_AUTH_ENABLED = True
MCP_JWT_ALGORITHM = "HS256"
MCP_JWT_SECRET = os.environ["MCP_JWT_SECRET"]
MCP_JWT_ISSUER = os.environ.get("MCP_JWT_ISSUER", "superset-gvarslvdb04t")
MCP_JWT_AUDIENCE = os.environ.get("MCP_JWT_AUDIENCE", "superset-mcp")
