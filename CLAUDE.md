# Surplus Food Marketplace

A two-sided marketplace: food vendors list surplus food at a discount, nearby consumers reserve it and pick it up in store. One developer, one launch city, multi-city ready.

- Full system design (requirements, data model, state machine, risks, roadmap): `docs/design.md`. Read the relevant section before changing a module.
- Wireframes: `docs/wireframes/Surplus Food Marketplace Wireframes-png/` (consumer mobile, vendor mobile, desktop).

## Stack

| Concern | Choice |
| --- | --- |
| Backend | Django, one app per module: accounts, vendors, listings, reservations, payments, notifications |
| Database | Postgres + PostGIS (GeoDjango), run locally with Docker. Never SQLite |
| API | JSON API with an OpenAPI schema and a generated TypeScript client |
| Admin / moderation | Django admin |
| Frontend | React + TypeScript, Vite, mobile first, PWA. TanStack Query, react-hook-form + zod, Tailwind + shadcn/ui |
| Payments (month 5) | Stripe: authorize at reservation, capture at pickup |
| Background jobs | Celery + Redis or a Postgres-backed queue (not yet decided) |

## Layout

```
backend/            Django 6 project (config/) and apps, managed with uv
backend/openapi.yaml  Generated OpenAPI schema (input to the TS client)
frontend/           Vite React app; src/api/generated/ is the generated client (do not edit)
docs/design.md      System design
docs/wireframes/    Screen wireframes
docker-compose.yml  Postgres/PostGIS (and later Redis)
```

## Dev commands

```sh
docker compose up -d                                  # PostGIS on :5432
cd backend && uv run python manage.py migrate
cd backend && uv run python manage.py runserver       # API on :8000, admin at /admin/, Swagger at /api/docs/
cd frontend && npm run dev                            # SPA on :5173, proxies /api and /admin to :8000
cd backend && uv run pytest                           # tests (need the db container running)
cd backend && uv run ruff check . && uv run ruff format .
cd frontend && npm run lint && npm run build
# After changing the API:
cd backend && uv run python manage.py spectacular --file openapi.yaml && cd ../frontend && npm run gen:api
```

- Env: copy `.env.example` to `.env` (root, compose) and `backend/.env.example` to `backend/.env`.
- Windows: GeoDjango loads GDAL/GEOS from OSGeo4W (`OSGEO4W_ROOT`, default `C:\OSGeo4W`); see `config/settings.py`.
- Auth model is `accounts.User` (email login, `role`, `status`). The API uses session auth + CSRF; `src/api/client.ts` sends the CSRF header.

## Rules that must never break

1. **Business logic lives in service functions** (`reserve`, `capture`, `expire`, ...) in each app. Views and API endpoints call them and never change stock or status themselves.
2. **Inventory is exact.** Never read a quantity in Python, check it, and save. Reserve with a single conditional update inside `transaction.atomic()`:
   ```python
   won = Listing.objects.filter(
       id=listing_id, status="active", qty_available__gte=n, expires_at__gt=now()
   ).update(qty_available=F("qty_available") - n)
   if won == 0:
       raise SoldOut
   ```
   Keep the DB CHECK constraints (`0 <= qty_available <= qty_total`, 3-day expiry, `pickup_end <= expires_at`) as the backstop.
3. **State transitions are conditional updates** (`WHERE status = <expected>`), and every transition writes an append-only `reservation_events` row.
4. **The client never decides stock or price.** React displays what the API returns. Capture amounts are computed server side from quantity × the snapshotted price, never from a client-sent amount.
5. **Every vendor/listing query filters by `city_id`.**
6. **Time:** store UTC, render in the city's timezone, send a server time offset to clients for countdowns.
7. **Photos** go to object storage through signed URLs. Store keys, not URLs. The API never handles the image bytes.
8. **Idempotency:** Stripe webhooks are deduped by `stripe_events`; captures use an idempotency key derived from the reservation ID; sweepers use `FOR UPDATE SKIP LOCKED`.

## Current phase: month-2 pilot

In scope: auth and roles, Django admin, listing creation with photos, browse nearby (polling), reserve with the atomic update, hold timer and sweeper, pickup code, pay in store only, `reservation_events`, price snapshots, `city_id` everywhere, CHECK constraints.

Out of scope for now: in-app payments, push, SSE, penalties, dashboards, delivery.

## Testing

Concurrency-sensitive code (reserve, pickup, sweepers) must have tests that run against real Postgres with parallel requests, proving exactly one winner for the last item.
