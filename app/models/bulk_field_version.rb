# Remembers which bulk action last wrote each (entity record, field), so an older action that runs late
# (rate-limit delay, retry, slow worker) can never overwrite a newer action's value.
class BulkFieldVersion < ApplicationRecord
  # The table's primary key is (entity_type, entity_id, field), which Rails 7.0 models can't express.
  self.primary_key = nil
end
