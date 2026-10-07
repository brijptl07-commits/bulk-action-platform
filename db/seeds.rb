# Tops every entity up to a target count (re-running never duplicates work).
# SEED_COUNT sets the default; SEED_<ENTITY>_COUNT overrides one entity, e.g. SEED_CONTACT_COUNT=100000.
default_count = ENV.fetch("SEED_COUNT", 2_000).to_i

BulkActions::EntityRegistry.all.each do |entity|
  target = ENV.fetch("SEED_#{entity.name.upcase}_COUNT", default_count).to_i
  missing = target - entity.model.count

  if missing.positive?
    Rake::Task["crm:seed"].reenable
    Rake::Task["crm:seed"].invoke(missing, entity.name)
  else
    puts "#{entity.label}: #{entity.model.count} records (target #{target}), skipping"
  end
end
