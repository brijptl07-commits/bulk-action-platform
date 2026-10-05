class CreateBulkFieldVersions < ActiveRecord::Migration[7.0]
  def change
    create_table :bulk_field_versions do |t|
      t.string :entity_type, null: false
      t.bigint :entity_id, null: false
      t.string :field, null: false
      t.bigint :bulk_action_id, null: false
      t.datetime :effective_at, precision: 6, null: false
    end

    add_index :bulk_field_versions, %i[entity_type entity_id field], unique: true, name: "index_bulk_field_versions_on_entity_field"
  end
end
