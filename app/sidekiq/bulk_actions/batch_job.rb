module BulkActions
  # Step 2: processes one chunk of ids. Many of these run in parallel across Sidekiq processes,
  # which is how the system scales horizontally.
  #
  # The whole batch is one transaction: lock the records, apply the action, record field versions,
  # bump the counters and insert the logs. A crash or error anywhere rolls all of it back, so a retry
  # (Sidekiq's, or RecoveryJob's re-send) redoes the batch from a clean state. Ids that already have a
  # log row are skipped, which makes duplicate deliveries of the same batch harmless.
  class BatchJob
    include Sidekiq::Job
    sidekiq_options queue: "bulk_action_batches", retry: 5

    def perform(bulk_action_id, ids, duplicate_ids = [])
      bulk_action = BulkAction.find_by(id: bulk_action_id)
      return unless bulk_action&.in_progress?

      ids, duplicate_ids = bulk_action.without_logged(ids, duplicate_ids)
      return BulkAction.complete_if_done!(bulk_action.id) if ids.empty? && duplicate_ids.empty?

      if ids.any?
        wait = RateLimiter.acquire(bulk_action.account_id, ids.size)
        if wait.positive?
          self.class.perform_in(wait, bulk_action_id, ids, duplicate_ids)
          return
        end
      end

      with_deadlock_retry { process(bulk_action, ids, duplicate_ids) }
      BulkAction.complete_if_done!(bulk_action.id)
    end

    private

    def process(bulk_action, ids, duplicate_ids)
      entity = bulk_action.entity_config

      # Sidekiq runs jobs with the query cache on; a cached read here would hide logs and field versions
      # committed by other batches while this one waited for the row locks.
      ActiveRecord::Base.uncached do
        ActiveRecord::Base.transaction do
          locked = entity.model.where(id: ids + duplicate_ids).order(:id).lock.to_a
          # Checked again under the row locks: a concurrent copy of this batch that committed first is visible now.
          ids, duplicate_ids = bulk_action.without_logged(ids, duplicate_ids)
          next if ids.empty? && duplicate_ids.empty?

          pending = ids.to_set
          records = locked.select { |record| pending.include?(record.id) }
          results = records.any? ? bulk_action.handler_class.new(bulk_action, entity).call(records) : []

          missing_ids = ids - results.map(&:entity_id)
          results += missing_ids.map { |id| Handlers::Base::Result.new(id, "skipped", "Record not found") }
          results += duplicate_ids.map do |id|
            Handlers::Base::Result.new(id, "skipped", "Duplicate #{entity.dedupe_field}")
          end

          record_results(bulk_action, results)
        end
      end
    end

    # Counters are updated before logs are inserted so every transaction takes the exclusive lock on
    # the bulk_actions row first; inserting child rows first (FK shared lock) and then upgrading
    # deadlocks under concurrency in MySQL.
    def record_results(bulk_action, results)
      now = Time.current
      counts = results.group_by(&:status).transform_values(&:size)

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

    # MySQL picks a victim when two batches lock overlapping rows; its transaction is rolled back
    # completely, so it is safe to run the whole batch again.
    def with_deadlock_retry(attempts: 3)
      yield
    rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
      attempts -= 1
      raise if attempts.zero?

      sleep(rand * 0.2)
      retry
    end
  end
end
