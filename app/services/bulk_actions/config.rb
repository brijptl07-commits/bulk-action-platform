module BulkActions
  module Config
    module_function

    def batch_size
      [ENV.fetch("BULK_BATCH_SIZE", 500).to_i, rate_limit_per_minute].min.clamp(1, 10_000)
    end

    def rate_limit_per_minute
      ENV.fetch("RATE_LIMIT_PER_MINUTE", 30_000).to_i
    end

    # How often RecoveryJob runs.
    def recovery_interval_seconds
      ENV.fetch("RECOVERY_INTERVAL_SECONDS", 300).to_i.clamp(10, 3600)
    end

    # An in-progress action with no committed batch for this long is considered stuck.
    def recovery_stall_seconds
      ENV.fetch("RECOVERY_STALL_SECONDS", 600).to_i.clamp(30, 86_400)
    end
  end
end
