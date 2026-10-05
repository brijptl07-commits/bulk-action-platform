namespace :crm do
  FIRST = %w[Aarav Vivaan Aditya Diya Ananya Riya Kabir Isha Arjun Meera John Jane Alex Sara Liam Emma].freeze
  LAST = %w[Shah Patel Mehta Desai Sharma Gupta Singh Rao Smith Brown Wilson Taylor].freeze
  WORDS = %w[Global Prime Blue Apex Nova Swift Bright Peak Urban Green Iron Silver].freeze

  # Every 20th row reuses an earlier unique value so de-duplication has something to catch.
  def self.dup_n(n)
    (n % 20 == 19 && n > 20) ? n - 10 : n
  end

  GENERATORS = {
    "contact" => lambda { |n|
      { name: "#{FIRST.sample} #{LAST.sample}", email: "contact#{dup_n(n)}@example.com", age: rand(18..70),
        status: Contact::STATUSES.sample }
    },
    "company" => lambda { |n|
      { name: "#{WORDS.sample} #{WORDS.sample} #{%w[Ltd Inc LLP Corp].sample}", domain: "company#{dup_n(n)}.com",
        industry: Company::INDUSTRIES.sample, employee_count: rand(5..5000), status: Company::STATUSES.sample }
    },
    "lead" => lambda { |n|
      { name: "#{FIRST.sample} #{LAST.sample}", email: "lead#{dup_n(n)}@example.com",
        company_name: "#{WORDS.sample} #{%w[Ltd Inc].sample}", source: Lead::SOURCES.sample, score: rand(0..100),
        status: Lead::STATUSES.sample }
    },
    "opportunity" => lambda { |n|
      @company_ids ||= Company.pluck(:id)
      { name: "Deal ##{n} - #{WORDS.sample}", company_id: @company_ids.sample, amount: rand(1_000..500_000),
        stage: Opportunity::STAGES.sample,
        probability: rand(0..100), close_date: Date.current + rand(-30..120) }
    },
    "task" => lambda { |n|
      { title: "#{%w[Call Email Follow-up Demo Review].sample} ##{n}", description: "Auto-generated task #{n}",
        status: Task::STATUSES.sample, priority: Task::PRIORITIES.sample, due_date: Date.current + rand(-10..30),
        assignee: FIRST.sample.downcase }
    }
  }.freeze

  desc "Seed fake records. Usage: rake crm:seed[COUNT] (all entities) or rake crm:seed[COUNT,lead]"
  task :seed, %i[count entity] => :environment do |_t, args|
    count = (args[:count] || 2_000).to_i
    names = args[:entity].present? ? [args[:entity]] : GENERATORS.keys

    names.each do |name|
      entity = BulkActions::EntityRegistry.fetch(name)
      generator = GENERATORS.fetch(name)
      offset = entity.model.maximum(:id).to_i
      now = Time.current

      count.times.each_slice(5_000) do |slice|
        entity.model.insert_all(slice.map { |i| generator.call(offset + i).merge(created_at: now, updated_at: now) })
      end
      puts "#{entity.label}: inserted #{count}, total #{entity.model.count}"
    end
  end
end
