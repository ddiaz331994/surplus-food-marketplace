<#
.SYNOPSIS
  One-step setup for Windows: installs the prerequisites, then the project dependencies.

.DESCRIPTION
  Safe to re-run. Tools that are already installed are skipped, and existing .env files are never overwritten.

  Installs (if missing): Git, uv, Node.js LTS, Docker Desktop (via winget) and GDAL/GEOS/PROJ (via OSGeo4W).
  Then: creates .env files, generates a Django secret key, installs backend (uv) and frontend (npm)
  packages, starts the PostGIS container and applies migrations.

.EXAMPLE
  # From the repo root (or double-click setup.cmd):
  powershell -ExecutionPolicy Bypass -File scripts\setup.ps1

.EXAMPLE
  # Skip installing tools; only set up the project:
  powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -ProjectOnly
#>
param([switch]$ProjectOnly)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$OSGeo4WRoot = 'C:\OSGeo4W'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Has($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Assert-ExitCode($what) {
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit code $LASTEXITCODE)" }
}

function Install-WithWinget($id, $name) {
    if (-not (Has winget)) {
        throw "winget was not found. Install 'App Installer' from the Microsoft Store, then run this script again."
    }
    Write-Host "    Installing $name with winget..."
    winget install -e --id $id --silent --accept-source-agreements --accept-package-agreements
    Assert-ExitCode "Installing $name"
    Update-SessionPath
}

function Test-DockerRunning {
    # Windows PowerShell 5.1 turns redirected native stderr into errors; don't let that abort the check.
    $ErrorActionPreference = 'Continue'
    docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
$dockerJustInstalled = $false

if (-not $ProjectOnly) {
    Step 'Checking prerequisites'

    if (Has git) { Ok "Git: $(git --version)" } else { Install-WithWinget 'Git.Git' 'Git' }

    if (Has uv) { Ok "uv: $(uv --version)" } else { Install-WithWinget 'astral-sh.uv' 'uv' }

    $nodeOk = $false
    if (Has node) {
        $major = [int]((node --version).TrimStart('v').Split('.')[0])
        $nodeOk = $major -ge 22
    }
    if ($nodeOk) { Ok "Node.js: $(node --version)" } else { Install-WithWinget 'OpenJS.NodeJS.LTS' 'Node.js LTS' }

    if (Has docker) {
        Ok "Docker: $(docker --version)"
    } else {
        Install-WithWinget 'Docker.DockerDesktop' 'Docker Desktop'
        $dockerJustInstalled = $true
    }

    if (Get-ChildItem "$OSGeo4WRoot\bin" -Filter 'gdal*.dll' -ErrorAction SilentlyContinue) {
        Ok "GDAL: found in $OSGeo4WRoot"
    } else {
        Write-Host "    Installing GDAL/GEOS/PROJ with OSGeo4W into $OSGeo4WRoot (a few minutes)..."
        $tmp = Join-Path $env:TEMP 'osgeo4w-setup'
        New-Item -ItemType Directory -Force $tmp | Out-Null
        $installer = Join-Path $tmp 'osgeo4w-setup.exe'
        Invoke-WebRequest 'https://download.osgeo.org/osgeo4w/v2/osgeo4w-setup.exe' -OutFile $installer -UseBasicParsing
        $installerArgs = '-q', '-k', '-n', '-O', '-s', 'https://download.osgeo.org/osgeo4w/v2/', '-R', $OSGeo4WRoot, '-l', "$tmp\pkgs", '-P', 'gdal,geos,proj'
        $p = Start-Process -FilePath $installer -ArgumentList $installerArgs -WorkingDirectory $tmp -Wait -PassThru
        if ($p.ExitCode -ne 0 -or -not (Get-ChildItem "$OSGeo4WRoot\bin" -Filter 'gdal*.dll' -ErrorAction SilentlyContinue)) {
            throw "OSGeo4W install failed (exit code $($p.ExitCode)). See $tmp\setup.log"
        }
        Ok "GDAL installed in $OSGeo4WRoot"
    }
}

# ---------------------------------------------------------------------------
# 2. Docker must be running for the database
# ---------------------------------------------------------------------------
Step 'Checking that Docker is running'
if (-not (Test-DockerRunning)) {
    $desktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (Test-Path $desktop) {
        Write-Host '    Starting Docker Desktop and waiting for it (up to 3 minutes)...'
        Start-Process $desktop
        $deadline = (Get-Date).AddMinutes(3)
        while (-not (Test-DockerRunning) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
    }
}
if (-not (Test-DockerRunning)) {
    if ($dockerJustInstalled) {
        Warn 'Docker Desktop was just installed. Restart Windows (or sign out and in), open Docker Desktop once'
        Warn 'and accept its terms, then run this script again.'
    } else {
        Warn 'Docker is not running. Open Docker Desktop, wait until it says "running", then run this script again.'
    }
    exit 1
}
Ok 'Docker is running'

# ---------------------------------------------------------------------------
# 3. Environment files
# ---------------------------------------------------------------------------
Step 'Creating environment files'
$rootEnv = Join-Path $Root '.env'
$backendEnv = Join-Path $Root 'backend\.env'

if (Test-Path $rootEnv) { Ok '.env already exists (left unchanged)' }
else { Copy-Item (Join-Path $Root '.env.example') $rootEnv; Ok 'Created .env' }

if (Test-Path $backendEnv) { Ok 'backend\.env already exists (left unchanged)' }
else { Copy-Item (Join-Path $Root 'backend\.env.example') $backendEnv; Ok 'Created backend\.env' }

# ---------------------------------------------------------------------------
# 4. Backend packages and secret key
# ---------------------------------------------------------------------------
Step 'Installing backend packages (uv sync)'
Push-Location (Join-Path $Root 'backend')
try {
    uv sync
    Assert-ExitCode 'uv sync'

    $content = [IO.File]::ReadAllText($backendEnv)
    if ($content.Contains('DJANGO_SECRET_KEY=change-me')) {
        $key = uv run python -c "import secrets; print(secrets.token_urlsafe(50))"
        Assert-ExitCode 'Generating a secret key'
        $content = $content.Replace('DJANGO_SECRET_KEY=change-me', "DJANGO_SECRET_KEY=$($key.Trim())")
        [IO.File]::WriteAllText($backendEnv, $content, (New-Object Text.UTF8Encoding $false))
        Ok 'Generated DJANGO_SECRET_KEY in backend\.env'
    }
} finally { Pop-Location }

# ---------------------------------------------------------------------------
# 5. Database
# ---------------------------------------------------------------------------
Step 'Starting the database (PostGIS in Docker)'
Push-Location $Root
try {
    docker compose up -d --wait
    Assert-ExitCode 'docker compose up'
} finally { Pop-Location }

Step 'Applying database migrations'
Push-Location (Join-Path $Root 'backend')
try {
    uv run python manage.py migrate
    Assert-ExitCode 'migrate'
} finally { Pop-Location }

# ---------------------------------------------------------------------------
# 6. Frontend packages
# ---------------------------------------------------------------------------
Step 'Installing frontend packages (npm ci)'
Push-Location (Join-Path $Root 'frontend')
try {
    npm ci
    Assert-ExitCode 'npm ci'
} finally { Pop-Location }

# ---------------------------------------------------------------------------
Write-Host "`nSetup complete." -ForegroundColor Green
Write-Host @'

Next steps:
  1. Create your admin login (first time only):
       cd backend
       uv run python manage.py createsuperuser

  2. Start the backend (terminal 1):
       cd backend
       uv run python manage.py runserver

  3. Start the frontend (terminal 2):
       cd frontend
       npm run dev

  4. Open http://localhost:5173  (admin: http://localhost:5173/admin/)

If a command is "not recognized", close this terminal and open a new one so it picks up the new PATH.
'@
