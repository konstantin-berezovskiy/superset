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
# Pull a linux/amd64 image from Docker Hub without Docker and save it as a docker-archive tar.
param(
    [Parameter(Mandatory)] [string]$Repo,   # e.g. apache/superset or library/redis
    [Parameter(Mandatory)] [string]$Tag,
    [Parameter(Mandatory)] [string]$OutDir
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$token = (Invoke-RestMethod "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${Repo}:pull").token
$auth = @{ Authorization = "Bearer $token" }
$base = "https://registry-1.docker.io/v2/$Repo"
$accept = 'application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

function Get-Manifest($ref) {
    $r = Invoke-WebRequest -UseBasicParsing "$base/manifests/$ref" -Headers ($auth + @{ Accept = $accept })
    # PowerShell 5.1 returns non-"application/json" bodies (OCI media types) as raw bytes.
    $body = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { $r.Content }
    $body | ConvertFrom-Json
}

$m = Get-Manifest $Tag
if ($m.manifests) {
    $entry = $m.manifests | Where-Object { $_.platform.os -eq 'linux' -and $_.platform.architecture -eq 'amd64' } | Select-Object -First 1
    if (-not $entry) { throw "No linux/amd64 manifest for ${Repo}:${Tag}" }
    $m = Get-Manifest $entry.digest
}

$work = Join-Path $OutDir ("{0}_{1}" -f ($Repo -replace '[/:]', '_'), $Tag)
New-Item -ItemType Directory -Force $work | Out-Null

function Get-Blob($digest) {
    $hex = $digest -replace '^sha256:', ''
    $file = Join-Path $work $hex
    if (-not (Test-Path $file) -or (Get-FileHash $file -Algorithm SHA256).Hash -ne $hex.ToUpper()) {
        # Blobs redirect to a signed CDN URL that rejects the registry token, so follow the redirect manually.
        $req = [Net.HttpWebRequest]::Create("$base/blobs/$digest")
        $req.Headers.Add('Authorization', "Bearer $token")
        $req.AllowAutoRedirect = $false
        $resp = $req.GetResponse()
        $location = $resp.Headers['Location']
        $resp.Close()
        if ($location) {
            Invoke-WebRequest -UseBasicParsing $location -OutFile $file
        } else {
            Invoke-WebRequest -UseBasicParsing "$base/blobs/$digest" -Headers $auth -OutFile $file
        }
        if ((Get-FileHash $file -Algorithm SHA256).Hash -ne $hex.ToUpper()) { throw "Digest mismatch for $digest" }
    }
    $hex
}

$configHex = Get-Blob $m.config.digest
Move-Item -Force (Join-Path $work $configHex) (Join-Path $work "$configHex.json")
$layers = foreach ($l in $m.layers) {
    $hex = Get-Blob $l.digest
    Write-Host ("  layer {0} {1:N1} MB" -f $hex.Substring(0, 12), ($l.size / 1MB))
    "$hex"
}

$name = if ($Repo -like 'library/*') { $Repo.Substring(8) } else { $Repo }
$manifest = @(@{ Config = "$configHex.json"; RepoTags = @("docker.io/${name}:${Tag}"); Layers = @($layers) })
ConvertTo-Json -InputObject $manifest -Depth 5 | Set-Content -Encoding ascii (Join-Path $work 'manifest.json')

$tarPath = Join-Path $OutDir ("{0}_{1}.tar" -f ($name -replace '/', '_'), $Tag)
& tar.exe -cf $tarPath -C $work manifest.json "$configHex.json" @layers
if ($LASTEXITCODE -ne 0) { throw "tar failed" }
Remove-Item -Recurse -Force $work
Get-Item $tarPath | Select-Object Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
