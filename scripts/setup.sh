#!/usr/bin/env bash
# One-step setup for macOS and Linux (Debian/Ubuntu): installs the prerequisites, then the project dependencies.
#
# Safe to re-run. Tools that are already installed are skipped, and existing .env files are never overwritten.
#
# Usage, from the repo root:
#   bash scripts/setup.sh                 # install tools + set up the project
#   bash scripts/setup.sh --project-only  # skip installing tools
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ONLY=false
[[ "${1:-}" == "--project-only" ]] && PROJECT_ONLY=true

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32m%s\033[0m\n' "$1"; }
warn() { printf '    \033[33m%s\033[0m\n' "$1"; }
has()  { command -v "$1" >/dev/null 2>&1; }

OS="$(uname -s)"

node_ok() {
  has node && [[ "$(node --version | sed 's/^v//' | cut -d. -f1)" -ge 22 ]]
}

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
install_macos() {
  if ! has brew; then
    warn "Homebrew is required. Install it from https://brew.sh, then run this script again."
    exit 1
  fi
  has git || brew install git
  has uv || brew install uv
  node_ok || brew install node
  has gdalinfo || brew install gdal
  if ! has docker; then
    brew install --cask docker
    DOCKER_JUST_INSTALLED=true
  fi
}

install_linux() {
  if ! has apt-get; then
    warn "Automatic install supports Debian/Ubuntu (apt). On other distros, install git, uv, Node.js 22+,"
    warn "Docker and GDAL yourself, then run: bash scripts/setup.sh --project-only"
    exit 1
  fi
  sudo apt-get update
  sudo apt-get install -y git curl ca-certificates binutils gdal-bin libgdal-dev libproj-dev
  if ! has uv; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
  fi
  if ! node_ok; then
    curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
    sudo apt-get install -y nodejs
  fi
  if ! has docker; then
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER" || true
    DOCKER_JUST_INSTALLED=true
  fi
}

DOCKER_JUST_INSTALLED=false
if ! $PROJECT_ONLY; then
  step "Installing prerequisites (skipping any already installed)"
  case "$OS" in
    Darwin) install_macos ;;
    Linux)  install_linux ;;
    *) warn "Unsupported OS: $OS. On Windows, use setup.cmd instead."; exit 1 ;;
  esac
  ok "git $(git --version | awk '{print $3}'), uv $(uv --version | awk '{print $2}'), node $(node --version)"
fi

# ---------------------------------------------------------------------------
# 2. Docker must be running for the database
# ---------------------------------------------------------------------------
step "Checking that Docker is running"
if ! docker info >/dev/null 2>&1; then
  if [[ "$OS" == "Darwin" ]]; then
    echo "    Starting Docker Desktop and waiting for it (up to 3 minutes)..."
    open -a Docker || true
  else
    sudo systemctl start docker 2>/dev/null || true
  fi
  for _ in $(seq 1 36); do docker info >/dev/null 2>&1 && break; sleep 5; done
fi
if ! docker info >/dev/null 2>&1; then
  if $DOCKER_JUST_INSTALLED; then
    warn "Docker was just installed. On macOS, open Docker Desktop once and accept its terms."
    warn "On Linux, sign out and back in so your user can run docker. Then run this script again."
  else
    warn "Docker is not running. Start Docker, then run this script again."
  fi
  exit 1
fi
ok "Docker is running"

# ---------------------------------------------------------------------------
# 3. Environment files
# ---------------------------------------------------------------------------
step "Creating environment files"
if [[ -f "$ROOT/.env" ]]; then ok ".env already exists (left unchanged)"
else cp "$ROOT/.env.example" "$ROOT/.env"; ok "Created .env"; fi

BACKEND_ENV="$ROOT/backend/.env"
if [[ -f "$BACKEND_ENV" ]]; then
  ok "backend/.env already exists (left unchanged)"
else
  cp "$ROOT/backend/.env.example" "$BACKEND_ENV"
  ok "Created backend/.env"
  # Homebrew on Apple Silicon installs GDAL where Django may not look; point at it explicitly.
  if [[ "$OS" == "Darwin" ]] && has brew; then
    BREW_LIB="$(brew --prefix)/lib"
    if [[ -f "$BREW_LIB/libgdal.dylib" ]]; then
      sed -i.bak \
        -e "s|^# GDAL_LIBRARY_PATH=.*|GDAL_LIBRARY_PATH=$BREW_LIB/libgdal.dylib|" \
        -e "s|^# GEOS_LIBRARY_PATH=.*|GEOS_LIBRARY_PATH=$BREW_LIB/libgeos_c.dylib|" \
        "$BACKEND_ENV" && rm -f "$BACKEND_ENV.bak"
      ok "Set GDAL/GEOS library paths for Homebrew in backend/.env"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4. Backend packages and secret key
# ---------------------------------------------------------------------------
step "Installing backend packages (uv sync)"
cd "$ROOT/backend"
uv sync
if grep -q '^DJANGO_SECRET_KEY=change-me' "$BACKEND_ENV"; then
  KEY="$(uv run python -c 'import secrets; print(secrets.token_urlsafe(50))')"
  # Write with Python so the key needs no shell escaping.
  KEY="$KEY" uv run python - "$BACKEND_ENV" <<'PY'
import os, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
with open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(text.replace("DJANGO_SECRET_KEY=change-me", "DJANGO_SECRET_KEY=" + os.environ["KEY"], 1))
PY
  ok "Generated DJANGO_SECRET_KEY in backend/.env"
fi

# ---------------------------------------------------------------------------
# 5. Database
# ---------------------------------------------------------------------------
step "Starting the database (PostGIS in Docker)"
cd "$ROOT"
docker compose up -d --wait

step "Applying database migrations"
cd "$ROOT/backend"
uv run python manage.py migrate

# ---------------------------------------------------------------------------
# 6. Frontend packages
# ---------------------------------------------------------------------------
step "Installing frontend packages (npm ci)"
cd "$ROOT/frontend"
npm ci

# ---------------------------------------------------------------------------
printf '\n\033[32mSetup complete.\033[0m\n'
cat <<'EOF'

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

If a command is "not found", open a new terminal so it picks up the new PATH.
EOF
