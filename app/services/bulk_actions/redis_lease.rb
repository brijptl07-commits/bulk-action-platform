module BulkActions
  # A Redis lock that expires on its own if the holder dies, so a crashed worker never blocks others for
  # longer than `ttl`. The holder calls `refresh!` while it is still working (a heartbeat).
  class RedisLease
    RELEASE = "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) else return 0 end".freeze
    REFRESH = "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('EXPIRE', KEYS[1], ARGV[2]) else return 0 end".freeze

    def self.acquire(key, ttl:)
      token = SecureRandom.hex(16)
      acquired = Sidekiq.redis { |r| r.call("SET", key, token, "NX", "EX", ttl) }
      new(key, token, ttl) if acquired
    end

    def self.held?(key)
      Sidekiq.redis { |r| r.call("EXISTS", key) }.to_i.positive?
    end

    def initialize(key, token, ttl)
      @key = key
      @token = token
      @ttl = ttl
    end

    def refresh!
      Sidekiq.redis { |r| r.call("EVAL", REFRESH, 1, @key, @token, @ttl) }.to_i.positive?
    end

    def release!
      Sidekiq.redis { |r| r.call("EVAL", RELEASE, 1, @key, @token) }
    end
  end
end
