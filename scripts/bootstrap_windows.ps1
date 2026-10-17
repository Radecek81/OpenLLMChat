$ErrorActionPreference = "Stop"

$ResourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$PayloadRoot = Join-Path $ResourceRoot "payload"
$AppSupportRoot = Join-Path $env:LOCALAPPDATA "LLM Chat"
$AppRoot = Join-Path $AppSupportRoot "app"
$DataRoot = Join-Path $AppSupportRoot "data"
$DataDir = Join-Path $DataRoot "conversations"
$VenvRoot = Join-Path $AppSupportRoot ".venv"
$VenvPython = Join-Path $VenvRoot "Scripts\python.exe"
$HashFile = Join-Path $AppSupportRoot "requirements.sha256"
$AppPort = if ($env:APP_PORT) { $env:APP_PORT } else { "8000" }
$AppPublicUrl = if ($env:APP_PUBLIC_URL) { $env:APP_PUBLIC_URL } else { "http://127.0.0.1:$AppPort" }
$AppReload = if ($env:APP_RELOAD) { $env:APP_RELOAD } else { "false" }
$AutoOpenBrowser = if ($env:AUTO_OPEN_BROWSER) { $env:AUTO_OPEN_BROWSER } else { "true" }

function Resolve-Python {
  if (Get-Command py -ErrorAction SilentlyContinue) {
    return @{
      Exe = "py"
      Prefix = @("-3")
    }
  }
  if (Get-Command python -ErrorAction SilentlyContinue) {
    return @{
      Exe = "python"
      Prefix = @()
    }
  }
  if (Get-Command python3 -ErrorAction SilentlyContinue) {
    return @{
      Exe = "python3"
      Prefix = @()
    }
  }
  throw "Python 3 nebyl nalezen. Nainstaluj Python 3 pro Windows a spust aplikaci znovu."
}

function Invoke-SystemPython {
  param([string[]]$Arguments)

  $python = Resolve-Python
  & $python.Exe @($python.Prefix + $Arguments)
  if ($LASTEXITCODE -ne 0) {
    throw "Volani systemoveho Pythonu selhalo s kodem $LASTEXITCODE."
  }
}

function Test-PythonVersion {
  $python = Resolve-Python
  & $python.Exe @($python.Prefix + @("-c", "import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)"))
  if ($LASTEXITCODE -ne 0) {
    throw "Je potreba Python 3.11 nebo novejsi. Aktualni Python je prilis stary."
  }
}

function Invoke-VenvPython {
  param([string[]]$Arguments)

  & $VenvPython @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Volani Pythonu z virtualniho prostredi selhalo s kodem $LASTEXITCODE."
  }
}

function Sync-Payload {
  New-Item -ItemType Directory -Force -Path $AppSupportRoot, $AppRoot, $DataDir | Out-Null
  & robocopy $PayloadRoot $AppRoot /MIR /XD conversations dist .venv __pycache__ /XF *.pyc *.pyo *.zip *.dmg /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) {
    throw "Kopie aplikace do runtime slozky selhala (robocopy exit code $LASTEXITCODE)."
  }
}

function Install-Deps {
  $requirementsPath = Join-Path $AppRoot "requirements.txt"
  $nextHash = (Get-FileHash -Algorithm SHA256 $requirementsPath).Hash.ToLowerInvariant()
  $currentHash = ""

  if (Test-Path $HashFile) {
    $currentHash = (Get-Content $HashFile -Raw).Trim().ToLowerInvariant()
  }

  if (-not (Test-Path $VenvPython)) {
    Invoke-SystemPython @("-m", "venv", $VenvRoot)
  }

  if ($nextHash -ne $currentHash) {
    Invoke-VenvPython @("-m", "pip", "install", "--upgrade", "pip")
    Invoke-VenvPython @("-m", "pip", "install", "-r", $requirementsPath)
    Set-Content -Path $HashFile -Value $nextHash -NoNewline
  }
}

function Open-Browser {
  if ($AutoOpenBrowser -ne "true") {
    return
  }
  Start-Job -ScriptBlock {
    param($Url)
    Start-Sleep -Seconds 2
    Start-Process $Url | Out-Null
  } -ArgumentList $AppPublicUrl | Out-Null
}

function Test-PortBusy {
  try {
    $connections = Get-NetTCPConnection -State Listen -LocalPort ([int]$AppPort) -ErrorAction SilentlyContinue
    return [bool]$connections
  }
  catch {
    return $false
  }
}

Write-Host "LLM Chat bootstrap"
Write-Host "Runtime: $AppSupportRoot"

Test-PythonVersion
Sync-Payload
Install-Deps

if (Test-PortBusy) {
  Write-Host "Na portu $AppPort uz neco bezi. Oteviram $AppPublicUrl."
  Open-Browser
  exit 0
}

Write-Host "Spoustim aplikaci na $AppPublicUrl"
Open-Browser

Set-Location $AppRoot
$env:APP_PORT = $AppPort
$env:APP_PUBLIC_URL = $AppPublicUrl
$env:APP_RELOAD = $AppReload
$env:AUTO_OPEN_BROWSER = "false"
$env:LLM_CHAT_DATA_DIR = $DataDir

Invoke-VenvPython @((Join-Path $AppRoot "main.py"))
