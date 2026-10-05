module BulkActions
  # Step 2: processes one chunk of ids. Many of these run in parallel across Sidekiq processes,
  # which is how the system scales horizontally.
  #
  # Safe to retry: ids already logged for this action are skipped, and logs + counters are written
  # in one transaction (the unique index on [bulk_action_id, entity_id] guards against double logging).
  class BatchJob
    include Sidekiq::Job
    sidekiq_options queue: "bulk_action_batches", retry: 5

    def perform(bulk_action_id, ids, duplicate_ids = [])
      bulk_action = BulkAction.find_by(id: bulk_action_id)
      return unless bulk_action&.in_progress?

      already_logged = bulk_action.logs.where(entity_id: ids + duplicate_ids).pluck(:entity_id).to_set
      ids -= already_logged.to_a
      duplicate_ids -= already_logged.to_a
      return BulkAction.complete_if_done!(bulk_action.id) if ids.empty? && duplicate_ids.empty?

      if ids.any?
        wait = RateLimiter.acquire(bulk_action.account_id, ids.size)
        if wait.positive?
          self.class.perform_in(wait, bulk_action_id, ids, duplicate_ids)
          return
        end
      end

      entity = bulk_action.entity_config
      records = entity.model.where(id: ids).to_a
      results = records.any? ? bulk_action.handler_class.new(bulk_action, entity).call(records) : []

      missing_ids = ids - records.map(&:id)
      results += missing_ids.map { |id| Handlers::Base::Result.new(id, "skipped", "Record not found") }
      results += duplicate_ids.map do |id|
        Handlers::Base::Result.new(id, "skipped", "Duplicate #{entity.dedupe_field}")
      end

      persist(bulk_action, results)
      BulkAction.complete_if_done!(bulk_action.id)
    end

    private

    # Counters are updated before logs are inserted so every transaction takes the exclusive lock on
    # the bulk_actions row first; inserting child rows first (FK shared lock) and then upgrading
    # deadlocks under concurrency in MySQL.
    def persist(bulk_action, results, attempts: 3)
      now = Time.current
      counts = results.group_by(&:status).transform_values(&:size)

      ActiveRecord::Base.transaction do
        BulkAction.update_counters(
          bulk_action.id,
          processed_count: results.size,
          success_count: counts.fetch("success", 0),
          failure_count: counts.fetch("failed", 0),
          skipped_count: counts.fetch("skipped", 0),
          touch: true
        )
        BulkActionLog.insert_all(
          results.map { |r| { bulk_action_id: bulk_action.id, entity_id: r.entity_id, status: r.status, message: r.message, created_at: now } }
        )
      end
    rescue ActiveRecord::Deadlocked
      attempts -= 1
      raise if attempts.zero?

      sleep(rand * 0.2)
      retry
    end
  end
end
