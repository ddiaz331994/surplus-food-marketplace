# Surplus Food Marketplace

A two-sided marketplace: food vendors list surplus food at a discount, and nearby consumers reserve it and pick it up in store.

- **Backend:** Django 6 + Django REST Framework on Postgres/PostGIS (GeoDjango), managed with [uv](https://docs.astral.sh/uv/)
- **Frontend:** React + TypeScript (Vite), Tailwind, shadcn/ui, TanStack Query
- **Database:** Postgres 17 + PostGIS 3.5 in Docker

System design: [`docs/design.md`](docs/design.md). Wireframes: [`docs/wireframes/`](docs/wireframes/). Rules for contributors (and AI assistants): [`CLAUDE.md`](CLAUDE.md).

---

## Contents

0. [Quick setup (one command)](#quick-setup-one-command)
1. [Run the app on a new device (for testing)](#1-run-the-app-on-a-new-device-for-testing)
2. [Set up a device to contribute](#2-set-up-a-device-to-contribute)
3. [Command reference](#3-command-reference)
4. [Troubleshooting](#4-troubleshooting)

---

## Quick setup (one command)

A setup script installs everything for you: the tools (Git, uv, Node.js, Docker, GDAL), the `.env` files with a generated secret key, the backend and frontend packages, and the database. It is safe to run again: it skips anything already installed and never overwrites your `.env` files.

**1. Get the code.** You need Git to clone. If you don't have it yet, download the ZIP from the GitHub repo page (**Code → Download ZIP**) and unzip it instead.

```sh
git clone https://github.com/ddiaz331994/surplus-food-marketplace.git
cd surplus-food-marketplace
```

**2. Run the setup script.**

| OS | Command (from the repo root) |
| --- | --- |
| Windows | Double-click `setup.cmd`, or run `.\setup.cmd` in a terminal |
| macOS / Linux (Debian/Ubuntu) | `bash scripts/setup.sh` |

If you already have the tools and only want the project set up, run `.\setup.cmd -ProjectOnly` (Windows) or `bash scripts/setup.sh --project-only` (macOS/Linux).

**3. Follow the "Next steps" it prints.** Create your admin login, start the backend and frontend, and open http://localhost:5173. These are the same as [1.5](#15-set-up-and-start-the-backend) to [1.7](#17-open-the-app) below.

Notes:
- **Docker first run:** if Docker gets installed during setup, the script stops and asks you to restart (Windows), open Docker Desktop once (macOS) or sign out and back in (Linux). Run the script again afterwards and it picks up where it left off.
- **Requirements:** Windows needs `winget`, which is built into Windows 10/11. macOS needs [Homebrew](https://brew.sh). Linux setup uses `sudo` for apt and Docker.
- **If the script fails:** it shows which step failed. The manual steps below do the same thing one at a time.

---

## 1. Run the app on a new device (for testing)

Follow this section if you only want to get the app running and click around. The [quick setup](#quick-setup-one-command) script does all the installing in steps 1.1 to 1.6 for you. You still create the admin login and start the servers yourself.

### 1.1 Install the prerequisites

| Tool | Version | Why |
| --- | --- | --- |
| Git | any recent | Clone the repo |
| Docker Desktop (or Docker Engine) | any recent | Runs Postgres + PostGIS |
| uv | 0.12+ | Installs Python 3.13 and the backend packages |
| Node.js | 24 LTS | Runs the frontend |
| GDAL / GEOS / PROJ | GDAL 3.x | Native geo libraries GeoDjango needs on the machine running Django |

You do **not** need to install Python yourself. uv downloads Python 3.13 automatically.

<details open>
<summary><b>Windows 10/11</b> (PowerShell)</summary>

```powershell
winget install Git.Git
winget install Docker.DockerDesktop
winget install astral-sh.uv
winget install OpenJS.NodeJS.LTS
```

Install GDAL, GEOS and PROJ with OSGeo4W, unattended, into `C:\OSGeo4W`:

```powershell
cd $env:TEMP
Invoke-WebRequest https://download.osgeo.org/osgeo4w/v2/osgeo4w-setup.exe -OutFile osgeo4w-setup.exe
Start-Process .\osgeo4w-setup.exe -Wait -ArgumentList '-q','-k','-n','-O','-s','https://download.osgeo.org/osgeo4w/v2/','-R','C:\OSGeo4W','-l',"$env:TEMP\osgeo4w-pkgs",'-P','gdal,geos,proj'
```

Optional: add `C:\OSGeo4W\bin` to your user PATH so `gdalinfo` works in any terminal. Django finds GDAL without this.

```powershell
[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';C:\OSGeo4W\bin', 'User')
```

Close and reopen your terminal afterwards, then **start Docker Desktop** and wait until it says it is running.

> Use `python` or `py` on Windows, not `python3`. `python3` opens the Microsoft Store.

</details>

<details>
<summary><b>macOS</b> (Homebrew)</summary>

```sh
brew install git uv node@24 gdal
brew install --cask docker
```

Start Docker Desktop from Applications.

If Django later reports that it cannot find GDAL (common on Apple Silicon), add these two lines to `backend/.env`:

```
GDAL_LIBRARY_PATH=/opt/homebrew/lib/libgdal.dylib
GEOS_LIBRARY_PATH=/opt/homebrew/lib/libgeos_c.dylib
```

</details>

<details>
<summary><b>Linux</b> (Debian/Ubuntu)</summary>

```sh
sudo apt update
sudo apt install -y git binutils gdal-bin libgdal-dev libproj-dev
curl -LsSf https://astral.sh/uv/install.sh | sh
# Node 24: use nvm (https://github.com/nvm-sh/nvm) or your distro's NodeSource package
# Docker Engine: https://docs.docker.com/engine/install/
```

</details>

Check everything is installed:

```sh
git --version
docker --version
docker compose version
uv --version
node --version      # v24.x
gdalinfo --version  # Windows: C:\OSGeo4W\bin\gdalinfo --version
```

### 1.2 Get the code

The repository is private, so your GitHub account needs access to it.

```sh
git clone https://github.com/ddiaz331994/surplus-food-marketplace.git
cd surplus-food-marketplace
```

### 1.3 Create the environment files

There are two `.env` files. Neither is committed to git.

```sh
# Root: used by docker compose
cp .env.example .env

# Backend: used by Django
cp backend/.env.example backend/.env
```

(On Windows PowerShell, `cp` works too, or use `Copy-Item`.)

Generate a secret key and paste it into `backend/.env` as `DJANGO_SECRET_KEY=...`:

```sh
cd backend
uv run python -c "import secrets; print(secrets.token_urlsafe(50))"
cd ..
```

The defaults in both files already match each other. Change them only if port 5432 is taken (see [Troubleshooting](#4-troubleshooting)).

### 1.4 Start the database

From the repo root:

```sh
docker compose up -d --wait
```

The first run downloads the PostGIS image, which takes a minute. The data persists in a Docker volume between restarts.

### 1.5 Set up and start the backend

Open a terminal in the repo root:

```sh
cd backend
uv sync                                  # installs Python 3.13 + all backend packages into backend/.venv
uv run python manage.py migrate          # creates the tables
uv run python manage.py createsuperuser  # your login for the admin (email + password)
uv run python manage.py runserver        # http://127.0.0.1:8000
```

Leave this terminal running.

### 1.6 Set up and start the frontend

Open a **second** terminal in the repo root:

```sh
cd frontend
npm ci          # installs exact versions from package-lock.json
npm run dev     # http://localhost:5173
```

### 1.7 Open the app

| URL | What |
| --- | --- |
| http://localhost:5173 | The React app. The "API status" card should say `ok, PostGIS 3.5.x` |
| http://localhost:5173/admin/ | Django admin. Log in with the superuser you created |
| http://127.0.0.1:8000/api/docs/ | Interactive API docs (Swagger) |
| http://127.0.0.1:8000/api/health/ | Raw health check JSON |

In development, the frontend forwards `/api` and `/admin` to Django on port 8000, so both run on one origin and login cookies work.

### 1.8 Stopping and starting again

- Stop the servers with `Ctrl+C` in each terminal.
- Stop the database with `docker compose stop`. Your data is kept.
- Next time, run `docker compose up -d`, then `runserver` in `backend/` and `npm run dev` in `frontend/`.
- After pulling new code, run `uv sync` and `uv run python manage.py migrate` in `backend/`, and `npm ci` in `frontend/`.

---

## 2. Set up a device to contribute

Do everything in [section 1](#1-run-the-app-on-a-new-device-for-testing) first, then the steps below.

### 2.1 Git identity and GitHub access

```sh
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

Install the GitHub CLI (Windows: `winget install GitHub.cli`, macOS: `brew install gh`), then log in:

```sh
gh auth login
```

### 2.2 Editor (recommended: VS Code)

Useful extensions:

- **Python** and **Ruff** (`charliermarsh.ruff`) for backend linting and formatting
- **Tailwind CSS IntelliSense** for class name completion
- **oxc** (`oxc.oxc-vscode`) for frontend linting

Point VS Code's Python interpreter at `backend/.venv` (Command Palette → "Python: Select Interpreter").

### 2.3 Day-to-day workflow

1. Update `main` and create a branch:
   ```sh
   git switch main
   git pull
   git switch -c feature/short-description
   ```
2. Make your changes. Read the relevant section of `docs/design.md` before changing a module, and follow the rules in `CLAUDE.md`.
3. Run the checks (all must pass):
   ```sh
   # backend (database container must be running)
   cd backend
   uv run ruff check .
   uv run ruff format .
   uv run pytest

   # frontend
   cd ../frontend
   npm run lint
   npm run build
   ```
4. Commit, push and open a pull request:
   ```sh
   git add -A
   git commit -m "Describe the change"
   git push -u origin HEAD
   gh pr create --fill
   ```

### 2.4 Contributing to the backend

- **Layout:** `backend/config/` holds the settings and URLs. There is one Django app per module: `accounts`, `vendors`, `listings`, `reservations`, `payments`, `notifications`.
- **Adding packages:** `uv add <package>` (or `uv add --dev <package>` for tools). This updates `pyproject.toml` and `uv.lock`. Commit both.
- **Model changes:** after editing `models.py`, run
  ```sh
  uv run python manage.py makemigrations
  uv run python manage.py migrate
  ```
  and commit the new files in `migrations/`.
- **Business logic** goes in service functions in each app, never in views or serializers. Stock and status changes must be single conditional updates. See `CLAUDE.md` for the full rules.
- **Tests** live in each app's `tests/` folder and run against the real Postgres in Docker. Never use SQLite. Concurrency-sensitive code (reserve, pickup, sweepers) needs tests with parallel requests.
- **The user model** is `accounts.User`. It logs in by email and has a `role` (consumer, vendor_staff, moderator, admin).

### 2.5 Contributing to the frontend

- **Layout:** `src/api/` holds the API client, `src/components/ui/` the shadcn/ui components and `src/lib/` helpers. `@/` is an alias for `src/`.
- **Adding packages:** `npm install <package>` (or `npm install -D <package>`). Commit `package.json` and `package-lock.json`.
- **UI components:** add shadcn/ui components with `npx shadcn@latest add <component>`. They are copied into `src/components/ui/`.
- **Calling the API:** use the generated TanStack Query helpers, never hand-written `fetch` calls:
  ```tsx
  import { useQuery } from '@tanstack/react-query'
  import { healthRetrieveOptions } from '@/api/generated/@tanstack/react-query.gen'

  const health = useQuery(healthRetrieveOptions())
  ```
- **The client never decides stock or price.** Display what the API returns.
- **Mobile first:** design for phone width, then scale up. See the wireframes.

### 2.6 When the API changes (backend and frontend together)

`src/api/generated/` is generated code. Never edit it by hand. After changing an API endpoint or serializer:

```sh
cd backend
uv run python manage.py spectacular --file openapi.yaml --validate
cd ../frontend
npm run gen:api
```

Commit `backend/openapi.yaml` and `frontend/src/api/generated/` together with the backend change, so the TypeScript types always match the API.

---

## 3. Command reference

| Task | Command (from) |
| --- | --- |
| Start database | `docker compose up -d` (root) |
| Stop database | `docker compose stop` (root) |
| Open a SQL shell | `docker compose exec db psql -U marketplace -d marketplace` (root) |
| Install backend packages | `uv sync` (backend) |
| Run backend | `uv run python manage.py runserver` (backend) |
| Apply migrations | `uv run python manage.py migrate` (backend) |
| Create migrations | `uv run python manage.py makemigrations` (backend) |
| Create admin user | `uv run python manage.py createsuperuser` (backend) |
| Django shell | `uv run python manage.py shell` (backend) |
| Backend tests | `uv run pytest` (backend) |
| Backend lint / format | `uv run ruff check .` / `uv run ruff format .` (backend) |
| Install frontend packages | `npm ci` (frontend) |
| Run frontend | `npm run dev` (frontend) |
| Frontend lint | `npm run lint` (frontend) |
| Frontend type check + build | `npm run build` (frontend) |
| Regenerate API schema + client | `uv run python manage.py spectacular --file openapi.yaml` (backend), then `npm run gen:api` (frontend) |

---

## 4. Troubleshooting

**`Could not find the GDAL library` / `Could not find the GEOS library`**
GDAL isn't installed, or Django can't find it.
- Windows: check that `C:\OSGeo4W\bin\gdal*.dll` exists. If you installed OSGeo4W elsewhere, set `OSGEO4W_ROOT` in `backend/.env`.
- macOS/Linux: set `GDAL_LIBRARY_PATH` and `GEOS_LIBRARY_PATH` in `backend/.env` to the full paths of `libgdal` and `libgeos_c`.

**`connection refused` on port 5432, or tests fail to connect**
The database isn't running. Start Docker Desktop, then run `docker compose up -d --wait`. Check it with `docker compose ps`.

**Port 5432 is already in use** (for example, a local Postgres install)
Pick another port, such as 5433. Set `POSTGRES_PORT=5433` in the root `.env`, and change the port in `DATABASE_URL` in `backend/.env` to `5433`. Then run `docker compose up -d` again.

**The "API status" card says the API is unreachable**
Django isn't running on port 8000. Start it with `uv run python manage.py runserver` in `backend/`.

**`DJANGO_SECRET_KEY` not set / `ImproperlyConfigured`**
`backend/.env` is missing. See [step 1.3](#13-create-the-environment-files).

**Start over with an empty database**
```sh
docker compose down -v   # deletes the database volume
docker compose up -d --wait
cd backend && uv run python manage.py migrate && uv run python manage.py createsuperuser
```
