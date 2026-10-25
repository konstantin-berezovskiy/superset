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
"""Check each dataset SQL against LB_MSCRM: runs, row count, key uniqueness, duration. Prints no row data."""
import os
import pathlib
import sys
import time

import pymssql

conn = pymssql.connect(
    server=os.environ.get("MSSQL_SERVER", "gvarslvdb03t"), port=1433,
    user=os.environ["MSSQL_USER"], password=os.environ["MSSQL_PW"],
    database=os.environ.get("MSSQL_DB", "LB_MSCRM"), login_timeout=15, timeout=600,
)
cur = conn.cursor()
cur.execute("SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED")

names = sys.argv[1:] or sorted(p.stem for p in pathlib.Path("/ampm/datasets").glob("*.sql"))
for name in names:
    sql = pathlib.Path(f"/ampm/datasets/{name}.sql").read_text(encoding="utf-8")
    try:
        cur.execute(f"SELECT TOP 0 * FROM (\n{sql}\n) q")
        cols = [d[0] for d in cur.description]
        key = cols[0]
        t0 = time.time()
        cur.execute(f"SELECT COUNT(*), COUNT(DISTINCT {key}) FROM (\n{sql}\n) q")
        n, distinct = cur.fetchone()
        print(f"{name}: rows={n} distinct_{key}={distinct} {'OK' if n == distinct else 'DUPLICATE KEYS'} "
              f"time={time.time() - t0:.1f}s cols={len(cols)}")
        print("   ", ", ".join(cols))
    except Exception as e:  # report and continue with the next dataset
        print(f"{name}: ERROR {str(e)[:500]}")
