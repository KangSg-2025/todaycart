# 오늘 장보기 자료 갱신 — 이 PC에 한 번만 설정
#   · Git · Dart · 인증키 파일 확인
#   · 매주 일요일 오전 10시 자동 실행 등록 (작업 스케줄러 「TodayCart data update」)
#   · -RunNow 를 붙이면 바코드 전체 첫 받기(약 3시간)를 바로 시작 (창이 따로 열림)
#
# 실행 (PowerShell에서, 저장소 폴더 안의 tools 에서):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\setup_schedule.ps1 -RunNow
param(
  [string]$Repo = (Split-Path -Parent $PSScriptRoot),
  [switch]$RunNow
)

$ok = $true
function Test-Need([string]$what, [bool]$good, [string]$help) {
  if ($good) { Write-Host "  [OK] $what" -ForegroundColor Green }
  else { Write-Host "  [없음] $what — $help" -ForegroundColor Red; $script:ok = $false }
}

Write-Host "저장소: $Repo"
Test-Need 'Git' ([bool](Get-Command git -ErrorAction SilentlyContinue)) 'https://git-scm.com 에서 설치'
Test-Need 'Dart' ([bool](Get-Command dart -ErrorAction SilentlyContinue)) 'Flutter 설치 또는 https://dart.dev/get-dart (PATH에 추가)'
$keys = Join-Path $env:USERPROFILE '.todaycart\api_keys.json'
Test-Need "인증키 파일 ($keys)" (Test-Path $keys) '개발 PC의 같은 위치 파일을 복사해 오기'
foreach ($f in 'update_data.ps1', 'fetch_prices.dart', 'fetch_barcodes.dart') {
  Test-Need "tools\$f" (Test-Path (Join-Path $Repo "tools\$f")) 'GitHub에서 Pull 해서 최신 파일 받기'
}
Test-Need 'CNAME (홈페이지 저장소 맞는지)' (Test-Path (Join-Path $Repo 'CNAME')) '홈페이지 저장소 폴더에서 실행했는지 확인'
if (-not $ok) { Write-Host "`n위 [없음]을 해결한 뒤 다시 실행하세요." -ForegroundColor Yellow; exit 1 }

$script = Join-Path $Repo 'tools\update_data.ps1'
$arg = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg -WorkingDirectory $Repo
$trigger = New-ScheduledTaskTrigger -Daily -At 9pm
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 5)
Register-ScheduledTask -TaskName 'TodayCart data update' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Write-Host "`n[OK] 매일 밤 9시 자동 실행 등록 (작업 스케줄러: TodayCart data update)" -ForegroundColor Green

if ($RunNow) {
  Write-Host '바코드 전체 첫 받기를 새 창에서 시작합니다 (약 3시간, 창을 닫지 마세요).'
  Start-Process powershell.exe -ArgumentList "$arg -FullBarcodes" -WorkingDirectory $Repo
}
Write-Host "기록: $env:USERPROFILE\.todaycart\update_날짜.log"
