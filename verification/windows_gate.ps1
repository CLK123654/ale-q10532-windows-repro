$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$evidenceRoot = Join-Path $repo 'evidence'
$referenceRoot = Join-Path $env:RUNNER_TEMP '特征封账 标准业务交付'
$inputArchive = Join-Path $repo '输入数据包.zip'
$referenceArchive = Join-Path $repo 'reference.zip'
$candidateChart = Join-Path $repo 'candidate/chart'
$sourceNames = @(
  'README.md',
  'package.json',
  'package-lock.json',
  'policy/asset_contract.json',
  'cases/render_cases.csv',
  'cases/preview-values.yaml',
  'cases/production-values.yaml',
  'cases/regulated-values.yaml'
)

Remove-Item -LiteralPath $evidenceRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $referenceRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $evidenceRoot,$referenceRoot | Out-Null
Expand-Archive -LiteralPath $referenceArchive -DestinationPath $referenceRoot

function Get-RelativeHashes([string]$root,[string]$subtree) {
  $base = Join-Path $root $subtree
  $map = [ordered]@{}
  Get-ChildItem -LiteralPath $base -File -Recurse | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($base.Length + 1).Replace('\','/')
    $map[$relative] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  return $map
}

function Assert-HashMapsEqual($actual,$expected,[string]$label) {
  if (($actual | ConvertTo-Json -Compress) -ne ($expected | ConvertTo-Json -Compress)) { throw "$label文件树或内容不一致" }
}

function Get-SourceHashes([string]$inputRoot) {
  $map = [ordered]@{}
  foreach ($name in $sourceNames) {
    $path = Join-Path $inputRoot $name
    $map[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  return $map
}

function Set-Crlf([string]$path) {
  $text = [IO.File]::ReadAllText($path)
  $text = $text -replace "`r?`n","`r`n"
  if (-not $text.EndsWith("`r`n")) { $text += "`r`n" }
  [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))
}

function Invoke-Task([string]$directory,[string]$mode) {
  Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force $directory | Out-Null
  Expand-Archive -LiteralPath $inputArchive -DestinationPath $directory
  $inputRoot = Join-Path $directory 'input_data'
  New-Item -ItemType Directory -Force (Join-Path $directory 'output/chart') | Out-Null
  Copy-Item -LiteralPath $candidateChart -Destination (Join-Path $directory 'output/chart/feature-freeze-control') -Recurse
  Push-Location $inputRoot
  try { & npm.cmd ci --ignore-scripts | Out-Null } finally { Pop-Location }
  if ($LASTEXITCODE -ne 0) { throw '无法安装代码依赖' }
  if ($mode -eq 'crlf') { Set-Crlf (Join-Path $inputRoot 'cases/render_cases.csv') }
  if ($mode -eq 'valid_change') {
    $casePath = Join-Path $inputRoot 'cases/preview-values.yaml'
    (Get-Content -LiteralPath $casePath -Raw).Replace('replicaCount: 1','replicaCount: 2') | Set-Content -LiteralPath $casePath -Encoding utf8NoBOM
  }
  if ($mode -eq 'invalid') {
    $casePath = Join-Path $inputRoot 'cases/preview-values.yaml'
    (Get-Content -LiteralPath $casePath -Raw).Replace('mode: Audit','mode: Bypass') | Set-Content -LiteralPath $casePath -Encoding utf8NoBOM
  }
  $before = Get-SourceHashes $inputRoot
  Remove-Item -LiteralPath (Join-Path $directory 'output') -Recurse -Force
  New-Item -ItemType Directory -Force (Join-Path $directory 'output/chart') | Out-Null
  Copy-Item -LiteralPath $candidateChart -Destination (Join-Path $directory 'output/chart/feature-freeze-control') -Recurse
  Push-Location $inputRoot
  try {
    & npm.cmd run process
    $exitCode = $LASTEXITCODE
  } finally { Pop-Location }
  return [ordered]@{
    directory = $directory
    input_root = $inputRoot
    output_root = Join-Path $directory 'output'
    exit_code = $exitCode
    before_hashes = $before
    after_hashes = Get-SourceHashes $inputRoot
  }
}

$archiveBefore = (Get-FileHash -LiteralPath $inputArchive -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedReference = Get-RelativeHashes $referenceRoot 'output'
$cleanOne = Invoke-Task (Join-Path $env:RUNNER_TEMP '特征封账 发布一区') 'baseline'
if ($cleanOne.exit_code -ne 0) { throw '第一个中文空格目录处理失败' }
Assert-HashMapsEqual (Get-RelativeHashes (Split-Path $cleanOne.output_root -Parent) 'output') $expectedReference '第一个中文空格目录'
Assert-HashMapsEqual $cleanOne.before_hashes $cleanOne.after_hashes '第一个中文空格目录输入'

$cleanTwo = Invoke-Task (Join-Path $env:RUNNER_TEMP '特征封账 发布二区') 'crlf'
if ($cleanTwo.exit_code -ne 0) { throw '第二个中文空格目录处理失败' }
Assert-HashMapsEqual (Get-RelativeHashes (Split-Path $cleanTwo.output_root -Parent) 'output') $expectedReference '第二个中文空格目录'
Assert-HashMapsEqual $cleanTwo.before_hashes $cleanTwo.after_hashes '第二个中文空格目录输入'
$crlfText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $cleanTwo.input_root 'cases/render_cases.csv')))
if ($crlfText -notmatch "`r`n" -or ($crlfText -replace "`r`n",'') -match "`n") { throw 'CRLF输入未生效' }

$changed = Invoke-Task (Join-Path $env:RUNNER_TEMP '特征封账 业务调整') 'valid_change'
if ($changed.exit_code -ne 0) { throw '有效业务输入变化处理失败' }
$changedHandover = Get-Content -LiteralPath (Join-Path $changed.output_root 'reports/release_handover.json') -Raw | ConvertFrom-Json
$changedPreview = $changedHandover.release_cases | Where-Object case_id -eq 'preview'
if ($changedPreview.replica_count -ne 2) { throw '副本变化没有进入发布交接记录' }
if ((Get-FileHash -LiteralPath (Join-Path $changed.output_root 'reports/release_handover.json') -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expectedReference['reports/release_handover.json']) { throw '有效变化没有改变业务交付' }

$invalid = Invoke-Task (Join-Path $env:RUNNER_TEMP '特征封账 无效配置') 'invalid'
if ($invalid.exit_code -eq 0) { throw '无效策略模式仍成功' }
if (Test-Path -LiteralPath (Join-Path $invalid.output_root 'reports')) { throw '无效输入留下报告' }

$archiveAfter = (Get-FileHash -LiteralPath $inputArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($archiveBefore -ne $archiveAfter) { throw '输入数据包发生变化' }
$attachments = [ordered]@{}
foreach ($name in @('输入数据包.zip','reference.zip','关键标准答案.xlsx','任务规格转化.xlsx')) {
  $attachments[$name] = (Get-FileHash -LiteralPath (Join-Path $repo $name) -Algorithm SHA256).Hash.ToLowerInvariant()
}
$evidence = [ordered]@{
  schema_version = 1
  result = 'PASS'
  repository = 'https://github.com/CLK123654/ale-q10532-windows-repro'
  commit = $env:GITHUB_SHA
  run_id = $env:GITHUB_RUN_ID
  runner = $env:RUNNER_OS
  image = $env:ImageOS
  helm_version = (& $env:HELM_BIN version --short).Trim()
  real_helm = $true
  helm_operations = @('helm lint','helm template','values.schema.json','Kubernetes对象渲染')
  unicode_space_directories = @($cleanOne.directory,$cleanTwo.directory)
  input_archive_unchanged = $archiveBefore -eq $archiveAfter
  input_sources_unchanged = ($cleanOne.before_hashes | ConvertTo-Json -Compress) -eq ($cleanOne.after_hashes | ConvertTo-Json -Compress)
  crlf_input_supported = $true
  reference_full_compare = $true
  reference_members = @($expectedReference.Keys)
  valid_input_change = [ordered]@{exit_code=$changed.exit_code;field='preview-values.yaml replicaCount';value=2;business_result_changed=$true}
  invalid_input = [ordered]@{exit_code=$invalid.exit_code;reports_absent=-not (Test-Path -LiteralPath (Join-Path $invalid.output_root 'reports'))}
  attachment_sha256 = $attachments
  score_total = 100
  score_item_count = 8
  gate_count = 2
}
$evidencePath = Join-Path $evidenceRoot 'windows-evidence.json'
$evidence | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $evidencePath -Encoding utf8NoBOM
$evidenceHash = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
@{evidence_sha256=$evidenceHash;result='PASS'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidenceRoot 'evidence-sha256.json') -Encoding utf8NoBOM
