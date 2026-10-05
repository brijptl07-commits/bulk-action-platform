class CreateBulkActions < ActiveRecord::Migration[7.0]
  def change
    create_table :bulk_actions do |t|
      t.string :account_id, null: false
      t.string :entity_type, null: false
      t.string :action_type, null: false
      t.string :status, null: false, default: "queued"

      t.json :payload
      t.json :filters
      t.boolean :dedupe, null: false, default: false

      t.integer :total_count, null: false, default: 0
      t.integer :processed_count, null: false, default: 0
      t.integer :success_count, null: false, default: 0
      t.integer :failure_count, null: false, default: 0
      t.integer :skipped_count, null: false, default: 0

      t.datetime :scheduled_at
      t.datetime :started_at
      t.datetime :planned_at
      t.datetime :completed_at
      t.text :error_message

      t.timestamps
    end

    add_index :bulk_actions, :status
    add_index :bulk_actions, [:account_id, :created_at]
  end
end
