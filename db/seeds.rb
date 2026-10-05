if Contact.none?
  Rake::Task["contacts:seed"].invoke(ENV.fetch("SEED_COUNT", 5_000))
else
  puts "Contacts already present (#{Contact.count}), skipping seed."
end
