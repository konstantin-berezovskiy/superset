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
"""Create/update the Missing Persons datasets, charts and dashboards in Superset via the REST API.

Idempotent: datasets are matched by table name, charts by name, dashboards by slug.
Env: SUPERSET_URL, ADMIN_USER, ADMIN_PW. Dataset SQL is read from /ampm/datasets/<name>.sql.
"""
import json
import os
import pathlib

import requests
import urllib3

urllib3.disable_warnings()

URL = os.environ.get("SUPERSET_URL", "https://gvarslvdb04t.gva.icrc.priv")
DATABASE_NAME = "LB_MSCRM"
CACHE_TIMEOUT = 3600
DASHBOARD_ROLES = ["Gamma"]  # viewers via DASHBOARD_RBAC

s = requests.Session()
s.verify = False


def api(method, path, **kw):
    r = s.request(method, f"{URL}/api/v1/{path}", timeout=300, **kw)
    if r.status_code >= 400:
        raise RuntimeError(f"{method} {path} -> {r.status_code}: {r.text[:800]}")
    return r.json() if r.content else {}


def login():
    tok = api("POST", "security/login", json={
        "username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PW"], "provider": "db", "refresh": False,
    })["access_token"]
    s.headers["Authorization"] = f"Bearer {tok}"
    s.headers["X-CSRFToken"] = api("GET", "security/csrf_token/")["result"]
    s.headers["Referer"] = URL


def find_one(resource, col, value):
    q = f"(filters:!((col:{col},opr:eq,value:'{value}')),page_size:100)"
    res = api("GET", f"{resource}/", params={"q": q})["result"]
    return res[0] if res else None


# ---------------------------------------------------------------- datasets

DATASETS = {
    "mp_missing_person": {
        "description": "One row per missing person (AM/PM). Last-seen details from the best MP Record. "
                       "Excludes confidential/sensitive persons; no names, addresses or free text.",
        "metrics": {
            "missing_persons": ("COUNT(*)", "Missing persons", None),
            "still_missing": ("SUM(CASE WHEN mp_status = 'Missing' THEN 1 ELSE 0 END)", "Still missing", None),
            "with_dna_reference": ("SUM(CASE WHEN has_dna_reference = 'Yes' THEN 1 ELSE 0 END)", "With DNA reference", None),
            "pct_with_dna_reference": ("AVG(CASE WHEN has_dna_reference = 'Yes' THEN 1.0 ELSE 0 END)", "% with DNA reference", ".1%"),
            "with_death_information": ("SUM(CASE WHEN has_death_information = 'Yes' THEN 1 ELSE 0 END)", "With death information", None),
            "avg_age_at_disappearance": ("AVG(CAST(age_at_disappearance AS float))", "Average age at disappearance", ".1f"),
            "family_members": ("SUM(family_member_count)", "Family members", None),
        },
    },
    "mp_record": {
        "description": "One row per MP Record (registration, interview, consolidation) of an in-scope missing person.",
        "metrics": {
            "records": ("COUNT(*)", "Records", None),
            "interviews": ("SUM(CASE WHEN record_type = 'Interview' THEN 1 ELSE 0 END)", "Interviews", None),
            "validated_records": ("SUM(CASE WHEN review_status = 'Validated' THEN 1 ELSE 0 END)", "Validated records", None),
            "pct_validated": ("AVG(CASE WHEN review_status = 'Validated' THEN 1.0 ELSE 0 END)", "% validated", ".1%"),
        },
    },
    "mp_family_link": {
        "description": "One row per relationship '<relative> is <type> of <missing person>': family, interviewees, "
                       "persons linked to the circumstances of disappearance.",
        "metrics": {
            "links": ("COUNT(*)", "Links", None),
            "relatives": ("COUNT(DISTINCT relative_id)", "Relatives / contacts", None),
            "missing_persons": ("COUNT(DISTINCT person_id)", "Missing persons", None),
            "dna_donors": ("COUNT(DISTINCT CASE WHEN gave_dna_sample = 'Yes' THEN relative_id END)", "Relatives who gave DNA", None),
        },
    },
    "mp_dna_sample": {
        "description": "One row per biological reference sample (BRS) given by a relative of an in-scope missing person.",
        "metrics": {
            "samples": ("COUNT(*)", "DNA samples", None),
            "samples_collected": ("SUM(CASE WHEN sample_status IN ('Collected', 'Stored and Profiled') THEN 1 ELSE 0 END)", "Samples collected", None),
            "samples_profiled": ("SUM(CASE WHEN sample_status = 'Stored and Profiled' THEN 1 ELSE 0 END)", "Samples profiled", None),
            "samples_to_collect": ("SUM(CASE WHEN sample_status = 'To be Collected' THEN 1 ELSE 0 END)", "Samples to be collected", None),
            "missing_persons_covered": ("COUNT(DISTINCT CASE WHEN sample_status IN ('Collected', 'Stored and Profiled') THEN person_id END)", "Missing persons covered", None),
        },
    },
    "mp_event": {
        "description": "One row per event of disappearance with the number of in-scope missing persons linked.",
        "metrics": {
            "events": ("COUNT(*)", "Events", None),
            "linked_missing_persons": ("SUM(missing_person_count)", "Missing persons linked", None),
        },
    },
    "mp_death_information": {
        "description": "One row per item of death information reported in an MP Record.",
        "metrics": {
            "death_information_items": ("COUNT(*)", "Death information items", None),
            "missing_persons": ("COUNT(DISTINCT person_id)", "Missing persons", None),
        },
    },
}


def label(col):
    return col.replace("_ar", " (Arabic)").replace("_", " ").capitalize().replace("Dna", "DNA").replace("Mp ", "MP ")


def upsert_dataset(db_id, name, spec):
    sql = pathlib.Path(f"/ampm/datasets/{name}.sql").read_text(encoding="utf-8").strip()
    existing = find_one("dataset", "table_name", name)
    if existing:
        ds_id = existing["id"]
        api("PUT", f"dataset/{ds_id}", json={"sql": sql})
        api("PUT", f"dataset/{ds_id}/refresh")
    else:
        ds_id = api("POST", "dataset/", json={"database": db_id, "schema": "dbo", "table_name": name, "sql": sql})["id"]
    ds = api("GET", f"dataset/{ds_id}")["result"]
    old_metrics = {m["metric_name"]: m["id"] for m in ds["metrics"]}
    metrics = [
        {**({"id": old_metrics[m]} if m in old_metrics else {}), "metric_name": m, "expression": expr,
         "verbose_name": verbose, "d3format": fmt}
        for m, (expr, verbose, fmt) in spec["metrics"].items()
    ]
    columns = [
        {"id": c["id"], "column_name": c["column_name"], "verbose_name": label(c["column_name"]),
         "is_dttm": c["is_dttm"], "type": c["type"], "groupby": not c["column_name"].endswith("_id"),
         "filterable": True}
        for c in ds["columns"]
    ]
    api("PUT", f"dataset/{ds_id}?override_columns=true", json={
        "description": spec["description"], "cache_timeout": CACHE_TIMEOUT, "metrics": metrics, "columns": columns,
    })
    print(f"dataset {name}: id={ds_id} columns={len(columns)} metrics={len(metrics)}")
    return ds_id


# ---------------------------------------------------------------- charts

def big_number(metric, subtitle, fmt="SMART_NUMBER"):
    return {"viz_type": "big_number_total", "metric": metric, "subtitle": subtitle, "header_font_size": 0.4,
            "subtitle_font_size": 0.15, "y_axis_format": fmt, "adhoc_filters": []}


def bar(x, metric, horizontal=False, groupby=None, sort_by_x=False, limit=50, categorical=False, stack=False):
    return {
        "viz_type": "echarts_timeseries_bar", "x_axis": x, "metrics": [metric], "groupby": groupby or [],
        "adhoc_filters": [], "row_limit": 10000 if groupby else limit,
        "orientation": "horizontal" if horizontal else "vertical",
        "x_axis_sort": x if sort_by_x else metric, "x_axis_sort_asc": True if (sort_by_x or horizontal) else False,
        "xAxisForceCategorical": categorical, "show_value": not groupby, "show_legend": bool(groupby),
        "stack": "Stack" if stack else None, "rich_tooltip": True, "truncate_metric": True,
        "color_scheme": "supersetColors", "y_axis_format": "SMART_NUMBER", "zoomable": False,
    }


def pie(col, metric):
    return {"viz_type": "pie", "groupby": [col], "metric": metric, "adhoc_filters": [], "row_limit": 25,
            "sort_by_metric": True, "donut": True, "show_labels": True, "label_type": "key_percent",
            "labels_outside": True, "show_legend": True, "legendOrientation": "top", "innerRadius": 40,
            "outerRadius": 70, "number_format": "SMART_NUMBER", "color_scheme": "supersetColors"}


def line(x, metric, groupby=None, grain="P1M"):
    return {"viz_type": "echarts_timeseries_line", "x_axis": x, "time_grain_sqla": grain, "metrics": [metric],
            "groupby": groupby or [], "adhoc_filters": [], "row_limit": 10000, "show_legend": True,
            "rich_tooltip": True, "markerEnabled": True, "color_scheme": "supersetColors", "y_axis_format": "SMART_NUMBER"}


def table(groupby, metrics, sort_metric, limit=20):
    return {"viz_type": "table", "query_mode": "aggregate", "groupby": groupby, "metrics": metrics,
            "all_columns": [], "percent_metrics": [], "adhoc_filters": [], "timeseries_limit_metric": sort_metric,
            "order_desc": True, "row_limit": limit, "server_page_length": 10, "show_cell_bars": True,
            "table_timestamp_format": "smart_date", "include_search": False}


# Dashboards: list of rows; each row is a list of (chart name, dataset, form data, width, height).
DASHBOARDS = [
    {
        "slug": "missing-persons-overview",
        "title": "Missing Persons - Overview",
        "intro": "### Missing Persons - Overview\nMissing persons registered in the AM/PM database (LB_MSCRM). "
                 "Last-seen information comes from each person's best MP Record. Confidential and sensitive persons "
                 "are excluded, and no names or addresses are shown. Data is cached for 1 hour.",
        "filters": [("Sex", "sex"), ("Nationality", "nationality"), ("Governorate last seen", "governorate_last_seen"),
                    ("Period last seen", "period_last_seen"), ("Event type", "event_type"), ("MP status", "mp_status")],
        "rows": [
            [("Missing persons", "mp_missing_person", big_number("missing_persons", "registered missing persons"), 3, 25),
             ("Still missing", "mp_missing_person", big_number("still_missing", "status 'Missing'"), 3, 25),
             ("With DNA reference", "mp_missing_person", big_number("pct_with_dna_reference", "of missing persons have a collected DNA reference sample", ".1%"), 3, 25),
             ("With death information", "mp_missing_person", big_number("with_death_information", "persons with reported death information"), 3, 25)],
            [("Missing persons by year last seen", "mp_missing_person", bar("year_last_seen", "missing_persons", sort_by_x=True, limit=100, categorical=True), 8, 50),
             ("Missing persons by governorate last seen", "mp_missing_person", bar("governorate_last_seen", "missing_persons", horizontal=True), 4, 50)],
            [("Missing persons by sex", "mp_missing_person", pie("sex", "missing_persons"), 4, 50),
             ("Missing persons by age at disappearance", "mp_missing_person", bar("age_group", "missing_persons", sort_by_x=True), 4, 50),
             ("Missing persons by nationality", "mp_missing_person", bar("nationality", "missing_persons", horizontal=True, limit=10), 4, 50)],
            [("Missing persons by period and governorate", "mp_missing_person", bar("period_last_seen", "missing_persons", groupby=["governorate_last_seen"], sort_by_x=True, stack=True), 8, 55),
             ("Missing persons by event type", "mp_missing_person", bar("event_type", "missing_persons", horizontal=True), 4, 55)],
            [("Events with the most missing persons", "mp_event", table(["event_name", "event_type", "start_year", "governorate"], ["linked_missing_persons"], "linked_missing_persons"), 12, 60)],
        ],
    },
    {
        "slug": "missing-persons-family-dna",
        "title": "Missing Persons - Family Links & DNA",
        "intro": "### Family links & DNA reference samples\nRelatives and other persons linked to missing persons, and the "
                 "biological reference samples (BRS) collected from relatives to support identification.",
        "filters": [],
        "rows": [
            [("DNA samples", "mp_dna_sample", big_number("samples", "biological reference samples registered"), 3, 25),
             ("DNA samples collected", "mp_dna_sample", big_number("samples_collected", "collected or stored & profiled"), 3, 25),
             ("DNA samples profiled", "mp_dna_sample", big_number("samples_profiled", "stored and profiled"), 3, 25),
             ("Missing persons covered by DNA", "mp_dna_sample", big_number("missing_persons_covered", "missing persons with at least one collected sample"), 3, 25)],
            [("DNA sample status", "mp_dna_sample", bar("sample_status", "samples", horizontal=True), 4, 50),
             ("DNA samples collected per year", "mp_dna_sample", bar("collected_year", "samples", sort_by_x=True, limit=100, categorical=True), 8, 50)],
            [("Donor relationship to the missing person", "mp_dna_sample", bar("donor_relationship", "samples", horizontal=True, limit=12), 6, 55),
             ("DNA coverage by governorate last seen", "mp_missing_person", bar("governorate_last_seen", "missing_persons", groupby=["has_dna_reference"], sort_by_x=True, stack=True), 6, 55)],
            [("All necessary DNA samples collected", "mp_missing_person", pie("all_dna_samples_collected", "missing_persons"), 4, 50),
             ("Links by relationship category", "mp_family_link", pie("relationship_category", "links"), 4, 50),
             ("Most frequent family relationships", "mp_family_link", {**bar("relationship_type", "relatives", horizontal=True, limit=12),
              "adhoc_filters": [{"expressionType": "SIMPLE", "clause": "WHERE", "subject": "relationship_category",
                                 "operator": "==", "comparator": "Family member"}]}, 4, 50)],
        ],
    },
    {
        "slug": "missing-persons-data-collection",
        "title": "Missing Persons - Data Collection",
        "intro": "### Data collection & case management\nRegistration and interview records, review status, and "
                 "death information reported for missing persons.",
        "filters": [],
        "rows": [
            [("MP records", "mp_record", big_number("records", "registration, interview and consolidation records"), 3, 25),
             ("Interviews", "mp_record", big_number("interviews", "interview records"), 3, 25),
             ("Records validated", "mp_record", big_number("pct_validated", "of records have review status 'Validated'", ".1%"), 3, 25),
             ("Death information items", "mp_death_information", big_number("death_information_items", "items of reported death information"), 3, 25)],
            [("Records created per month", "mp_record", line("created_on", "records", groupby=["record_type"]), 12, 50)],
            [("Record review status", "mp_record", pie("review_status", "records"), 4, 50),
             ("Interviews by governorate", "mp_record", {**bar("interview_governorate", "records", horizontal=True),
              "adhoc_filters": [{"expressionType": "SIMPLE", "clause": "WHERE", "subject": "record_type",
                                 "operator": "==", "comparator": "Interview"}]}, 4, 50),
             ("Death information by type", "mp_death_information", bar("information_type", "death_information_items", horizontal=True), 4, 50)],
        ],
    },
]


def query_context(ds_id, fd):
    """Minimal saved query context, so /api/v1/chart/<id>/data, CSV export and MCP can run the chart."""
    filters = [{"col": f["subject"], "op": f["operator"], "val": f["comparator"]} for f in fd.get("adhoc_filters", [])]
    query = {"filters": filters, "extras": {"having": "", "where": ""}, "applied_time_extras": {},
             "annotation_layers": [], "series_limit": 0, "order_desc": True, "url_params": {},
             "custom_params": {}, "custom_form_data": {}, "post_processing": []}
    viz = fd["viz_type"]
    if viz == "big_number_total":
        query.update(columns=[], metrics=[fd["metric"]], row_limit=1)
    elif viz == "pie":
        query.update(columns=fd["groupby"], metrics=[fd["metric"]], orderby=[[fd["metric"], False]], row_limit=fd["row_limit"])
    elif viz == "table":
        query.update(columns=fd["groupby"], metrics=fd["metrics"], orderby=[[fd["timeseries_limit_metric"], False]],
                     row_limit=fd["row_limit"])
    else:  # echarts timeseries bar / line
        axis = {"columnType": "BASE_AXIS", "sqlExpression": fd["x_axis"], "label": fd["x_axis"], "expressionType": "SQL"}
        if fd.get("time_grain_sqla"):
            axis["timeGrain"] = fd["time_grain_sqla"]
        query.update(columns=[axis, *fd["groupby"]], metrics=fd["metrics"], orderby=[[fd["metrics"][0], False]],
                     row_limit=fd["row_limit"])
    return {"datasource": {"id": ds_id, "type": "table"}, "force": False, "queries": [query], "form_data": fd,
            "result_format": "json", "result_type": "full"}


def upsert_chart(name, ds_id, form_data, dash_id):
    params = {**form_data, "datasource": f"{ds_id}__table"}
    body = {"slice_name": name, "viz_type": params["viz_type"], "datasource_id": ds_id, "datasource_type": "table",
            "params": json.dumps(params), "query_context": json.dumps(query_context(ds_id, params)),
            "dashboards": [dash_id], "cache_timeout": None}
    existing = find_one("chart", "slice_name", name)
    if existing:
        api("PUT", f"chart/{existing['id']}", json=body)
        return existing["id"]
    return api("POST", "chart/", json=body)["id"]


def role_ids(names):
    roles = api("GET", "dashboard/related/roles", params={"q": "(page_size:100)"})["result"]
    found = {r["text"]: r["value"] for r in roles}
    missing = set(names) - set(found)
    if missing:
        raise SystemExit(f"roles not found: {sorted(missing)}")
    return [found[n] for n in names]


def upsert_dashboard(spec, ds_ids):
    try:
        dash_id = api("GET", f"dashboard/{spec['slug']}")["result"]["id"]
    except RuntimeError:
        dash_id = api("POST", "dashboard/", json={"dashboard_title": spec["title"], "slug": spec["slug"]})["id"]

    position = {
        "DASHBOARD_VERSION_KEY": "v2",
        "ROOT_ID": {"type": "ROOT", "id": "ROOT_ID", "children": ["GRID_ID"]},
        "GRID_ID": {"type": "GRID", "id": "GRID_ID", "children": [], "parents": ["ROOT_ID"]},
        "HEADER_ID": {"id": "HEADER_ID", "type": "HEADER", "meta": {"text": spec["title"]}},
        "MARKDOWN-intro": {"type": "MARKDOWN", "id": "MARKDOWN-intro", "children": [],
                           "parents": ["ROOT_ID", "GRID_ID", "ROW-intro"],
                           "meta": {"width": 12, "height": 20, "code": spec["intro"]}},
        "ROW-intro": {"type": "ROW", "id": "ROW-intro", "children": ["MARKDOWN-intro"],
                      "parents": ["ROOT_ID", "GRID_ID"], "meta": {"background": "BACKGROUND_TRANSPARENT"}},
    }
    position["GRID_ID"]["children"].append("ROW-intro")
    charts_by_ds = {}
    for i, row in enumerate(spec["rows"]):
        row_id = f"ROW-{i}"
        position["GRID_ID"]["children"].append(row_id)
        position[row_id] = {"type": "ROW", "id": row_id, "children": [], "parents": ["ROOT_ID", "GRID_ID"],
                            "meta": {"background": "BACKGROUND_TRANSPARENT"}}
        for name, ds, form_data, width, height in row:
            chart_id = upsert_chart(name, ds_ids[ds], form_data, dash_id)
            charts_by_ds.setdefault(ds, []).append(chart_id)
            cid = f"CHART-{chart_id}"
            position[row_id]["children"].append(cid)
            position[cid] = {"type": "CHART", "id": cid, "children": [], "parents": ["ROOT_ID", "GRID_ID", row_id],
                             "meta": {"width": width, "height": height, "chartId": chart_id, "sliceName": name}}

    all_charts = [c for ids in charts_by_ds.values() for c in ids]
    in_scope = charts_by_ds.get("mp_missing_person", [])
    filters = [{
        "id": f"NATIVE_FILTER-{col}", "name": fname, "filterType": "filter_select", "type": "NATIVE_FILTER",
        "targets": [{"datasetId": ds_ids["mp_missing_person"], "column": {"name": col}}],
        "controlValues": {"enableEmptyFilter": False, "defaultToFirstItem": False, "multiSelect": True,
                          "searchAllOptions": False, "inverseSelection": False},
        "defaultDataMask": {"extraFormData": {}, "filterState": {}, "ownState": {}},
        "cascadeParentIds": [], "description": "",
        "scope": {"rootPath": ["ROOT_ID"], "excluded": [c for c in all_charts if c not in in_scope]},
        "chartsInScope": in_scope, "tabsInScope": [],
    } for fname, col in spec["filters"]]
    metadata = {"native_filter_configuration": filters, "color_scheme": "supersetColors", "refresh_frequency": 0,
                "cross_filters_enabled": True, "timed_refresh_immune_slices": [], "expanded_slices": {},
                "label_colors": {}, "shared_label_colors": [], "chart_configuration": {}}
    api("PUT", f"dashboard/{dash_id}", json={
        "dashboard_title": spec["title"], "slug": spec["slug"], "published": True,
        "position_json": json.dumps(position), "json_metadata": json.dumps(metadata),
        "roles": role_ids(DASHBOARD_ROLES),
    })
    print(f"dashboard {spec['slug']}: id={dash_id} charts={len(all_charts)} filters={len(filters)}")
    return all_charts


def verify_charts(chart_ids):
    """Run every chart's saved query; print row counts only."""
    failed = 0
    for cid in chart_ids:
        r = s.get(f"{URL}/api/v1/chart/{cid}/data/", params={"format": "json", "type": "full"}, timeout=300)
        name = api("GET", f"chart/{cid}")["result"]["slice_name"]
        if r.status_code >= 400:
            failed += 1
            print(f"  FAIL chart {cid} '{name}': {r.status_code} {r.text[:300]}")
        else:
            q = r.json()["result"][0]
            print(f"  ok   chart {cid} '{name}': rows={q.get('rowcount')}")
    print(f"verified {len(chart_ids)} charts, {failed} failed")


def main():
    login()
    db = find_one("database", "database_name", DATABASE_NAME)
    if not db:
        raise SystemExit(f"database {DATABASE_NAME} not found")
    ds_ids = {name: upsert_dataset(db["id"], name, spec) for name, spec in DATASETS.items()}
    chart_ids = [c for spec in DASHBOARDS for c in upsert_dashboard(spec, ds_ids)]
    verify_charts(chart_ids)


if __name__ == "__main__":
    main()
