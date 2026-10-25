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
"""Aggregate-only profile of a dataset: value counts for the given columns. Usage: profile.py <dataset> <col> [<col>...]"""
import os
import pathlib
import sys

import pymssql

name, cols = sys.argv[1], sys.argv[2:]
sql = pathlib.Path(f"/ampm/datasets/{name}.sql").read_text(encoding="utf-8")
conn = pymssql.connect(
    server=os.environ.get("MSSQL_SERVER", "gvarslvdb03t"), port=1433,
    user=os.environ["MSSQL_USER"], password=os.environ["MSSQL_PW"],
    database=os.environ.get("MSSQL_DB", "LB_MSCRM"), login_timeout=15, timeout=600,
)
cur = conn.cursor()
cur.execute("SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED")
for col in cols:
    cur.execute(f"SELECT TOP 12 {col}, COUNT(*) n FROM (\n{sql}\n) q GROUP BY {col} ORDER BY n DESC")
    print(f"-- {col}: " + " | ".join(f"{v}={n}" for v, n in cur.fetchall()))
