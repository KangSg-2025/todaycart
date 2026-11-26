# Today Cart: update reference prices + barcode data on THIS PC, then push to GitHub.
# (Korean public APIs return HTTP 403 to GitHub Actions servers abroad, so this runs at home.)
#
# Run (PowerShell):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\update_data.ps1
#   first time only (all ~260k barcodes, about 3 hours):  ... -FullBarcodes
#
# Keys: %USERPROFILE%\.todaycart\api_keys.json  (NOT in this repository)
#   { "DATA_GO_KR_KEY": "...", "FOOD_SAFETY_KOREA_KEY": "..." }
# Log:  %USERPROFILE%\.todaycart\update_YYYYMMDD_HHmm.log
param(
  [string]$Repo = (Split-Path -Parent $PSScriptRoot),
  [string]$Keys = (Join-Path $env:USERPROFILE '.todaycart\api_keys.json'),
  [switch]$FullBarcodes
)

$home2 = Join-Path $env:USERPROFILE '.todaycart'
New-Item -ItemType Directory -Force $home2 | Out-Null
$log = Join-Path $home2 ("update_" + (Get-Date -Format 'yyyyMMdd_HHmm') + ".log")
Start-Transcript -Path $log | Out-Null

try {
  if (-not (Test-Path $Keys)) { throw "keys file not found: $Keys" }
  $k = Get-Content -Raw -Encoding UTF8 $Keys | ConvertFrom-Json
  $env:DATA_GO_KR_KEY = $k.DATA_GO_KR_KEY
  $env:FOOD_SAFETY_KOREA_KEY = $k.FOOD_SAFETY_KOREA_KEY

  # never wait forever on a stalled network (11/26 19:10 run hung in git fetch)
  $env:GIT_TERMINAL_PROMPT = "0"
  $env:GIT_HTTP_LOW_SPEED_LIMIT = "1000"
  $env:GIT_HTTP_LOW_SPEED_TIME = "60"
  Set-Location $Repo
  git pull --rebase

  # 1) reference prices (skips by itself when the survey day has not changed)
  dart run tools/fetch_prices.dart prices

  # 2) barcodes: first time = full (~3h), afterwards = changes of the last 7 days
  if ($FullBarcodes) {
    dart run tools/fetch_barcodes.dart barcodes --full
  } else {
    dart run tools/fetch_barcodes.dart barcodes
  }

  foreach ($d in 'prices', 'barcodes') { if (Test-Path $d) { git add $d } }
  git diff --cached --quiet -- . ':!barcodes/version.json'
  if ($LASTEXITCODE -ne 0) {
    git commit -m "update prices and barcodes"
    git push
  } else {
    Write-Output "nothing changed"
  }
} catch {
  Write-Output ("ERROR: " + $_.Exception.Message)
} finally {
  Stop-Transcript | Out-Null
}
