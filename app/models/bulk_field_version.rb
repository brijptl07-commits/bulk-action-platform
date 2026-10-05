# Remembers which bulk action last wrote each (entity record, field), so an older action that runs late
# (rate-limit delay, retry, slow worker) can never overwrite a newer action's value.
class BulkFieldVersion < ApplicationRecord
end
