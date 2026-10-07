module BulkActions
  # Runs Recovery every `Config.recovery_interval_seconds`, without a cron dependency: each run schedules
  # the next one.
  #
  # Exactly one chain stays alive across all Sidekiq processes:
  #   - `ensure_scheduled` (called at Sidekiq boot and on every new bulk action) only enqueues a run when
  #     no chain is alive, tracked by a "next run" key that expires if the chain is lost;
  #   - a per-interval tick lock means that if two runs ever overlap, only one works and reschedules,
  #     and the extra one ends.
  class RecoveryJob
    include Sidekiq::Job
    sidekiq_options queue: "bulk_actions", retry: 0

    TICK_KEY = "bulk_actions:recovery:tick".freeze
    NEXT_KEY = "bulk_actions:recovery:next".freeze

    def self.ensure_scheduled
      interval = Config.recovery_interval_seconds
      armed = Sidekiq.redis { |r| r.call("SET", NEXT_KEY, "1", "NX", "EX", interval * 2) }
      perform_async if armed
    end

    def perform
      interval = Config.recovery_interval_seconds
      acquired = Sidekiq.redis { |r| r.call("SET", TICK_KEY, jid, "NX", "EX", [interval - 5, 1].max) }
      return unless acquired

      report = Recovery.call
      logger.info("Bulk action recovery: #{report}") if report.any?
    ensure
      if acquired
        Sidekiq.redis { |r| r.call("SET", NEXT_KEY, "1", "EX", interval * 2) }
        self.class.perform_in(interval)
      end
    end
  end
end
