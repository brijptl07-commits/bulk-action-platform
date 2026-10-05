# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.0].define(version: 2026_10_05_192114) do
  create_table "bulk_action_logs", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "bulk_action_id", null: false
    t.bigint "entity_id", null: false
    t.string "status", null: false
    t.text "message"
    t.datetime "created_at", null: false
    t.index ["bulk_action_id", "entity_id"], name: "index_bulk_action_logs_on_bulk_action_id_and_entity_id", unique: true
    t.index ["bulk_action_id", "status"], name: "index_bulk_action_logs_on_bulk_action_id_and_status"
  end

  create_table "bulk_actions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "account_id", null: false
    t.string "entity_type", null: false
    t.string "action_type", null: false
    t.string "status", default: "queued", null: false
    t.json "payload"
    t.json "filters"
    t.boolean "dedupe", default: false, null: false
    t.integer "total_count", default: 0, null: false
    t.integer "processed_count", default: 0, null: false
    t.integer "success_count", default: 0, null: false
    t.integer "failure_count", default: 0, null: false
    t.integer "skipped_count", default: 0, null: false
    t.datetime "scheduled_at"
    t.datetime "started_at"
    t.datetime "planned_at"
    t.datetime "completed_at"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "sequence"
    t.index ["account_id", "created_at"], name: "index_bulk_actions_on_account_id_and_created_at"
    t.index ["sequence"], name: "index_bulk_actions_on_sequence"
    t.index ["status"], name: "index_bulk_actions_on_status"
  end

  create_table "companies", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "name", null: false
    t.string "domain"
    t.string "industry"
    t.integer "employee_count"
    t.string "status", default: "prospect", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "last_bulk_action_id"
    t.bigint "last_bulk_action_seq"
    t.index ["domain"], name: "index_companies_on_domain"
    t.index ["industry"], name: "index_companies_on_industry"
    t.index ["status"], name: "index_companies_on_status"
  end

  create_table "contacts", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "name", null: false
    t.string "email"
    t.integer "age"
    t.string "status", default: "lead", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "last_bulk_action_id"
    t.bigint "last_bulk_action_seq"
    t.index ["email"], name: "index_contacts_on_email"
    t.index ["status"], name: "index_contacts_on_status"
  end

  create_table "leads", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "name", null: false
    t.string "email"
    t.string "company_name"
    t.string "source"
    t.integer "score"
    t.string "status", default: "new", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "last_bulk_action_id"
    t.bigint "last_bulk_action_seq"
    t.index ["email"], name: "index_leads_on_email"
    t.index ["source"], name: "index_leads_on_source"
    t.index ["status"], name: "index_leads_on_status"
  end

  create_table "opportunities", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "name", null: false
    t.bigint "company_id"
    t.decimal "amount", precision: 12, scale: 2
    t.string "stage", default: "prospecting", null: false
    t.integer "probability"
    t.date "close_date"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "last_bulk_action_id"
    t.bigint "last_bulk_action_seq"
    t.index ["company_id"], name: "index_opportunities_on_company_id"
    t.index ["stage"], name: "index_opportunities_on_stage"
  end

  create_table "sequences", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "name", null: false
    t.bigint "value", default: 0, null: false
    t.index ["name"], name: "index_sequences_on_name", unique: true
  end

  create_table "tasks", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "title", null: false
    t.text "description"
    t.string "status", default: "todo", null: false
    t.string "priority", default: "medium", null: false
    t.date "due_date"
    t.string "assignee"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "last_bulk_action_id"
    t.bigint "last_bulk_action_seq"
    t.index ["assignee"], name: "index_tasks_on_assignee"
    t.index ["priority"], name: "index_tasks_on_priority"
    t.index ["status"], name: "index_tasks_on_status"
  end

  add_foreign_key "bulk_action_logs", "bulk_actions"
  add_foreign_key "opportunities", "companies"
end
