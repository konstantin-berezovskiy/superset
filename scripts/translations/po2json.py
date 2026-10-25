#!/usr/bin/env python3
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
"""Build frontend language packs (messages.json) from messages.po without Node.

Produces the same Jed 1.x structure as
`po2json --domain superset --format jed1.x --fuzzy` (superset-frontend/scripts/po2json.sh),
using only Babel, which every Superset image already ships. This lets a published
"lean" image (built with BUILD_TRANSLATIONS=false) get working UI translations:

    python scripts/translations/po2json.py superset/translations/ar/LC_MESSAGES/messages.po
    pybabel compile -d superset/translations -l ar
"""

import json
import sys
from pathlib import Path

from babel.messages.pofile import read_po


def po_to_jed(po_path: Path) -> dict:
    with po_path.open("rb") as f:
        catalog = read_po(f)
    lang = str(catalog.locale) if catalog.locale else po_path.parent.parent.name
    data: dict = {
        "": {
            "domain": "superset",
            "plural_forms": catalog.plural_forms,
            "lang": lang,
        }
    }
    for message in catalog:
        if not message.id:
            continue
        msgid = message.id[0] if isinstance(message.id, tuple) else message.id
        forms = list(message.string) if isinstance(message.string, tuple) else [message.string]
        if not any(forms):
            continue  # Jed falls back to the msgid
        key = f"{message.context}\u0004{msgid}" if message.context else msgid
        data[key] = forms
    return {"domain": "superset", "locale_data": {"superset": data}}


def main(paths: list[str]) -> None:
    if not paths:
        sys.exit(f"usage: {sys.argv[0]} <messages.po> [...]")
    for path in map(Path, paths):
        out = path.with_suffix(".json")
        pack = po_to_jed(path)
        out.write_text(json.dumps(pack, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"{out}: {len(pack['locale_data']['superset']) - 1} messages")


if __name__ == "__main__":
    main(sys.argv[1:])
