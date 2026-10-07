module BulkActions
  # Step 1: one job per bulk action. Walks the target records and enqueues a BatchJob per page.
  #
  # Planning is restartable: if this job crashes (or the worker is killed) part-way, a retry or
  # RecoveryJob runs it again from the start. That is safe because batches skip records that are
  # already logged, the dedupe set is rebuilt, and total_count is overwritten rather than added to.
  # A Redis lease with a heartbeat makes sure only one planner works on an action at a time.
  class PlanJob
    include Sidekiq::Job
    sidekiq_options queue: "bulk_actions", retry: 3

    LEASE_TTL = 60

    sidekiq_retries_exhausted do |job, error|
      BulkAction.where(id: job["args"].first, status: "in_progress", planned_at: nil)
                .update_all(status: "failed", error_message: "#{error.class}: #{error.message}",
                            completed_at: Time.current, updated_at: Time.current)
    end

    def self.lease_key(bulk_action_id)
      "bulk_actions:planning:#{bulk_action_id}"
    end

    def perform(bulk_action_id)
      bulk_action = BulkAction.find_by(id: bulk_action_id)
      return unless bulk_action && start_or_resume(bulk_action)

      lease = RedisLease.acquire(self.class.lease_key(bulk_action.id), ttl: LEASE_TTL)
      return unless lease

      begin
        plan(bulk_action, lease)
      ensure
        lease.release!
      end
      BulkAction.complete_if_done!(bulk_action.id)
    end

    private

    def start_or_resume(bulk_action)
      return true if bulk_action.transition!(from: %w[queued scheduled], to: "in_progress", started_at: Time.current,
                                             sequence: Sequence.next(:bulk_action))

      bulk_action.reload.in_progress? && bulk_action.planned_at.nil?
    end

    def plan(bulk_action, lease)
      planner = Planner.new(bulk_action)
      # Estimate up front so progress is meaningful while planning; the exact total is written once at
      # the end. Updating the bulk_actions row after every page would contend with the BatchJobs that
      # update its counters.
      bulk_action.update_columns(total_count: planner.count, updated_at: Time.current)

      planned = 0
      planner.each_page do |page|
        planned += page.size
        BatchJob.perform_async(bulk_action.id, page.ids, page.duplicate_ids)
        lease.refresh!
        break if BulkAction.where(id: bulk_action.id, status: "cancelled").exists?
      end

      bulk_action.update_columns(total_count: planned, planned_at: Time.current, updated_at: Time.current)
    end
  end
end
