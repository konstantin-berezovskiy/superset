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
# Download wheels for "name==version" pins (cp310 / linux x86_64 / glibc<=2.36) from PyPI, verifying sha256.
param([string[]]$Pins, [string]$OutDir)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force $OutDir | Out-Null

function Get-Score($f) {
    $n = $f.filename
    if ($f.packagetype -ne 'bdist_wheel') { return -1 }
    if ($n -match '-py3-none-any\.whl$|-py2\.py3-none-any\.whl$') { return 1 }
    if ($n -notmatch '(cp310-cp310|cp3\d+-abi3|py3-none)-') { return -1 }
    if ($n -match 'musllinux') { return -1 }
    if ($n -match 'manylinux_2_(\d+)_x86_64' -and [int]$Matches[1] -le 36) { return 3 }
    if ($n -match 'manylinux(2014|2010|1)_x86_64') { return 2 }
    -1
}

foreach ($pin in $Pins) {
    $name, $ver = $pin -split '=='
    $j = Invoke-RestMethod "https://pypi.org/pypi/$name/$ver/json"
    $best = $j.urls | ForEach-Object { [pscustomobject]@{ F = $_; S = (Get-Score $_) } } |
        Where-Object S -ge 0 | Sort-Object S -Descending | Select-Object -First 1
    if (-not $best) { Write-Warning "NO WHEEL: $pin"; continue }
    $f = $best.F; $path = Join-Path $OutDir $f.filename
    if (-not (Test-Path $path)) { Invoke-WebRequest -UseBasicParsing $f.url -OutFile $path }
    if ((Get-FileHash $path -Algorithm SHA256).Hash -ne $f.digests.sha256.ToUpper()) { throw "sha256 mismatch: $($f.filename)" }
    $f.filename
}
