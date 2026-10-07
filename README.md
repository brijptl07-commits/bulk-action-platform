# Bulk Action Platform

A scalable, extensible platform for running bulk actions (starting with **Bulk Update**) on CRM entities —
**Contacts, Companies, Leads, Opportunities and Tasks**. Built with **Ruby on Rails 7, MySQL, Sidekiq and Redis**.

- JSON API exactly as specified (`/bulk-actions`, `/bulk-actions/:id`, `/bulk-actions/:id/stats`) plus logs and cancel
- Five CRM entities out of the box, all driven by the same pipeline and handler code
- Batch processing in parallel Sidekiq workers (horizontally scalable)
- Per-record logs (success / failed / skipped) and summary stats
- Optional enhancements implemented: **rate limiting per account**, **de-duplication** (email / domain), **scheduling**
- Basic UI for creating actions, watching live progress and filtering logs

---

## Architecture

```
                 ┌──────────────┐   POST /bulk-actions
  Client / UI ──▶│  Rails API   │── validate (registries) ── save BulkAction (queued | scheduled)
                 └──────┬───────┘
                        │ PlanJob.perform_async / perform_at(scheduled_at)
                        ▼
                 ┌──────────────┐
                 │    Redis     │  Sidekiq queues: bulk_actions, bulk_action_batches
                 └──────┬───────┘  + rate-limit counters + de-dupe sets
                        ▼
   ┌──────────────────────────────────────────┐
   │ PlanJob (1 per action)                   │
   │  - queued → in_progress (atomic)         │
   │  - keyset-paginate target ids            │  WHERE id > ? ORDER BY id LIMIT 500
   │  - de-dupe by email (Redis SADD)         │
   │  - enqueue BatchJob(ids, duplicate_ids)  │
   └──────────────────┬───────────────────────┘
                      ▼  (fan-out)
   ┌──────────────────────────────────────────┐
   │ BatchJob × N  (any number of processes)  │
   │  - skip ids already logged (idempotent)  │
   │  - RateLimiter.acquire(account, n)       │── over limit → re-enqueue for next window
   │  - ONE transaction:                      │
   │      lock rows, handler.call(records),   │  1 bulk UPDATE per batch
   │      field versions, counters, logs      │
   │  - mark completed when processed = total │
   └──────────────────┬───────────────────────┘
                      ▼
                 ┌──────────────┐
                 │    MySQL     │  CRM entity tables, bulk_actions, bulk_action_logs
                 └──────────────┘

   RecoveryJob (every 5 min, one at a time): re-plans lost/dead plans, re-sends lost batches,
   completes finished actions — so nothing stays stuck (see "Reliability and recovery").
```

### Key design decisions

| Concern | Approach |
|---|---|
| **Large volumes** | Planner never loads the full set: keyset pagination on the primary key, only `id` (+ dedupe field) is plucked. Ids are snapshotted at plan time, so updating the field you filtered on doesn't shift the target set. |
| **Efficient writes** | Each batch validates records in memory (so per-record errors are logged) and then writes all valid rows with a **single** `UPDATE ... WHERE id IN (...)`. Logs are written with one multi-row `INSERT`. |
| **Horizontal scaling** | Workers are stateless; all state lives in MySQL/Redis. Run more `sidekiq` processes (on any machine) to process more batches in parallel. Measured with `bin/scale_test`: 1 → 2 → 4 processes gives 1.0x → 1.6x → 1.9x throughput on one laptop (see [Load test](#load-test)). |
| **Progress / stats** | Counters (`total`, `processed`, `success`, `failed`, `skipped`) are maintained atomically with `UPDATE ... SET x = x + n` — stats are O(1), no `COUNT(*)` over logs. |
| **Reliability** | Each batch is **one transaction** (record update + field versions + counters + logs), so a crash never leaves records updated without logs or counts. Batches retry (Sidekiq, 5 attempts) and are idempotent: already-logged ids are skipped (re-checked under the row locks), and a unique index on `(bulk_action_id, entity_id)` prevents double logging. The planner is restartable, and a `RecoveryJob` finds and fixes anything stuck. Status changes use conditional updates (`WHERE status IN (...)`) so concurrent workers can't race. Details: [Reliability and recovery](#reliability-and-recovery). |
| **Extensibility** | Two registries: `EntityRegistry` (which models + which fields are updatable/filterable/dedupe) and `ActionRegistry` (`action_type` → handler class). Planning, batching, retries, rate limiting, dedupe, logs and stats are shared by every action. |
| **Concurrent actions on the same records** | Each action gets a strictly increasing `sequence` when it starts (durable MySQL counter). Every write stamps `last_bulk_action_seq` on the record, and the batch `UPDATE` only touches rows whose stamp is not newer. So if action 2 started after action 1, action 1 can never overwrite action 2's values, even if its batch runs later; those records are logged as `skipped — Superseded by newer bulk action #2`. Actions still run fully in parallel. |
| **Concurrent actions on the same records** | Last-writer-wins **per field**, independent of execution order (see below). |
| **Safety** | Filters must be explicit (`ids`, `where`, or `all: true`), and only whitelisted fields can be filtered/updated. |

### Overlapping bulk actions (ordering guarantee)

Two bulk actions can target the same records, e.g. action #1 sets `name = "name1"` and action #2 (submitted later)
sets `name = "name2"`. Batches of #1 can run *after* #2 because of a rate-limit delay, a retry or a slow worker.
Without protection #1 would overwrite the newer value.

`FieldVersionGuard` prevents this:

1. In one transaction the batch's rows are locked (`SELECT ... FOR UPDATE`, ordered by id).
2. `bulk_field_versions` stores, per `(entity_type, entity_id, field)`, which action last wrote it.
3. A field is written only if no **newer** action owns it. Newer = later `scheduled_at || created_at` (tie → higher id).
4. The action is then recorded as the latest writer of the fields it applied (also for no-op writes).

It is **per field**: if #1 changes `name` + `score` and #2 changes only `name`, a late #1 still applies `score`.
Superseded records/fields are visible in the logs, e.g. `Superseded by newer bulk action #27` or
`name superseded by #27`.

Verified: action #1 was held back by the rate limiter while #2 completed; when #1 ran a minute later all 300 leads
kept `name2` and received #1's `score`. Re-running an older action's batch after a newer one completed (simulated
Sidekiq retry) left every record unchanged and logged `skipped / Superseded by newer bulk action`.

### Data model

CRM entities (each registered in `config/initializers/bulk_actions.rb`):

| Entity | Table | Updatable fields | Filterable fields | Dedupe key |
|---|---|---|---|---|
| Contact | `contacts` | name, email, age, status | status, age, email | email |
| Company | `companies` | name, domain, industry, employee_count, status | status, industry, domain | domain |
| Lead | `leads` | name, email, company_name, source, score, status | status, source, email | email |
| Opportunity | `opportunities` | name, amount, stage, probability, close_date | stage, company_id | — |
| Task | `tasks` | title, description, status, priority, due_date, assignee | status, priority, assignee | — |

Platform tables:

- `bulk_actions` — `account_id, entity_type, action_type, status, payload (json), filters (json), dedupe, total/processed/success/failure/skipped counts, scheduled_at, started_at, planned_at, completed_at, error_message`
- `bulk_action_logs` — `bulk_action_id, entity_id, status (success|failed|skipped), message` — indexed by `(bulk_action_id, status)` and unique `(bulk_action_id, entity_id)`
- `bulk_field_versions` — `entity_type, entity_id, field, bulk_action_id, effective_at` — primary key `(entity_type, entity_id, field)`; latest bulk writer per field

Statuses: `scheduled → queued → in_progress → completed | failed | cancelled`

### Code map

```
app/services/bulk_actions/
  entity_registry.rb      # register entities (model, updatable/filterable fields, dedupe field)
  action_registry.rb      # register actions (action_type → handler)
  handlers/base.rb        # handler contract
  handlers/bulk_update.rb # the Bulk Update action
  field_version_guard.rb  # per-field last-writer-wins across bulk actions
  creator.rb              # validate request, persist, enqueue (now or scheduled)
  scope_builder.rb        # filters → ActiveRecord relation
  planner.rb              # keyset page walker over an action's target records (+ dedupe)
  rate_limiter.rb         # per-account fixed-window limiter (Redis + Lua, atomic)
  deduplicator.rb         # Redis-set based de-duplication
  recovery.rb             # finds stuck actions and puts them back on track
  redis_lease.rb          # self-expiring Redis lock with heartbeat
app/sidekiq/bulk_actions/
  plan_job.rb             # step 1: plan & fan out batches (restartable)
  batch_job.rb            # step 2: process a batch in one transaction
  recovery_job.rb         # runs Recovery every RECOVERY_INTERVAL_SECONDS
config/initializers/bulk_actions.rb   # registrations
app/controllers/api/*     # JSON API
app/controllers/ui/*      # basic UI
test/                     # Minitest: handler, creator, rate limiter, jobs, recovery, API
```

---

## Extending

**Add a new entity (e.g. Invoice)** — create the model/migration, then register it. Field types drive the UI
form inputs (`:string`, `:text`, `:integer`, `:decimal`, `:date`, or an Array of allowed options → dropdown):

```ruby
BulkActions::EntityRegistry.register(
  :invoice, model: "Invoice",
  fields: { number: :string, amount: :decimal, due_date: :date, status: Invoice::STATUSES },
  filterable_fields: %i[status],
  dedupe_field: :number          # optional
)
```

This is exactly how Companies, Leads, Opportunities and Tasks were added — no changes to the planner, batch
worker, handlers, API or UI were needed. The UI form, record browser (`/ui/entities/:entity_type`) and
`GET /entities/:entity_type/records` pick the new entity up automatically.

**Add a new action (e.g. Bulk Delete)** — one handler class + one line:

```ruby
module BulkActions::Handlers
  class BulkDelete < Base
    def call(records)
      entity.model.where(id: records.map(&:id)).delete_all
      records.map { |r| success(r) }
    end
  end
end

BulkActions::ActionRegistry.register(:bulk_delete, "BulkActions::Handlers::BulkDelete")
```

Nothing else changes — the API, UI, planner, batching, rate limiting, dedupe, logs and stats all work for it.

---

## Setup

### Option A: Docker (one command)

Requirements: Docker with Compose v2. Nothing else (no Ruby, MySQL or Redis on the host).

```bash
docker compose up --build
```

This starts MySQL 8, Redis 7, a one-shot `setup` service (creates + migrates the database and seeds
**100,000 contacts** and 5,000 records of every other entity, topping up only what is missing), the Rails
server and a Sidekiq worker. Change the counts with `SEED_COUNT` / `SEED_CONTACT_COUNT` in `docker-compose.yml`.

- UI: http://localhost:3000 (use `WEB_PORT=3001 docker compose up` if port 3000 is taken)
- Sidekiq dashboard: http://localhost:3000/sidekiq
- API: http://localhost:3000/bulk-actions (the Postman collection works unchanged)

```bash
docker compose up -d --scale worker=4             # horizontal scaling: 4 Sidekiq processes
docker compose logs -f web worker                 # follow logs
docker compose exec web bin/rails "crm:seed[50000,contact]"   # more data
docker compose exec web bin/rails bulk:load_test  # throughput test inside Docker
docker compose down                               # stop (add -v to also delete the database)
```

### Option B: Local

Requirements: Ruby 3.1.3, MySQL 8, **Redis 6+** (Sidekiq 7 requirement).

```bash
bundle install
cp .env.example .env            # set DB_PASSWORD etc.
docker run -d --name bulk_action_redis -p 6380:6379 redis:7-alpine   # Redis 7 on localhost:6380 (skip if you have Redis 6+)

bin/rails db:create db:migrate
bin/rails db:seed                          # tops up to 2,000 per entity (SEED_COUNT, SEED_CONTACT_COUNT=100000 ...)
bin/rails "crm:seed[20000,contact]"        # optional: more records for one entity
bin/rails "crm:seed[5000]"                 # optional: more records for every entity
bin/rails "contacts:import[db/sample_contacts.csv]"   # optional: import contacts from CSV

# run (two terminals)
bin/rails server
bundle exec sidekiq -C config/sidekiq.yml
```

- UI: http://localhost:3000
- Sidekiq dashboard: http://localhost:3000/sidekiq
- Postman collection: `postman/Bulk_Action_Platform.postman_collection.json`

### Configuration (`.env`)

| Variable | Default | Purpose |
|---|---|---|
| `BULK_BATCH_SIZE` | 500 | records per batch job |
| `RATE_LIMIT_PER_MINUTE` | 30000 | max records processed per account per minute |
| `SIDEKIQ_CONCURRENCY` | 10 | threads per Sidekiq process |
| `REDIS_URL` | redis://localhost:6380/0 | Redis |
| `DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD`, `DB_POOL` | | MySQL |
| `RECOVERY_INTERVAL_SECONDS` | 300 | how often `RecoveryJob` runs |
| `RECOVERY_STALL_SECONDS` | 600 | an in-progress action with no committed batch for this long gets its unprocessed records re-sent |

### Tests

```bash
bin/rails db:test:prepare && bin/rails test                                                  # local
docker compose run --rm -e RAILS_ENV=test web bash -c "bin/rails db:test:prepare && bin/rails test"   # Docker
```

Minitest, against real MySQL and Redis (Redis DB 15, so dev data is untouched). Covers the Bulk Update handler
(validation, per-record failures, last-writer-wins in both orders), `Creator`, the rate limiter, `PlanJob`
(batching, dedupe, resume, lease), `BatchJob` (logs/counters, skipped records, idempotency, concurrent duplicate
deliveries, full rollback on failure, deadlock retry, rate-limit reschedule), `Recovery`/`RecoveryJob`, and the API
end to end.

---

## API

All endpoints return JSON. Errors: `422 { "errors": [...] }`, `404` for unknown ids.

### `POST /bulk-actions`

```json
{
  "account_id": "acc_1",
  "entity_type": "contact",
  "action_type": "bulk_update",
  "dedupe": true,
  "scheduled_at": "2026-11-22T23:15:00+05:30",
  "filters": { "where": { "status": "lead" } },
  "payload": { "fields": { "status": "prospect", "age": 30 } }
}
```

- `entity_type`: `contact`, `company`, `lead`, `opportunity`, `task`
- `filters`: one of `{ "ids": [1,2,3] }`, `{ "where": { "status": "lead" } }` (equality / array = IN, filterable fields only), `{ "all": true }`
- `payload.fields`: any of the entity's updatable fields; values are validated per record with the model's validations
- `dedupe` (optional): skip records whose dedupe key (email for contacts/leads, domain for companies) was already seen in this action; they are logged as `skipped`. Rejected for entities without a dedupe key.

More examples:

```json
{ "account_id": "acc_1", "entity_type": "opportunity", "action_type": "bulk_update",
  "filters": { "where": { "stage": "negotiation" } },
  "payload": { "fields": { "stage": "closed_won", "probability": 100, "close_date": "2026-10-31" } } }

{ "account_id": "acc_1", "entity_type": "task", "action_type": "bulk_update",
  "filters": { "where": { "priority": "high" } },
  "payload": { "fields": { "status": "done", "assignee": "brij" } } }
```
- `scheduled_at` (optional): ISO-8601 time; status is `scheduled` until then

Returns `201` with the bulk action.

### `GET /bulk-actions`
Query: `status` (comma separated), `account_id`, `entity_type`, `page`, `per_page`.

### `GET /bulk-actions/:id`
Full details including payload, filters, timestamps and live stats.

### `GET /bulk-actions/:id/stats`

```json
{ "data": { "id": 9, "status": "completed", "total": 20000, "processed": 20000,
            "success": 19001, "failed": 0, "skipped": 999, "pending": 0, "progress_percent": 100.0 } }
```

### `GET /bulk-actions/:id/logs`
Query: `status` (`success,failed,skipped`), `entity_id`, `page`, `per_page` (max 500).

### `POST /bulk-actions/:id/cancel`
Cancels a scheduled/queued/in-progress action; remaining batches become no-ops.

### Helpers
- `GET /entities` — registered entities (fields, types, options, filterable fields, dedupe key) and actions
- `GET /entities/:entity_type/records` — browse records of any entity; any filterable field can be a query param

---

## Optional enhancements

**Rate limiting** — every bulk action has an `account_id`. Before a batch is processed, `RateLimiter.acquire`
atomically (Lua script) reserves `n` units in a Redis counter keyed by `account + current minute`. If the account
would exceed `RATE_LIMIT_PER_MINUTE` (default 30k), the batch is re-scheduled to the start of the next window instead
of being dropped. The limit is shared across all workers/processes.

The planner enqueues every batch up front. With 1,000,000 records at 30,000/min, 2,000 batches are queued: about 60
run in the current minute and the rest are re-scheduled to the next one, again and again until their turn. That
repeated pick-up and re-schedule is wasted work (see the production notes for the fix).

**De-duplication** — when `dedupe: true`, the planner walks records in id order and `SADD`s each normalized value of
the entity's dedupe key (email for contacts and leads, domain for companies) into a per-action Redis set. If the
value was already present, the record is passed to the batch as a duplicate and logged as `skipped` with message
`Duplicate email` / `Duplicate domain`. The set expires automatically and is deleted after planning.

**Scheduling** — `scheduled_at` uses Sidekiq's scheduled set (`perform_at`). The action stays `scheduled`
(visible in the list and cancellable) until it starts.

---

## Concurrent actions on the same records

Scenario: action 1 sets `name = name1`, action 2 (started later) sets `name = name2` on the same contacts, but
action 1's batch is delayed and runs after action 2's. Without protection the record would end with the stale
`name1`.

How it is prevented:

1. When an action starts, `PlanJob` assigns `bulk_actions.sequence` from `Sequence.next(:bulk_action)`, which is
   an atomic `UPDATE sequences SET value = LAST_INSERT_ID(value + 1)` and so strictly increasing across processes.
2. Each entity table has `last_bulk_action_seq` / `last_bulk_action_id`, stamped on every bulk write.
3. The batch update is conditional:
   `UPDATE ... SET ..., last_bulk_action_seq = :seq WHERE id IN (...) AND (last_bulk_action_seq IS NULL OR last_bulk_action_seq <= :seq)`.
   MySQL evaluates this per row under a row lock, so it is race-free even when both actions write the same row
   at the same moment. `<=` lets retries of the same action re-apply safely.
4. Rows a newer action already owns are logged as `skipped` with `Superseded by newer bulk action #N`.
   Records that already have the target values are still stamped, so an older action can't overwrite them later.

```bash
bin/rails bulk:ordering_demo          # runs the newer action's batch first, then the older one
```

```
Final values:
  #1: name="name2 (newer action)" last_bulk_action_id=21
  ...
Action #21: completed {:success=>5, :failed=>0, :skipped=>0}
Action #20: completed {:success=>0, :failed=>0, :skipped=>5}
  skipped x5 Superseded by newer bulk action #21
```

Verified end to end as well: two actions submitted back to back on the same 3,000 contacts ran concurrently;
every contact ended with the newer action's value (the older action wrote 2,000 rows first, then skipped 1,000
as superseded).

New entities get this protection by adding the two columns; without them the handler falls back to plain updates.

## Reliability and recovery

**One transaction per batch.** `BatchJob` locks the batch's records (`SELECT ... FOR UPDATE`, in id order), runs
the handler, records field versions, bumps the counters and inserts the logs — all in one transaction. If the
worker crashes or any step fails, MySQL rolls everything back, so there is never a record that was updated but not
logged or counted. The retry starts from a clean state. Ids that already have a log row are skipped, checked again
after the row locks are taken, so two deliveries of the same batch running at the same time count each record once.

**Restartable planner.** `PlanJob` holds a Redis lease (`bulk_actions:planning:<id>`, 60s, refreshed on every page),
so only one planner works on an action. If it dies part-way, a retry or `RecoveryJob` runs it again from the start:
batches skip logged records, the dedupe set is rebuilt and `total_count` is overwritten, so nothing is processed or
counted twice. After 3 failed attempts the action is marked `failed`.

**RecoveryJob** runs every `RECOVERY_INTERVAL_SECONDS` (5 min) — exactly one run at a time across all Sidekiq
processes (a Redis tick lock; it reschedules itself and is re-armed at Sidekiq boot and on every new action).
`bin/rails bulk:recover` runs the same check once by hand.

| Stuck state | How it is detected | Fix |
|---|---|---|
| `scheduled`/`queued`, but its `PlanJob` was lost | `scheduled_at` passed 2 min ago / queued for 10 min | enqueue `PlanJob` again |
| Planner died before finishing | `in_progress`, `planned_at` empty, no planner lease | enqueue `PlanJob` (it resumes) |
| Some batches were lost (Redis data loss, retries exhausted) | planned, records pending, no batch committed for `RECOVERY_STALL_SECONDS` | re-walk the scope (records created before `planned_at`), send only records with no log row |
| All records processed but not marked completed | `processed_count >= total_count` | mark `completed` |

Every fix goes through an idempotent path, so running recovery too often or at the same time as normal processing
is harmless.

Verified by killing Sidekiq with `kill -9` in the middle of a 100,000-contact update (and deleting its queued
batches to simulate Redis data loss): after restart, recovery resumed the planner and the action completed with
exactly 100,000 processed / 100,000 logs.

---

## Load test

```bash
bin/rails "crm:seed[80000,contact]"        # dummy contacts (100,000 in total here)
bin/rails bulk:load_test                   # one bulk update over all contacts, with Sidekiq running
RECORDS=25000 bin/rails bulk:load_test     # only the first 25,000 contacts
bin/scale_test 1 2 4                       # same test with 1, 2 and 4 Sidekiq processes
```

`bulk:load_test` creates a real bulk action (status + age on every contact) through the normal pipeline
(`Creator` → `PlanJob` → `BatchJob`s → logs + counters) and reports the worker count and records/minute.
`bin/scale_test` starts N Sidekiq processes, runs the test, stops them and prints a comparison. It raises the
per-account rate limit for its own workers so the numbers show raw capacity; stop any other Sidekiq first.

### Results (one laptop: 8 cores, MySQL 8 with the default 128 MB buffer pool, batch size 500)

**Horizontal scaling — 100,000 contacts per run, rate limit raised:**

| Sidekiq processes | Threads | Time | Records / minute | Speed-up |
|---|---|---|---|---|
| 1 | 10 | 59.4s | 101,072 | 1.0x |
| 2 | 20 | 37.0s | 162,082 | 1.6x |
| 4 | 40 | 31.6s | 189,806 | 1.9x |

Every run: 100,000 success, 0 failed, 0 deadlocks, exactly 100,000 log rows, counters equal to logs.
The gain flattens at 4 processes because the workers, MySQL and Redis share one laptop; with MySQL on its own
host (and a larger buffer pool) more workers keep adding throughput.

**Rate limit — 25,000 contacts, 2 processes, limit set to 10,000/min per account:**

| Minute | Records processed |
|---|---|
| 23:30 | 10,000 |
| 23:31 | 10,000 |
| 23:32 | 5,000 |

The limit holds across processes because the counter lives in Redis; extra batches wait for the next window.

### Bottlenecks found by the load test (and fixed)

1. **Planner stalled behind batches.** `PlanJob` used to add to `total_count` after every page, on the same
   `bulk_actions` row every batch locks for its counters, so planning 100k records took 37s and extra workers
   sat idle. It now writes an estimate (`COUNT`) up front and the exact total once at the end.
2. **Deadlocks on `bulk_field_versions`.** With an auto-increment `id`, every new row was inserted at the end of
   the primary key and concurrent upserts deadlocked on its gap locks (throughput *dropped* as workers were
   added). The natural key `(entity_type, entity_id, field)` is now the primary key, so batches of different
   records write to different parts of the index.

---

## Production notes / what I would do next

- **Hot counter row**: with very high parallelism the `bulk_actions` counter row becomes a contention point. Next
  step: accumulate counters in Redis (`HINCRBY`) and flush to MySQL periodically.
- **Field versions vs. single-record edits**: the guard orders bulk actions against each other. Regular
  single-record edits from the app could also bump `bulk_field_versions` (or a `lock_version`) so a late bulk
  action never overwrites a newer manual edit.
- **Logs volume**: for millions of records per action, partition `bulk_action_logs` by date / action or move logs
  to a columnar or log store, with a retention policy.
- **Rate limiting**: fixed window allows bursts at window edges; a sliding window or GCRA would be smoother.
  Separate queues per account (or weighted fetch) would add fairness between tenants.
- **Rate-limit aware planning**: the planner enqueues all batches at once, so with a low limit most of them are
  picked up, rejected and re-scheduled every minute. The planner should enqueue only what fits in the current
  minute, save its position (`last_id`) and continue the next minute. That also gives a planner checkpoint for
  crash recovery and keeps Redis small for very large actions.
- **Scheduling**: `RecoveryJob` reschedules itself to avoid a cron dependency; in production a periodic-job
  feature (sidekiq-cron / Sidekiq Enterprise) is the simpler choice.
- **Real-time UI**: the UI polls every 2s; ActionCable / Turbo Streams could push progress instead.
- Authentication / multi-tenancy (deriving `account_id` from the caller).
