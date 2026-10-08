# Surplus Food Marketplace: System Design

Oct 6, 2026 · @Diego

## Overview and requirements

This is a two-sided marketplace where food businesses list surplus food at a discount before it would be thrown out, and nearby consumers reserve it and pick it up in store. One developer builds it, starting in one city, with the ability to add cities later.

**Roles**

- **Vendors** (restaurants, bakeries, grocers) create listings, upload photos, and confirm pickups.
- **Consumers** browse nearby listings, reserve, and pick up.
- **Moderators and admins** approve vendors, review listings, handle disputes, and see analytics.

**Decisions made so far**

- Fulfilment is reserve and pick up in store. Delivery is out of scope.
- Payment is in app or in store. In-app cards are authorized at reservation and captured at pickup.
- Listings are either specific items or surprise bags, on one shared listing model.
- Inventory is exact: when two people reach for the last item, exactly one wins.
- A listing lives at most 3 days. Vendors upload photos so buyers can judge quality.
- Real-time updates and favorite vendors are wanted, but they ship after the core flow.
- A no-show is penalized (no charge for an uncaptured authorization), and the penalty policy is decided later from real data.

## Scale assumptions and constraints

At launch the hard problem is correctness, not throughput: the design assumes one metro area, bursty evening traffic, and a single developer.

| Dimension | Assumption |
| --- | --- |
| Vendors | About 300 in the launch city |
| Consumers | About 50,000 |
| Active listings | About 2,000 at a time |
| Peak window | 5pm to 9pm, with spikes when a vendor posts a batch |
| Burst shape | A few hundred buyers competing for a handful of rows |
| Consistency | Exact inventory: never oversell |
| Listing life | 3 days at most |
| Team | 1 developer, no fixed deadline |
| Growth | More cities, then out of state, without a rewrite |

Peak load matters even at this size. A bakery dropping 40 discounted items while 2,000 people watch creates a burst of reads and competing writes on a few rows, and that contention is the riskiest part of the design.

## Architecture

The system is one modular monolith: a single deployable with clean internal modules, which a solo developer can run, and which can be split along the module lines later.

&#91;embedded content: architecture · 3 clients, 1 API, 5 services\]

Postgres with PostGIS holds all authoritative state: relational data, transactions for inventory, and geo queries for nearby listings. Everything else is derived or external.

**Key choices**

- **Modular monolith** rather than microservices. One developer gains nothing from the operational cost of splitting.
- **One listing model** covers items and surprise bags: a listing has a type, quantity, prices, a pickup window, and an expiry.
- **Role-based access** (consumer, vendor staff, moderator, admin) lives in the monolith.
- **Photos** go from the client straight to object storage through signed URLs and are served by a CDN, so the API never handles the bytes.
- **Multi-city** comes from `city_id` on vendors and listings, with every query filtered by city.

## Technology stack: Django and React

The backend is Django on Postgres, exposed as a JSON API plus Django's built-in admin, and the front end is a React single-page app. Django has no database of its own: it is the application layer on top of Postgres and PostGIS, and every statement in this document is sent by its ORM.

| Concern | Choice |
| --- | --- |
| Backend | Django, one Django app per module (accounts, vendors, listings, reservations, payments, notifications) |
| Database | Postgres with PostGIS through GeoDjango. Not Django's default SQLite, and Postgres locally too, so concurrency behavior matches production |
| API | Django REST Framework or Django Ninja, with an OpenAPI schema (drf-spectacular) and a generated TypeScript client so front-end types cannot drift |
| Admin and moderation | Django admin, with no front end to build |
| Consumer app and vendor dashboard | React with TypeScript, built with Vite, mobile first, installable as a PWA |
| Server state | TanStack Query for caching and the month-2 polling, and the browser's `EventSource` for SSE later |
| Forms and styling | react-hook-form with zod, Tailwind with shadcn/ui |
| Maps | MapLibre or Leaflet |
| Payments | Stripe React Elements for authorization, hosted Connect onboarding for vendors |
| Background jobs | Celery with Redis, or a Postgres-backed queue (procrastinate, Django-Q2) to avoid another service at first |
| Authentication | Session cookies with CSRF on one domain for web, and token auth added when a native app exists |
| Native, later | React Native (Expo) against the same API, decided from month-3 push-notification data |

**Rules that keep the design intact**

- Business logic lives in service functions (`reserve`, `capture`, `expire`) that both views and the API call, so the inventory rule exists in exactly one place.
- Never read a quantity in Python, check it, and save. Always use the conditional update, and keep the CHECK constraint as the backstop.
- React never decides stock or price. It displays what the API returns.
- SSE needs ASGI (uvicorn or daphne). Run the stream endpoint as its own process so open connections do not tie up normal request workers, and use polling until month 8.
- Deployment is two pieces: the SPA as static files on a CDN, and Django as a container beside Postgres.

```python
with transaction.atomic():
    won = Listing.objects.filter(
        id=listing_id, status="active", qty_available__gte=n, expires_at__gt=now()
    ).update(qty_available=F("qty_available") - n)
    if won == 0:
        raise SoldOut
    Reservation.objects.create(...)
```

**Vite single-page app, not Next.js.** Next.js adds a Node server to run beside Django, and its main benefit is SEO, which most screens here do not need because they sit behind interaction. If public city or vendor pages later matter for search traffic, add Next.js or a small static site for just those pages.

## Data model

Postgres with PostGIS is the single source of truth, and `city_id` sits on vendors and listings so every query can filter by city from day one.

| Table | Key columns |
| --- | --- |
| users | id, email, role (consumer, vendor\_staff, moderator, admin), stripe\_customer\_id, status |
| vendors | id, owner\_user\_id, name, city\_id, location, stripe\_account\_id, status (pending, approved, suspended), trust\_tier (new, established) |
| cities | id, name, timezone, status |
| listings | id, vendor\_id, city\_id, location (denormalized), type (item, surprise\_bag), title, description, photo\_keys, original\_price\_cents, price\_cents, qty\_total, qty\_available, pickup\_start, pickup\_end, expires\_at, status, attested\_at, attested\_by |
| reservations | id, listing\_id, user\_id, qty, status, payment\_method (app, in\_store), unit\_price\_cents, original\_unit\_price\_cents, stripe\_payment\_intent\_id, payment\_status, hold\_expires\_at, pickup\_by, pickup\_code\_hash, resolved\_at, resolved\_by |
| reservation\_events | id, reservation\_id, from\_status, to\_status, actor\_type, actor\_id, reason\_code, metadata, created\_at (append only) |
| stripe\_events | stripe\_event\_id (unique), processed\_at |
| favorites | user\_id, vendor\_id, created\_at |
| devices | user\_id, token, platform, last\_seen |
| outbox | id, event\_type, payload, created\_at, sent\_at |

**Design notes**

- Price snapshots on reservations mean a later listing edit never changes what someone agreed to pay.
- `pickup_code_hash` stores a hash, not the code.
- `attested_at` and `attested_by` record the vendor's claim that the food is still safe to sell, which is the audit trail if someone gets sick.
- Photos are stored as object-storage keys, not URLs, so the CDN can change later.
- `location` is copied onto listings so the browse query is one index lookup instead of a join.
- Listing status values: draft, pending\_review, active, sold\_out, expired, removed.

**Constraints that enforce the rules**

```sql
CHECK (qty_available >= 0 AND qty_available <= qty_total)
CHECK (expires_at <= created_at + interval '3 days')
CHECK (pickup_end <= expires_at)
-- reservations.pickup_by <= listing.expires_at is enforced in the reserve transaction
```

**Indexes for the hot queries**

| Query | Index |
| --- | --- |
| Browse nearby active listings | GiST on listing location, partial on status = active |
| Active listings in a city, soonest expiring first | (city\_id, expires\_at) where status = active |
| Sweeper finds expired holds | (hold\_expires\_at) where status = pending\_authorization |
| Sweeper finds ended pickup windows | (pickup\_by) where status = confirmed |
| A user's reservations | (user\_id, created\_at desc) |
| Cap on concurrent unpaid reservations | (user\_id) where status = confirmed and payment\_method = in\_store |
| Favorites fan-out | (vendor\_id) on favorites |

The partial indexes keep the hot sets small as history grows, so these queries stay fast for years.

## Inventory reservation: Postgres decides

Postgres is the arbiter of who gets the last item, using one atomic conditional update inside a transaction. A Redis counter in front would add speed the launch scale does not need and would put the exactly-one-wins guarantee at risk.

**Approach A: Postgres as the arbiter**

```sql
UPDATE listings
SET qty_available = qty_available - :n
WHERE id = :id AND qty_available >= :n
  AND status = 'active' AND expires_at > now()
RETURNING qty_available;
-- 1 row = you got it; 0 rows = sold out
-- then INSERT the reservation (with hold_expires_at) in the same transaction
```

A sweeper job returns stock when a hold expires.

**Approach B: Redis as a front gate.** Keep a counter per listing in Redis, decrement it atomically with a Lua script, and write winners to Postgres afterward.

|  | A: Postgres | B: Redis gate |
| --- | --- | --- |
| Correctness | One source of truth, one transaction | Two stores can disagree; a crash between them needs reconciliation |
| Throughput | Row lock serializes buyers on one listing: tens to hundreds of operations per second per hot row | Tens of thousands per second per key |
| Complexity | Low, no extra infrastructure | Higher: sync, failure recovery, drift repair |
| Failure mode | Slower under extreme contention | Silent oversell or a false sold-out if the counter drifts |
| Fit for this project | Strong for one city and one developer | Worth it only at flash-sale scale |

**Decision: Approach A.** A hot row sees a few hundred buyers in a burst, which Postgres handles easily. Revisit only if sustained contention shows up in metrics. Redis remains useful for read caching and pub/sub on live counts, where slightly stale data is fine.

## Reservation and payment state machine

A card is authorized when the buyer reserves in app and captured only when the vendor confirms pickup, so a no-show costs the buyer nothing but is still penalized.

&#91;embedded content: reservation states · 6 states, 2 entry paths\]

Pay-in-store reservations skip the authorization step and start as confirmed.

**Stock rules**, all inside Postgres transactions

- Reserve is the atomic conditional update plus an inserted reservation, in one transaction.
- Expired and cancelled reservations return stock to the listing, since the food is still there.
- A no-show does not restock automatically. On a day-1 no-show the food may still be good, so the vendor can re-list it with one tap.
- Picked up is final.

**Expired versus no-show.** A reservation expires when checkout never finished: nothing was promised, so there is no penalty. It becomes a no-show when it was confirmed and the pickup window passed: stock was committed, so a penalty applies.

**Vendor-caused problems.** A reservation can also end as `vendor_issue` when the buyer reports a problem at arrival instead of the vendor confirming pickup. The authorization is released, stock is not returned, and no penalty applies to the buyer. See the vendor quality section.

**Payment rules**

- Capture is by quantity. The vendor changes the quantity at pickup (5 of 6 croissants) and the server computes the amount from the price snapshotted at reservation. A raw dollar amount from the client is never accepted.
- The authorized amount is a ceiling. Capturing less releases the remainder automatically.
- On a no-show the authorization is cancelled. Nothing was charged, so there is no refund and no processing fee lost.
- Card authorizations last about 7 days. The 3-day listing cap keeps every pickup well inside that.
- If a capture fails, the platform retries, then charges the saved card, then marks the reservation `paid_outside_app`.

**No double pickup.** Only the request that wins this update triggers the capture, and the capture carries an idempotency key derived from the reservation ID.

```sql
UPDATE reservations SET status = 'picked_up', resolved_at = now()
WHERE id = :id AND status = 'confirmed' AND pickup_code_hash = :hash
RETURNING id;
-- 0 rows = already used or invalid, so do nothing
```

## Real-time update design

Postgres never serves the fan-out: every change commits there first, and a separate layer delivers it to watchers. Two different problems hide under real time, and they use different mechanisms: quantity changes on a listing someone is viewing, and new-listing alerts for people who may not have the app open.

&#91;embedded content: real-time flow · outbox to SSE and push\]

**The outbox pattern.** If application code commits to Postgres and then publishes to Redis, a crash between the two loses the event. Instead, the reservation transaction also inserts an `outbox` row. A small publisher reads the outbox and publishes, which gives at-least-once delivery without a distributed transaction. Duplicates are harmless because each event carries the new absolute quantity, not a decrement.

**Quantity updates**

- Send state, not deltas: an event says listing 123 now has 2 left, version 47. Clients ignore any version lower than the one they hold.
- Subscribe narrowly: the listing detail screen subscribes to its own listing, and the browse list subscribes per city with coalesced updates.
- Coalesce bursts: a bakery drop of 40 reservations in 10 seconds produces about one update per listing per second.
- Never trust the display: "2 left" is a hint, and the reserve transaction is the only authority. Clients must handle "just sold out" gracefully.

**Transport.** Start with server-sent events (SSE) rather than WebSocket. Updates flow one way, SSE is plain HTTP with built-in reconnect, and switching later is a contained change if two-way messaging is ever needed.

**Scaling and failure**

- Connection count is the real cost, and one modest gateway handles thousands of watchers. Run two for redundancy.
- Redis pub/sub is fire and forget. After a gateway restart, clients reconnect, fetch current state from the API, then resume the stream.
- The MVP can skip all of this and poll every 15 to 30 seconds with short caching.

**New-listing alerts**

- When a listing goes active, its outbox event triggers a push worker, which finds users who favorited that vendor in the same city.
- Throttle and batch: a vendor with 5,000 followers posting three listings sends one consolidated push, not 15,000. Add per-user quiet hours and a daily cap.
- A dedup key on user and listing means retries never notify twice.
- Push tokens live in a `devices` table and are pruned when FCM or APNs report them invalid.

**What will bite you**

- A popular vendor posts and 2,000 users open the listing at once. Cache the listing-detail read for a few seconds.
- Phone clocks drift. Send `expires_at` plus a server time offset so countdowns never show "expired" early.
- Close the stream when the app is backgrounded and rely on push instead.
- Public events carry only listing ID and quantity, never who reserved.

## Hard parts and risks

The eight places this design is most likely to break, and the mitigation for each.

| Risk | What goes wrong | Mitigation |
| --- | --- | --- |
| Exactly-one-wins inventory | Two buyers take the last item under burst contention | Atomic conditional update, plus a CHECK constraint as a second defense |
| Reservation holds | Abandoned holds lock stock | Idempotent sweeper using `FOR UPDATE SKIP LOCKED` |
| Late payment webhook | Authorization arrives after the hold expired and the stock sold | Lock the reservation row, check state, cancel the authorization if it is no longer pending. Store Stripe event IDs for idempotency |
| Double scan at pickup | Capture happens twice | Conditional update on status plus code, and a capture idempotency key derived from the reservation ID |
| No-shows | Vendors lose food and revenue | Log outcomes now, apply penalties later, cap concurrent unpaid reservations, track no-show rate per user and vendor |
| False no-shows | A vendor forgets to scan or marks a no-show unfairly | Pickup code, dispute flow, soft penalties at first |
| Trust and safety | The platform sells near-end-of-life food | Photos, vendor onboarding, category maximum windows, attestation audit trail, moderation tiers |
| Time correctness | Wrong expiry across time zones or phone clocks | Store UTC, render local, send server time offset to clients |

**Capture failure at pickup.** If the authorization has been voided, the platform retries the capture, then tries a new charge on the saved card, and finally marks the reservation `paid_outside_app` so the vendor takes payment in person. The platform earns no commission on that last path.

## Vendor quality, reports, and flagging

Every complaint is tied to a real reservation, a vendor's failure is never counted as the buyer's no-show, and a vendor's standing is computed from upheld reports instead of being set by hand.

**Two moments, two flows**

- **Problem at arrival** (food not as described, vendor closed, vendor refuses): the buyer taps "Problem with this pickup" instead of the vendor confirming. Nothing is captured, the authorization is released, and the reservation ends as `vendor_issue` with no penalty to the buyer.
- **Problem after pickup** (quality, illness, wrong quantity): the buyer files a report within a window, 24 hours to start and longer for illness. If payment was captured, a refund can be issued using the report's reason.

**Reports table.** `reports`: id, reservation\_id, vendor\_id, reporter\_id, category, severity, description, photo\_keys, status (open, under\_review, upheld, dismissed), resolution, resolved\_by, created\_at, resolved\_at. Only a user with a real reservation at that vendor can file one. Categories: not as described, poor quality, food safety or illness, vendor unavailable or refused, wrong quantity, other.

**Severity decides the speed**

| Severity | Examples | Response |
| --- | --- | --- |
| Safety | Illness, spoiled food, contamination | Hide the vendor's active listings immediately, notify a moderator, review manually before restoring |
| Service | Closed, refused, wrong quantity | Release the hold or refund, moderator review, warning if upheld |
| Quality | Not as fresh as shown | Log it and count it toward the vendor's score |

One safety report can pause a vendor, because waiting is costly with food illness. A single non-safety report never suspends anyone automatically.

**Vendor standing.** A nightly job computes, per vendor, upheld reports divided by completed pickups over a rolling window, weighted by severity, plus vendor-fault cancellations as a second signal. Minimum counts stop a vendor with 3 pickups and 1 report from being treated like one with 300 and 100. The result feeds `trust_tier`, which now has more values than new and established:

`ok` → `warned` (vendor notified) → `restricted` (every listing pre-reviewed, no follower push) → `suspended` (listings hidden, moderator decides)

**Fairness and audit**

- Vendors can respond with their side and evidence, and can appeal.
- Track reporter reliability, so someone who reports every pickup carries less weight.
- Keep an append-only audit trail of reports and decisions, in the same style as `reservation_events`. With the vendor's attestation record, it is the evidence if someone gets sick.
- Get a legal review of retention and escalation for illness reports before launch.

## Roadmap: 2, 3, 5, 8, and 12 months

The plan assumes one developer working roughly full time; for nights and weekends, multiply every date by about 2 to 2.5. The gates matter more than the dates: if vendors are not posting at month 2, building payments will not fix it.

&#91;embedded content: roadmap · 5 phases, 5 gates, not to scale\]

Phases are drawn as equal bands, not to scale. What each one builds:

| By month | Build |
| --- | --- |
| 2 | Auth and roles, an off-the-shelf admin panel, listing creation with photos through signed URLs, browse nearby with polling and short caching, reserve with the atomic update, hold timer, sweeper and pickup code (all pay in store), `reservation_events` and price snapshots, `city_id` everywhere, CHECK constraints |
| 3 | Favorites and push through the outbox and a job queue, a cap on concurrent unpaid reservations, manual moderation of new vendors' listings, a report and remove tool, a basic vendor view, admin dashboards from SQL views, monitoring, and backups with a tested restore |
| 5 | Stripe Connect onboarding and payouts, authorize at reservation and capture at pickup with partial capture by quantity, idempotent webhooks, the capture-failure path, card on file with explicit no-show fee consent |
| 8 | Penalty policy designed from real no-show data, a no-show dispute flow, one-tap re-list, the `trust_tier` nightly job, SSE for live quantity, vendor and admin analytics on a read replica, moderator tooling and an audit trail |
| 12 | City onboarding as configuration, an index and query-plan review against real data, Redis only if metrics show the need, vendor efficiency tools such as templates and bulk actions, search and ranking tuning |

**Skipped on purpose.** Month 2 skips payments, push, SSE, penalties and dashboards. Month 3 skips live quantities and any penalty beyond the cap. At month 12, delivery, a second developer and out-of-state expansion are evaluated, not committed.

**Effect of Django and React.** Building a JSON API plus a React app is more work than server-rendered pages, so expect the month-2 pilot to stretch by roughly 2 to 4 weeks (an estimate, to revisit after the first month). To hold the date instead, build only the vendor flow (create listing, confirm pickup) and consumer browse and reserve for the pilot, and move favorites and map polish to month 3.

**Vendor reports in the plan.** Month 3 adds the "Problem with this pickup" button, a report form with a photo, and a moderator queue in Django admin with manual hide and suspend. Month 8 adds automated vendor scoring and the warned, restricted, and suspended tiers, once real report data exists to set thresholds from.

**Solo-developer advice**

- Buy where you can: admin panel, auth, push, and Stripe Connect are not places to be clever.
- Vendor supply is the real bottleneck. Spend part of every month onboarding vendors by hand, because an empty marketplace validates nothing.
- Before month 5, get the legal review on fees and consent and decide the commission policy for `paid_outside_app` sales.
- Budget extra time for payments: webhook edge cases and vendor onboarding friction take longer than they look.

## Parked decisions and next steps

Four decisions are deliberately deferred, and each has a point where it stops being optional.

| Decision | Why it can wait | Needed by |
| --- | --- | --- |
| No-show penalty policy (strikes, fee, or suspension, and thresholds) | Outcomes are logged from day one, so a policy can be applied later, even retroactively | Month 8, using 3 to 5 months of real data |
| Commission on `paid_outside_app` sales | Only arises when in-app payments exist | Month 5 |
| Who absorbs the cost of a no-show | Vendors absorb it in the MVP | Revisit if vendors churn over no-shows |
| Legal review of no-show fees and card-on-file consent | No fees are charged before in-app payments | Before month 5 |

**Next steps**

- [ ] Walk the failure scenarios: a Stripe outage mid-checkout, a Postgres failover during a drop, a vendor's phone dying at pickup
- [ ] Set the definition of an "established" vendor (completed pickups, no-show rate, no moderator removals)
- [ ] Decide the pickup confirmation method: one-time code shown by the user and scanned by the vendor, or a rotating QR
- [ ] Choose off-the-shelf pieces for auth, admin panel, push, and Stripe Connect
