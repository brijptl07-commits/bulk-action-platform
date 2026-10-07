require "test_helper"

class BulkActions::RateLimiterTest < ActiveSupport::TestCase
  Limiter = BulkActions::RateLimiter

  test "allows up to the limit per account per minute, then asks to wait for the next minute" do
    now = Time.zone.parse("2026-10-07 10:00:20")

    assert_equal 0, Limiter.acquire("acc_1", 6, limit: 10, now: now)
    assert_equal 0, Limiter.acquire("acc_1", 4, limit: 10, now: now)
    assert_includes 40..42, Limiter.acquire("acc_1", 1, limit: 10, now: now)
    assert_equal 10, Limiter.usage("acc_1", now: now)

    assert_equal 0, Limiter.acquire("acc_2", 10, limit: 10, now: now), "accounts are limited separately"
    assert_equal 0, Limiter.acquire("acc_1", 10, limit: 10, now: now + 1.minute), "a new minute starts fresh"
  end
end
