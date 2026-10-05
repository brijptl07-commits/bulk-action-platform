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
   │  - handler = ActionRegistry[action_type] │
   │  - handler.call(records) → results       │  1 bulk UPDATE per batch
   │  - txn: counters += ..., insert logs     │
   │  - mark completed when processed = total │
   └──────────────────┬───────────────────────┘
                      ▼
                 ┌──────────────┐
                 │    MySQL     │  CRM entity tables, bulk_actions, bulk_action_logs
                 └──────────────┘
```

### Key design decisions

| Concern | Approach |
|---|---|
| **Large volumes** | Planner never loads the full set: keyset pagination on the primary key, only `id` (+ dedupe field) is plucked. Ids are snapshotted at plan time, so updating the field you filtered on doesn't shift the target set. |
| **Efficient writes** | Each batch validates records in memory (so per-record errors are logged) and then writes all valid rows with a **single** `UPDATE ... WHERE id IN (...)`. Logs are written with one multi-row `INSERT`. |
| **Horizontal scaling** | All state lives in MySQL/Redis. Run more `sidekiq` processes (on any machine) to process more batches in parallel. |
| **Progress / stats** | Counters (`total`, `processed`, `success`, `failed`, `skipped`) are maintained atomically with `UPDATE ... SET x = x + n` — stats are O(1), no `COUNT(*)` over logs. |
| **Reliability** | Batch jobs retry (Sidekiq, 5 attempts). They are idempotent: already-logged ids are skipped, and a unique index on `(bulk_action_id, entity_id)` prevents double logging. Counter update + log insert happen in one transaction (counter row locked first to avoid MySQL FK deadlocks). Status changes use conditional updates (`WHERE status IN (...)`) so concurrent workers can't race. |
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

Statuses: `scheduled → queued → in_progress → completed | failed | cancelled`

### Code map

```
app/services/bulk_actions/
  entity_registry.rb      # register entities (model, updatable/filterable fields, dedupe field)
  action_registry.rb      # register actions (action_type → handler)
  handlers/base.rb        # handler contract
  handlers/bulk_update.rb # the Bulk Update action
  creator.rb              # validate request, persist, enqueue (now or scheduled)
  scope_builder.rb        # filters → ActiveRecord relation
  rate_limiter.rb         # per-account fixed-window limiter (Redis + Lua, atomic)
  deduplicator.rb         # Redis-set based de-duplication
app/sidekiq/bulk_actions/
  plan_job.rb             # step 1: plan & fan out batches
  batch_job.rb            # step 2: process a batch
config/initializers/bulk_actions.rb   # registrations
app/controllers/api/*     # JSON API
app/controllers/ui/*      # basic UI
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

Requirements: Ruby 3.1.3, MySQL 8, **Redis 6+** (Sidekiq 7 requirement).

```bash
bundle install
cp .env.example .env            # set DB_PASSWORD etc.
docker compose up -d redis      # Redis 7 on localhost:6380 (skip if you have Redis 6+)

bin/rails db:create db:migrate
bin/rails db:seed                          # 2,000 records per entity (~5% duplicate emails/domains)
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
| `RATE_LIMIT_PER_MINUTE` | 10000 | max records processed per account per minute |
| `SIDEKIQ_CONCURRENCY` | 10 | threads per Sidekiq process |
| `REDIS_URL` | redis://localhost:6380/0 | Redis |
| `DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD`, `DB_POOL` | | MySQL |

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
would exceed `RATE_LIMIT_PER_MINUTE` (default 10k), the batch is re-scheduled to the start of the next window instead
of being dropped. The limit is shared across all workers/processes.

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

## Load test

```bash
bin/rails "crm:seed[18000,contact]"   # 20,000 contacts in total
bin/rails "bulk:load_test"
```

Results on a laptop (MySQL 8, 20,000 contacts, batch size 500):

| Setup | Result |
|---|---|
| 2 Sidekiq processes × 10 threads, rate limit raised | 20,000 records in 5.6s ≈ **213,000 records/min** |
| default rate limit 10,000/min per account | progress pauses at the limit and resumes in the next minute window |

---

## Production notes / what I would do next

- **Hot counter row**: with very high parallelism the `bulk_actions` counter row becomes a contention point. Next
  step: accumulate counters in Redis (`HINCRBY`) and flush to MySQL periodically.
- **Logs volume**: for millions of records per action, partition `bulk_action_logs` by date / action or move logs
  to a columnar or log store, with a retention policy.
- **Rate limiting**: fixed window allows bursts at window edges; a sliding window or GCRA would be smoother.
  Separate queues per account (or weighted fetch) would add fairness between tenants.
- **Planner restart**: the planner is single-shot; for very large actions it could checkpoint `last_id` so it can
  resume after a crash.
- **Real-time UI**: the UI polls every 2s; ActionCable / Turbo Streams could push progress instead.
- Authentication / multi-tenancy (deriving `account_id` from the caller), and automated tests (RSpec).
