require "csv"

namespace :contacts do
  desc "Import contacts from CSV with headers name,email,age,status. Usage: rake contacts:import[path/to/file.csv]"
  task :import, [:path] => :environment do |_t, args|
    path = args[:path] || Rails.root.join("db/sample_contacts.csv")
    now = Time.current
    total = 0

    CSV.foreach(path, headers: true).each_slice(5_000) do |rows|
      Contact.insert_all(rows.map do |r|
        {
          name: r["name"],
          email: r["email"],
          age: r["age"].presence&.to_i,
          status: r["status"].presence || "lead",
          created_at: now,
          updated_at: now
        }
      end)
      total += rows.size
    end
    puts "Imported #{total} contacts from #{path}"
  end
end
