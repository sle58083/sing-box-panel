Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $ProjectRoot

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message"
}

function Write-WarnLine {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Assert-FileExists {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing required file: $Path"
    }
    Write-Info "Found $Path"
}

Write-Info "Checking sing-box-panel project on Windows PowerShell..."
Write-WarnLine "Do not run install.sh or uninstall.sh in native Windows."
Write-WarnLine "Bash syntax checks must be run in Linux, WSL, or a VPS: bash -n install.sh && bash -n uninstall.sh"

$RequiredFiles = @(
    "install.sh",
    "uninstall.sh",
    "README.md",
    "LICENSE",
    "backend/app.py",
    "backend/db.py",
    "backend/auth.py",
    "backend/singbox.py",
    "backend/expire_worker.py",
    "backend/requirements.txt",
    "backend/static/index.html",
    "backend/static/login.html",
    "backend/static/app.js",
    "backend/static/style.css",
    "systemd/sing-box-panel.service",
    "systemd/sing-box-panel-expire.service",
    "systemd/sing-box-panel-expire.timer"
)

foreach ($File in $RequiredFiles) {
    Assert-FileExists $File
}

$Python = Get-Command python -ErrorAction SilentlyContinue
if (-not $Python) {
    throw "python was not found in PATH. Install Python or add it to PATH."
}

Write-Info "Using Python: $($Python.Source)"

$PythonFiles = Get-ChildItem -LiteralPath "backend" -Filter "*.py" -File | Sort-Object Name
if (-not $PythonFiles) {
    throw "No Python files found under backend/"
}

$Args = @("-m", "py_compile") + ($PythonFiles | ForEach-Object { $_.FullName })
& python @Args
if ($LASTEXITCODE -ne 0) {
    throw "Python syntax check failed."
}

Write-Info "Python syntax check passed for backend/*.py"
Write-Info "Windows project check completed."
