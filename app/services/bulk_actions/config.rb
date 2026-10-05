module BulkActions
  module Config
    module_function

    def batch_size
      [ENV.fetch("BULK_BATCH_SIZE", 500).to_i, rate_limit_per_minute].min.clamp(1, 10_000)
    end

    def rate_limit_per_minute
      ENV.fetch("RATE_LIMIT_PER_MINUTE", 10_000).to_i
    end
  end
end
