class AddBulkActionOrdering < ActiveRecord::Migration[7.0]
  ENTITY_TABLES = %i[contacts companies leads opportunities tasks].freeze

  def change
    create_table :sequences do |t|
      t.string :name, null: false
      t.bigint :value, null: false, default: 0
    end
    add_index :sequences, :name, unique: true

    add_column :bulk_actions, :sequence, :bigint
    add_index :bulk_actions, :sequence

    ENTITY_TABLES.each do |table|
      add_column table, :last_bulk_action_id, :bigint
      add_column table, :last_bulk_action_seq, :bigint
    end
  end
end
