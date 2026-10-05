module BulkActions
  # Last-writer-wins per field across bulk actions, independent of execution order.
  #
  # Inside one transaction it locks the batch's rows (SELECT ... FOR UPDATE, ordered by id so concurrent
  # batches lock in the same order), reads which action last wrote each field, lets the handler apply only
  # the fields this action is entitled to, then records this action as the latest writer of those fields.
  class FieldVersionGuard
    def initialize(bulk_action, entity)
      @bulk_action = bulk_action
      @entity = entity
      @mine = bulk_action.version_key
    end

    # Yields the locked, freshly loaded records. Retries the whole unit on deadlock.
    def synchronize(ids, fields, attempts: 3)
      ActiveRecord::Base.transaction do
        records = @entity.model.where(id: ids).order(:id).lock.to_a
        load_versions(records.map(&:id), fields)
        @touched = []
        result = yield records
        write_versions
        result
      end
    rescue ActiveRecord::Deadlocked
      attempts -= 1
      raise if attempts.zero?

      sleep(rand * 0.2)
      retry
    end

    # Returns [fields this action may write, ids of newer actions that own the other fields].
    def partition(entity_id, fields)
      allowed = []
      superseded_by = []
      fields.each do |field|
        owner = @latest[[entity_id, field]]
        if owner.nil? || owner[1] == @bulk_action.id || (owner <=> @mine) <= 0
          allowed << field
        else
          superseded_by << owner[1]
        end
      end
      [allowed, superseded_by.uniq]
    end

    # Marks this action as the latest writer of `fields` on `entity_id` (also for no-op writes, so an
    # older action can't later overwrite a value this action confirmed).
    def touch(entity_id, fields)
      fields.each { |field| @touched << [entity_id, field] }
    end

    private

    def load_versions(ids, fields)
      @latest = BulkFieldVersion
                .where(entity_type: @entity.name, entity_id: ids, field: fields)
                .pluck(:entity_id, :field, :effective_at, :bulk_action_id)
                .to_h { |id, field, at, action_id| [[id, field], [at, action_id]] }
    end

    def write_versions
      return if @touched.empty?

      BulkFieldVersion.upsert_all(
        @touched.map do |entity_id, field|
          { entity_type: @entity.name, entity_id: entity_id, field: field,
            bulk_action_id: @bulk_action.id, effective_at: @mine[0] }
        end
      )
    end
  end
end
