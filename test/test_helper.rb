ENV["RAILS_ENV"] = "test"
require_relative "../config/environment"
abort("Tests must run with RAILS_ENV=test (they wipe the database)") unless Rails.env.test?
require "rails/test_help"
require "minitest/mock"
require "sidekiq/testing"

# Jobs are captured in memory (Sidekiq::Testing.fake!), but the rate limiter, dedupe sets and leases
# still use Redis, so the tests get their own Redis database.
Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0").sub(%r{/\d+\z}, "") + "/15" }
end

class ActiveSupport::TestCase
  # BatchJob relies on real transactions and row locks, so tests commit and clean up after themselves.
  self.use_transactional_tests = false

  TABLES = [BulkActionLog, BulkFieldVersion, BulkAction, Opportunity, Company, Contact, Lead, Task].freeze

  setup do
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
    Sidekiq.redis { |r| r.call("FLUSHDB") }
    TABLES.each(&:delete_all)
  end

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value.to_s }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  def create_contacts(count, **attrs)
    Array.new(count) do |i|
      Contact.create!({ name: "Contact #{i}", email: "contact#{i}@example.com", age: 30, status: "lead" }.merge(attrs))
    end
  end

  def create_action(fields:, filters: { "all" => true }, **attrs)
    BulkAction.create!({ account_id: "acc_test", entity_type: "contact", action_type: "bulk_update",
                         payload: { "fields" => fields }, filters: filters, status: "in_progress",
                         started_at: Time.current }.merge(attrs))
  end

  # Runs the plan and every batch it produced (and any batches those re-enqueue).
  def run_jobs
    BulkActions::PlanJob.drain
    BulkActions::BatchJob.drain
  end
end
