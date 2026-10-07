namespace :bulk do
  desc "Run bulk action recovery once (re-plans lost actions, re-sends lost batches, completes finished ones)"
  task recover: :environment do
    report = BulkActions::Recovery.call
    puts report.any? ? report.map { |k, v| "#{k}=#{v}" }.join(" ") : "Nothing to recover"
  end
end
