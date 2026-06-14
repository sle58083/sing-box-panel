Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $ProjectRoot

$Failures = 0

function Pass {
    param([string]$Message)
    Write-Host "PASS $Message" -ForegroundColor Green
}

function Fail {
    param([string]$Message)
    $script:Failures += 1
    Write-Host "FAIL $Message" -ForegroundColor Red
}

function Warn {
    param([string]$Message)
    Write-Host "WARN $Message" -ForegroundColor Yellow
}

function Test-RequiredFile {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Pass "Found $Path"
    } else {
        Fail "Missing required file: $Path"
    }
}

function Test-FileContains {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Message
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "Cannot inspect missing file: $Path"
        return
    }
    $Content = Get-Content -LiteralPath $Path -Raw
    if ($Content -match $Pattern) {
        Pass $Message
    } else {
        Fail $Message
    }
}

Write-Host "sing-box-panel Windows project check"
Warn "Do not run install.sh or uninstall.sh in native Windows."
Warn "bash -n checks must be run in Linux, WSL, or a VPS."

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
    "systemd/sing-box-panel-expire.timer",
    "scripts/test-vps.sh"
)

foreach ($File in $RequiredFiles) {
    Test-RequiredFile $File
}

Test-FileContains "backend/requirements.txt" "fastapi" "requirements.txt contains fastapi"
Test-FileContains "backend/requirements.txt" "uvicorn" "requirements.txt contains uvicorn"

$InstallText = if (Test-Path -LiteralPath "install.sh" -PathType Leaf) { Get-Content -LiteralPath "install.sh" -Raw } else { "" }
$ReadmeText = if (Test-Path -LiteralPath "README.md" -PathType Leaf) { Get-Content -LiteralPath "README.md" -Raw } else { "" }
$PlaceholderMine = "$([char]0x6211)$([char]0x7684)GitHub$([char]0x7528)$([char]0x6237)$([char]0x540D)"
$PlaceholderYours = "$([char]0x4F60)$([char]0x7684)GitHub$([char]0x7528)$([char]0x6237)$([char]0x540D)"
$PlaceholderRepo = "$([char]0x4ED3)$([char]0x5E93)$([char]0x540D)"
$Placeholders = @($PlaceholderMine, $PlaceholderYours, $PlaceholderRepo)
$FoundPlaceholder = $false
foreach ($Placeholder in $Placeholders) {
    if ($InstallText.Contains($Placeholder) -or $ReadmeText.Contains($Placeholder)) {
        Fail "Placeholder still exists: $Placeholder"
        $FoundPlaceholder = $true
    }
}
if (-not $FoundPlaceholder) {
    Pass "No GitHub username/repo placeholders found in install.sh or README.md"
}

if ($InstallText -match 'OWNER="\$\{PANEL_OWNER:-sle58083\}"' -and
    $InstallText -match 'REPO="\$\{PANEL_REPO:-sing-box-panel\}"' -and
    $InstallText -match 'BRANCH="\$\{PANEL_BRANCH:-main\}"' -and
    $InstallText -match 'ARCHIVE_URL="https://github.com/\$\{OWNER\}/\$\{REPO\}/archive/refs/heads/\$\{BRANCH\}\.tar\.gz"') {
    Pass "install.sh has GitHub owner/repo/branch archive download variables"
} else {
    Fail "install.sh is missing expected GitHub owner/repo/branch archive download variables"
}

if ($ReadmeText -match 'bash <\(wget -qO- https://raw\.githubusercontent\.com/sle58083/sing-box-panel/main/install\.sh\)') {
    Pass "README.md contains correct one-click install raw URL"
} else {
    Fail "README.md does not contain the expected one-click install raw URL"
}

if ($ReadmeText -match 'bash <\(wget -qO- https://raw\.githubusercontent\.com/sle58083/sing-box-panel/main/uninstall\.sh\)') {
    Pass "README.md contains correct one-click uninstall raw URL"
} else {
    Fail "README.md does not contain the expected one-click uninstall raw URL"
}

$Python = Get-Command python -ErrorAction SilentlyContinue
if ($Python) {
    Pass "python found: $($Python.Source)"
    $PythonFiles = Get-ChildItem -LiteralPath "backend" -Filter "*.py" -File | Sort-Object Name
    if ($PythonFiles.Count -gt 0) {
        & python @("-m", "py_compile") @($PythonFiles | ForEach-Object { $_.FullName })
        if ($LASTEXITCODE -eq 0) {
            Pass "Python syntax check passed for backend/*.py"
        } else {
            Fail "Python syntax check failed for backend/*.py"
        }
    } else {
        Fail "No Python files found under backend/"
    }
} else {
    Fail "python was not found in PATH"
}

if ($Failures -eq 0) {
    Write-Host "PASS Windows project check completed with 0 failures." -ForegroundColor Green
    exit 0
}

Write-Host "FAIL Windows project check completed with $Failures failure(s)." -ForegroundColor Red
exit 1
