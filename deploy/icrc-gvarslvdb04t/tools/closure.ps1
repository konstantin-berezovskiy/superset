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
# From uv-compiled requirement files, list pins needed for $Root that aren't already in base.txt.
param([string]$Dev, [string]$Base, [string]$Root = 'fastmcp')

function Read-Pins($path) {
    $pins = @{}; $via = @{}; $cur = $null; $inVia = $false
    foreach ($line in Get-Content $path) {
        if ($line -match '^([A-Za-z0-9_.\-]+)(\[[^\]]*\])?==(\S+)') {
            $cur = $Matches[1].ToLower() -replace '_', '-'; $pins[$cur] = $Matches[3]; $via[$cur] = @(); $inVia = $false
        } elseif ($cur -and $line -match '^\s+# via\s*(\S.*)?$') {
            $inVia = $true; if ($Matches[1]) { $via[$cur] += ($Matches[1].Trim().ToLower() -replace '_', '-') }
        } elseif ($cur -and $inVia -and $line -match '^\s+#\s+(\S+)') {
            $via[$cur] += ($Matches[1].ToLower() -replace '_', '-')
        } elseif ($line -notmatch '^\s+#') { $cur = $null; $inVia = $false }
    }
    @{ Pins = $pins; Via = $via }
}

$d = Read-Pins $Dev; $b = Read-Pins $Base
$set = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Root))
do {
    $added = $false
    foreach ($p in $d.Pins.Keys) {
        if (-not $set.Contains($p) -and ($d.Via[$p] | Where-Object { $set.Contains($_) })) { [void]$set.Add($p); $added = $true }
    }
} while ($added)

foreach ($p in ($set | Sort-Object)) {
    $bv = $b.Pins[$p]
    if (-not $bv) { "$p==$($d.Pins[$p])" }
    elseif ($bv -ne $d.Pins[$p]) { Write-Warning "$p base=$bv dev=$($d.Pins[$p])" }
}
