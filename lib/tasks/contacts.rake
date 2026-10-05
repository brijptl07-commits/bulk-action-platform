require "csv"

namespace :contacts do
  desc "Generate fake contacts (~5% duplicate emails). Usage: rake contacts:seed[10000]"
  task :seed, [:count] => :environment do |_t, args|
    count = (args[:count] || 5_000).to_i
    first = %w[Aarav Vivaan Aditya Diya Ananya Riya Kabir Isha Arjun Meera John Jane Alex Sara Liam Emma]
    last = %w[Shah Patel Mehta Desai Sharma Gupta Singh Rao Smith Brown Wilson Taylor]
    now = Time.current
    offset = Contact.maximum(:id).to_i

    count.times.each_slice(5_000) do |slice|
      rows = slice.map do |i|
        n = offset + i
        # Every 20th contact reuses an earlier email to exercise de-duplication.
        email_n = (n % 20 == 19 && n > 20) ? n - 10 : n
        {
          name: "#{first.sample} #{last.sample}",
          email: "contact#{email_n}@example.com",
          age: rand(18..70),
          status: Contact::STATUSES.sample,
          created_at: now,
          updated_at: now
        }
      end
      Contact.insert_all(rows)
      print "."
    end
    puts "\nInserted #{count} contacts. Total: #{Contact.count}"
  end

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
