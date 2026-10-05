module BulkActions
  # Fixed-window (per minute) rate limiter keyed by account, shared by all workers via Redis.
  # `acquire` atomically reserves `count` units; returns 0 when allowed, otherwise the number of
  # seconds to wait until the next window.
  class RateLimiter
    SCRIPT = <<~LUA.freeze
      local current = tonumber(redis.call('GET', KEYS[1]) or '0')
      local n = tonumber(ARGV[1])
      local limit = tonumber(ARGV[2])
      if current + n > limit then
        return 0
      end
      redis.call('INCRBY', KEYS[1], n)
      redis.call('EXPIRE', KEYS[1], 120)
      return 1
    LUA

    def self.acquire(account_id, count, limit: Config.rate_limit_per_minute, now: Time.current)
      window = now.to_i / 60
      key = "bulk_actions:rate:#{account_id}:#{window}"
      allowed = Sidekiq.redis { |r| r.call("EVAL", SCRIPT, 1, key, count, limit) }
      allowed == 1 ? 0 : ((window + 1) * 60 - now.to_i) + rand(0..2)
    end

    def self.usage(account_id, now: Time.current)
      Sidekiq.redis { |r| r.call("GET", "bulk_actions:rate:#{account_id}:#{now.to_i / 60}") }.to_i
    end
  end
end
