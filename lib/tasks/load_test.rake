require "sidekiq/api"

namespace :bulk do
  desc "End-to-end throughput test on contacts. Requires Sidekiq running. " \
       "Usage: rake bulk:load_test[account_id]  (RECORDS=n to target the first n contacts, " \
       "DEDUPE=1 to enable de-duplication, " \
       "EXPECT_PROCESSES=n to wait for n Sidekiq processes)"
  task :load_test, [:account_id] => :environment do |_t, args|
    abort "No contacts. Run: rake crm:seed[100000,contact]" unless Contact.exists?

    filters = if ENV["RECORDS"].present?
                { "ids" => Contact.order(:id).limit(ENV["RECORDS"].to_i).pluck(:id) }
              else
                { "all" => true }
              end
    count = filters["ids"]&.size || Contact.count

    expected = ENV.fetch("EXPECT_PROCESSES", 1).to_i
    deadline = Time.current + 60
    processes = Sidekiq::ProcessSet.new.to_a
    until processes.size >= expected
      abort "Expected #{expected} Sidekiq process(es), found #{processes.size}" if Time.current > deadline
      sleep 1
      processes = Sidekiq::ProcessSet.new.to_a
    end

    threads = processes.sum { |p| p["concurrency"].to_i }
    puts "Workers: #{processes.size} Sidekiq process(es), #{threads} threads | " \
         "batch size #{BulkActions::Config.batch_size} | rate limit #{BulkActions::Config.rate_limit_per_minute}/min"

    bulk_action = BulkActions::Creator.call(
      "account_id" => args[:account_id] || "load_test_#{Time.now.to_i}",
      "entity_type" => "contact",
      "action_type" => "bulk_update",
      "dedupe" => ENV["DEDUPE"] == "1",
      "filters" => filters,
      "payload" => { "fields" => { "age" => rand(18..70), "status" => Contact::STATUSES.sample } }
    )
    puts "Bulk action ##{bulk_action.id} on #{count} contacts"

    started = Time.current
    loop do
      sleep 0.5
      bulk_action.reload
      print "\r#{bulk_action.status.ljust(12)} #{bulk_action.processed_count}/#{bulk_action.total_count}"
      break if bulk_action.finished?
      abort "\nTimed out" if Time.current - started > 1800
    end

    seconds = bulk_action.completed_at - bulk_action.started_at
    per_minute = (bulk_action.processed_count / seconds * 60).round
    puts "\n#{bulk_action.stats.slice(:success, :failed, :skipped)}"
    puts format("Processed %d records in %.2fs => %d records/minute", bulk_action.processed_count, seconds, per_minute)
    puts "RESULT processes=#{processes.size} threads=#{threads} records=#{bulk_action.processed_count} " \
         "seconds=#{seconds.round(2)} per_minute=#{per_minute} bulk_action_id=#{bulk_action.id}"
  end
end
