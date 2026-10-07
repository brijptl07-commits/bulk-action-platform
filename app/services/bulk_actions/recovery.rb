module BulkActions
  # Finds bulk actions that stopped making progress and puts them back on track. Safe to run at any time
  # and any number of times: every fix goes through an idempotent path (PlanJob start/resume, or BatchJob,
  # which skips records that are already logged).
  #
  # What can get stuck, and the fix:
  #   scheduled/queued, but its PlanJob was lost         -> enqueue PlanJob again
  #   in_progress, planner died before finishing         -> enqueue PlanJob again (it resumes)
  #   in_progress, planned, but some batches were lost   -> re-send the records that have no log row yet
  #   in_progress, all records processed, not completed  -> mark completed
  class Recovery
    SCHEDULE_GRACE = 2.minutes
    PLANNER_GRACE = 2.minutes

    def self.call(now: Time.current)
      new(now).call
    end

    def initialize(now)
      @now = now
      @stall = Config.recovery_stall_seconds.seconds
      @report = Hash.new(0)
    end

    def call
      start_lost_plans
      resume_dead_planners
      finish_or_resend
      @report
    end

    private

    def start_lost_plans
      BulkAction.where(status: "scheduled").where("scheduled_at <= ?", @now - SCHEDULE_GRACE).find_each do |action|
        PlanJob.perform_async(action.id)
        @report[:plans_restarted] += 1
      end
      BulkAction.where(status: "queued").where("created_at <= ?", @now - @stall).find_each do |action|
        PlanJob.perform_async(action.id)
        @report[:plans_restarted] += 1
      end
    end

    def resume_dead_planners
      BulkAction.where(status: "in_progress", planned_at: nil).where("updated_at <= ?", @now - PLANNER_GRACE).find_each do |action|
        next if RedisLease.held?(PlanJob.lease_key(action.id))

        PlanJob.perform_async(action.id)
        @report[:planners_resumed] += 1
      end
    end

    def finish_or_resend
      BulkAction.where(status: "in_progress").where.not(planned_at: nil).find_each do |action|
        if BulkAction.complete_if_done!(action.id).positive?
          @report[:completed] += 1
        elsif action.updated_at <= @now - @stall
          @report[:records_resent] += resend_unprocessed(action)
        end
      end
    end

    # No batch has committed for a while, yet records are still pending: their BatchJobs were lost
    # (e.g. Redis data loss, or a job that exhausted its retries). Re-walk the planned scope and send
    # only the records that have no log row.
    def resend_unprocessed(action)
      sent = 0
      Planner.new(action, created_before: action.planned_at, dedupe_namespace: "recover").each_page do |page|
        ids, duplicate_ids = action.without_logged(page.ids, page.duplicate_ids)
        next if ids.empty? && duplicate_ids.empty?

        BatchJob.perform_async(action.id, ids, duplicate_ids)
        sent += ids.size + duplicate_ids.size
      end
      # Restarts the stall timer, so the re-sent batches get a full window before the next re-send.
      action.touch
      sent
    end
  end
end
