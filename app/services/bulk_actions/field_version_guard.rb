module BulkActions
  # Last-writer-wins per field across bulk actions, independent of execution order.
  #
  # Reads which action last wrote each field of the batch's records, lets the handler apply only the fields
  # this action is entitled to, then records this action as the latest writer of those fields.
  # Must run inside the batch transaction with the records already locked (BatchJob does both), so the
  # check, the write and the version update are atomic with respect to other batches.
  class FieldVersionGuard
    def initialize(bulk_action, entity)
      @bulk_action = bulk_action
      @entity = entity
      @mine = bulk_action.version_key
    end

    def track(records, fields)
      load_versions(records.map(&:id), fields)
      @touched = []
      result = yield
      write_versions
      result
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
