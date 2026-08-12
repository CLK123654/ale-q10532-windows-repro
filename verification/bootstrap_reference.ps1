$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$tempRoot = Join-Path $env:RUNNER_TEMP '特征封账 参考生成'
$evidenceRoot = Join-Path $repo 'evidence'
Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $evidenceRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $tempRoot,$evidenceRoot | Out-Null
Expand-Archive -LiteralPath (Join-Path $repo '输入数据包.zip') -DestinationPath $tempRoot
Copy-Item -LiteralPath (Join-Path $repo 'input_data/node_modules') -Destination (Join-Path $tempRoot 'input_data/node_modules') -Recurse
New-Item -ItemType Directory -Force (Join-Path $tempRoot 'output/chart') | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'candidate/chart') -Destination (Join-Path $tempRoot 'output/chart/feature-freeze-control') -Recurse
Push-Location (Join-Path $tempRoot 'input_data')
try {
  & npm.cmd run process
  if ($LASTEXITCODE -ne 0) { throw '业务入口结束状态非零' }
} finally { Pop-Location }
Compress-Archive -LiteralPath (Join-Path $tempRoot 'output') -DestinationPath (Join-Path $evidenceRoot 'reference.zip')
@{
  result = 'PASS'
  helm_version = (& $env:HELM_BIN version --short).Trim()
  reference_sha256 = (Get-FileHash -LiteralPath (Join-Path $evidenceRoot 'reference.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
  reference_members = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'output') -File -Recurse | ForEach-Object { $_.FullName.Substring($tempRoot.Length + 1).Replace('\','/') } | Sort-Object)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $evidenceRoot 'bootstrap-evidence.json') -Encoding utf8NoBOM
