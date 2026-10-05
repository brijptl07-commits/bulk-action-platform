class CreateBulkActionLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :bulk_action_logs do |t|
      t.references :bulk_action, null: false, foreign_key: true, index: false
      t.bigint :entity_id, null: false
      t.string :status, null: false
      t.text :message
      t.datetime :created_at, null: false
    end

    add_index :bulk_action_logs, [:bulk_action_id, :status]
    add_index :bulk_action_logs, [:bulk_action_id, :entity_id], unique: true
  end
end
