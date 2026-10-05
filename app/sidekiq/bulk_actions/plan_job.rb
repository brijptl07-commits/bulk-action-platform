module BulkActions
  # Step 1: walks the target records with keyset pagination (WHERE id > last ORDER BY id LIMIT n),
  # snapshots their ids, applies de-duplication and fans out one BatchJob per chunk.
  # Never loads the full result set into memory, so it scales to millions of rows.
  class PlanJob
    include Sidekiq::Job
    sidekiq_options queue: "bulk_actions", retry: 0

    def perform(bulk_action_id)
      bulk_action = BulkAction.find_by(id: bulk_action_id)
      return unless bulk_action
      return unless bulk_action.transition!(from: %w[queued scheduled], to: "in_progress", started_at: Time.current)

      entity = bulk_action.entity_config
      scope = ScopeBuilder.new(entity, bulk_action.filters).relation
      dedupe_field = bulk_action.dedupe ? entity.dedupe_field : nil
      deduplicator = Deduplicator.new(bulk_action) if dedupe_field
      columns = [:id, dedupe_field].compact
      batch_size = Config.batch_size
      last_id = 0

      loop do
        rows = scope.where("#{entity.model.quoted_table_name}.id > ?", last_id).order(:id).limit(batch_size).pluck(*columns)
        break if rows.empty?

        rows = rows.map { |r| Array(r) }
        last_id = rows.last.first
        ids, duplicate_ids = deduplicator ? deduplicator.split(rows) : [rows.map(&:first), []]

        BulkAction.update_counters(bulk_action.id, total_count: rows.size)
        BatchJob.perform_async(bulk_action.id, ids, duplicate_ids)

        break if BulkAction.where(id: bulk_action.id, status: "cancelled").exists?
      end

      bulk_action.update_columns(planned_at: Time.current, updated_at: Time.current)
      BulkAction.complete_if_done!(bulk_action.id)
    rescue StandardError => e
      BulkAction.where(id: bulk_action_id, status: "in_progress")
                .update_all(status: "failed", error_message: "#{e.class}: #{e.message}", completed_at: Time.current)
      raise
    ensure
      deduplicator&.cleanup
    end
  end
end
