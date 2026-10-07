# Concurrent upserts of new rows all landed at the end of the auto-increment primary key and deadlocked on
# its gap locks. Clustering by (entity_type, entity_id, field) spreads batches of different records apart.
class UseNaturalKeyForBulkFieldVersions < ActiveRecord::Migration[7.0]
  def up
    execute <<~SQL
      ALTER TABLE bulk_field_versions
        DROP INDEX index_bulk_field_versions_on_entity_field,
        DROP COLUMN id,
        ADD PRIMARY KEY (entity_type, entity_id, field)
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE bulk_field_versions
        DROP PRIMARY KEY,
        ADD COLUMN id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY FIRST,
        ADD UNIQUE INDEX index_bulk_field_versions_on_entity_field (entity_type, entity_id, field)
    SQL
  end
end
