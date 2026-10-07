module BulkActions
  # Walks an action's target records in id order (keyset pagination) and yields one page at a time,
  # split into ids to process and duplicate ids. Used by PlanJob to plan batches, and by Recovery to find
  # records that were planned but never processed.
  #
  # created_before: ignore records created after this time (Recovery uses planned_at, so it only
  # re-walks the records the original plan could have seen).
  class Planner
    Page = Struct.new(:ids, :duplicate_ids, :size, :last_id)

    def initialize(bulk_action, created_before: nil, dedupe_namespace: "plan")
      @bulk_action = bulk_action
      @entity = bulk_action.entity_config
      @created_before = created_before
      @dedupe_field = bulk_action.dedupe ? @entity.dedupe_field : nil
      @deduplicator = Deduplicator.new(bulk_action, dedupe_namespace) if @dedupe_field
    end

    def count
      scope.count
    end

    def each_page
      @deduplicator&.cleanup
      after_id = 0
      while (page = next_page(after_id))
        yield page
        after_id = page.last_id
      end
    ensure
      @deduplicator&.cleanup
    end

    private

    def next_page(after_id)
      columns = [:id, @dedupe_field].compact
      rows = scope.where("#{@entity.model.quoted_table_name}.id > ?", after_id).order(:id).limit(Config.batch_size).pluck(*columns)
      return if rows.empty?

      rows = rows.map { |row| Array(row) }
      ids, duplicate_ids = @deduplicator ? @deduplicator.split(rows) : [rows.map(&:first), []]
      Page.new(ids, duplicate_ids, rows.size, rows.last.first)
    end

    def scope
      relation = ScopeBuilder.new(@entity, @bulk_action.filters).relation
      return relation unless @created_before

      relation.where("#{@entity.model.quoted_table_name}.created_at <= ?", @created_before)
    end
  end
end
