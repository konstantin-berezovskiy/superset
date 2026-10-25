<!--
Licensed to the Apache Software Foundation (ASF) under one
or more contributor license agreements.  See the NOTICE file
distributed with this work for additional information
regarding copyright ownership.  The ASF licenses this file
to you under the Apache License, Version 2.0 (the
"License"); you may not use this file except in compliance
with the License.  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing,
software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, either express or implied.  See the License for the
specific language governing permissions and limitations
under the License.
-->

# Superset on gvarslvdb04t (ICRC, internal)

Deployment configuration and the Missing Persons data model for the Superset 6.1.0 instance on
`gvarslvdb04t.gva.icrc.priv` (RHEL 9.8, no internet access). **Internal: do not push to a public remote.**

No secrets are stored here. `setup.sh` generates them on the VM (`/opt/superset/.env`,
`/opt/superset/admin-credentials.txt`); the TLS key stays in `/etc/pki/tls/private/`.

## Layout

| Folder | Deployed to | Contents |
|---|---|---|
| `superset/` | `/opt/superset/` | Podman image, compose stack, Superset config, nginx reverse proxy, setup and MCP token scripts |
| `missing-persons/` | `/opt/superset/ampm/` | Dataset SQL, Superset build script, checks, proposed `rpt` views |
| `tools/` | operator PC | PowerShell helpers to stage images and wheels offline |

## Architecture

- **Runtime:** Podman + podman-compose from the internal Satellite; host networking.
- **Image:** `localhost/superset-icrc:6.1.0` = `apache/superset:6.1.0` (lean) + `psycopg2-binary`,
  `pymssql`, `fastmcp==3.1.0`, installed offline from `superset/wheels/` (not committed).
- **Containers:** `superset` (gunicorn on 127.0.0.1:8088), `superset-worker`, `superset-beat`,
  `superset-mcp` (127.0.0.1:5008), `redis` (127.0.0.1:6379).
- **Metadata DB:** database `superset` in the host PostgreSQL 17.
- **nginx on the host** terminates TLS on 443 (80 redirects), proxies `/` to the web server and `/mcp` to the
  MCP server. The certificate is self-signed until the ICRC CA issues one for `/etc/pki/tls/superset.csr`.
- **MCP auth:** HS256 JWT; mint a token with `sudo /opt/superset/mcp-token.sh <username> [days]`.
- **Access:** `DASHBOARD_RBAC` is enabled. The Missing Persons dashboards are assigned to the Gamma role, so
  Gamma users can view them without dataset permissions (which `superset init` would reset).

## Offline staging (operator PC)

```powershell
tools\pull-image.ps1 -Repo apache/superset -Tag 6.1.0 -OutDir .\images   # docker-archive tar, sha256-checked
tools\pull-image.ps1 -Repo library/redis   -Tag 7.4.11 -OutDir .\images
tools\closure.ps1 -Dev development.txt -Base base.txt                    # fastmcp pins missing from the lean image
tools\get-wheels.ps1 -Pins (Get-Content pins.txt) -OutDir .\wheels       # cp310 / manylinux wheels from PyPI
```

`development.txt` / `base.txt` are the 6.1.0 pinned requirements, fetched from
`api.github.com/repos/apache/superset/contents/requirements/<file>?ref=6.1.0`. Python 3.10 also needs `tomli>=2`.

## Install / update (VM)

```bash
sudo podman load -i apache_superset_6.1.0.tar && sudo podman load -i redis_7.4.11.tar
# copy superset/* (+ wheels/) to /opt/superset, then:
sudo /opt/superset/setup.sh      # idempotent: secrets, metadata DB, image build, migrations, compose, TLS, nginx
```

## Missing Persons data model

The source is `LB_MSCRM` on `gvarslvdb03t` (AM/PM, Dynamics CRM 9). Each dataset is one SELECT in
`missing-persons/datasets/`, used as a Superset virtual dataset. `rpt_missing_persons_views.sql` proposes
the same SELECTs as views in schema `rpt`; it has not been applied and must be reviewed by a DBA.

| Dataset | Grain |
|---|---|
| `mp_missing_person` | missing person: profile, status, last seen (best MP Record), event, record/family/DNA/death counts |
| `mp_record` | MP Record (registration, interview, consolidation) |
| `mp_family_link` | relative or contact of a missing person (`ampm_person` = missing person) |
| `mp_dna_sample` | biological reference sample, with the donor's relationship to the missing person |
| `mp_event` | event of disappearance with linked missing persons |
| `mp_death_information` | reported death information item |

Privacy rules: no names, addresses, coordinates or free text; persons flagged confidential or sensitive are
excluded. All checks print counts only, never person-level rows.

```bash
# on the VM; MSSQL_USER / MSSQL_PW = the Superset read account
podman run --rm --network host -e MSSQL_USER -e MSSQL_PW -v /opt/superset/ampm:/ampm:ro,z \
  --entrypoint python localhost/superset-icrc:6.1.0 /ampm/test_datasets.py         # grain + timing
# ADMIN_USER / ADMIN_PW = Superset admin
podman run --rm --network host -e ADMIN_USER -e ADMIN_PW -v /opt/superset/ampm:/ampm:ro,z \
  --entrypoint python localhost/superset-icrc:6.1.0 /ampm/build_superset.py        # datasets, charts, dashboards
```

`build_superset.py` is idempotent (datasets by name, charts by name, dashboards by slug) and finishes by
running every chart's query. `verify_role_access.py` checks a viewer account (`TEST_USER` / `TEST_PW`): it
should see all dashboards and charts, and be refused dataset, chart and SQL Lab access outside them.

## Open items

- The ICRC CA certificate (PKI team): sign the CSR ("ICRC Web Server SSLCert") or provide the internal ACME URL.
- The network firewall must allow TCP 443/80 to 10.64.2.33.
- A read-only service account for `LB_MSCRM` (replace with `superset set-database-uri -d LB_MSCRM -u ...`).
