namespace :bulk do
  desc "End-to-end throughput test. Requires Sidekiq running. Usage: rake bulk:load_test[account_id]"
  task :load_test, [:account_id] => :environment do |_t, args|
    count = Contact.count
    abort "No contacts. Run: rake contacts:seed[20000]" if count.zero?

    bulk_action = BulkActions::Creator.call(
      "account_id" => args[:account_id] || "load_test_#{Time.now.to_i}",
      "entity_type" => "contact",
      "action_type" => "bulk_update",
      "dedupe" => true,
      "filters" => { "all" => true },
      "payload" => { "fields" => { "age" => rand(18..70) } }
    )
    puts "Bulk action ##{bulk_action.id} on #{count} contacts (batch size #{BulkActions::Config.batch_size})"

    started = Time.current
    loop do
      sleep 1
      bulk_action.reload
      print "\r#{bulk_action.status.ljust(12)} #{bulk_action.processed_count}/#{bulk_action.total_count}"
      break if bulk_action.finished?
      abort "\nTimed out" if Time.current - started > 600
    end

    seconds = bulk_action.completed_at - bulk_action.started_at
    puts "\n#{bulk_action.stats.slice(:success, :failed, :skipped)}"
    puts format("Processed %d records in %.2fs => %d records/minute", bulk_action.processed_count, seconds,
                (bulk_action.processed_count / seconds * 60).round)
  end
end
