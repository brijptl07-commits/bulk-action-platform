count = ENV.fetch("SEED_COUNT", 2_000)

BulkActions::EntityRegistry.all.each do |entity|
  if entity.model.exists?
    puts "#{entity.label}: already seeded (#{entity.model.count}), skipping"
  else
    Rake::Task["crm:seed"].reenable
    Rake::Task["crm:seed"].invoke(count, entity.name)
  end
end
