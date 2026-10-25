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
"""Check what a viewer-role user can do: list dashboards, load every chart in dashboard context, and be
denied direct dataset/chart access. Env: SUPERSET_URL, ADMIN_USER/ADMIN_PW, TEST_USER/TEST_PW. Prints no data."""
import json
import os

import requests
import urllib3

urllib3.disable_warnings()
URL = os.environ.get("SUPERSET_URL", "https://gvarslvdb04t.gva.icrc.priv")


def session(user, pw):
    s = requests.Session()
    s.verify = False
    tok = s.post(f"{URL}/api/v1/security/login", json={"username": user, "password": pw, "provider": "db"}).json()
    s.headers["Authorization"] = f"Bearer {tok['access_token']}"
    s.headers["X-CSRFToken"] = s.get(f"{URL}/api/v1/security/csrf_token/").json()["result"]
    s.headers["Referer"] = URL
    return s


admin = session(os.environ["ADMIN_USER"], os.environ["ADMIN_PW"])
viewer = session(os.environ["TEST_USER"], os.environ["TEST_PW"])

dashboards = viewer.get(f"{URL}/api/v1/dashboard/", params={"q": "(page_size:100)"}).json().get("result", [])
print(f"viewer sees {len(dashboards)} dashboards: {[d['slug'] for d in dashboards]}")

ok = failed = 0
for d in dashboards:
    r = viewer.get(f"{URL}/api/v1/dashboard/{d['id']}/charts")
    if r.status_code != 200:
        print(f"  FAIL dashboard {d['slug']} charts: {r.status_code}")
        failed += 1
        continue
    for ch in r.json()["result"]:
        qc = json.loads(admin.get(f"{URL}/api/v1/chart/{ch['id']}").json()["result"]["query_context"])
        qc["form_data"].update(dashboardId=d["id"], slice_id=ch["id"])
        resp = viewer.post(f"{URL}/api/v1/chart/data", json=qc)
        if resp.status_code == 200:
            ok += 1
        else:
            failed += 1
            print(f"  FAIL chart {ch['id']} '{ch['slice_name']}': {resp.status_code} {resp.text[:200]}")
print(f"charts loaded in dashboard context: ok={ok} failed={failed}")

# Outside a dashboard the viewer must be refused.
print("direct dataset GET:", viewer.get(f"{URL}/api/v1/dataset/1").status_code, "(expect 403/404)")
qc = json.loads(admin.get(f"{URL}/api/v1/chart/1").json()["result"]["query_context"])
print("chart data without dashboard:", viewer.post(f"{URL}/api/v1/chart/data", json=qc).status_code, "(expect 403)")
print("SQL Lab execute:", viewer.post(f"{URL}/api/v1/sqllab/execute/", json={"database_id": 1, "sql": "SELECT 1"}).status_code, "(expect 403)")
