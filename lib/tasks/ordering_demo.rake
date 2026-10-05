namespace :bulk do
  desc "Shows that an older bulk action never overwrites a newer one, even if its batch runs last"
  task :ordering_demo, [:entity] => :environment do |_t, args|
    entity = BulkActions::EntityRegistry.fetch(args[:entity] || "contact")
    ids = entity.model.order(:id).limit(5).pluck(:id)
    field = entity.updatable_fields.include?("name") ? "name" : entity.updatable_fields.first

    build = lambda do |value|
      BulkAction.create!(
        account_id: "ordering_demo", entity_type: entity.name, action_type: "bulk_update",
        filters: { "ids" => ids }, payload: { "fields" => { field => value } },
        status: "in_progress", started_at: Time.current, planned_at: Time.current,
        total_count: ids.size, sequence: Sequence.next(:bulk_action)
      )
    end

    first = build.call("name1 (older action)")
    second = build.call("name2 (newer action)")
    puts "Action ##{first.id} (seq #{first.sequence}) sets #{field} = 'name1'"
    puts "Action ##{second.id} (seq #{second.sequence}) sets #{field} = 'name2'"
    puts "\nRunning the NEWER action's batch first, then the OLDER one's (out of order)..."

    BulkActions::BatchJob.new.perform(second.id, ids, [])
    BulkActions::BatchJob.new.perform(first.id, ids, [])

    puts "\nFinal values:"
    entity.model.where(id: ids).order(:id).each do |r|
      puts "  ##{r.id}: #{field}=#{r[field].inspect} last_bulk_action_id=#{r.last_bulk_action_id}"
    end
    [second, first].each do |a|
      a.reload
      puts "\nAction ##{a.id}: #{a.status} #{a.stats.slice(:success, :failed, :skipped)}"
      a.logs.group(:status, :message).count.each { |(s, m), c| puts "  #{s} x#{c} #{m}" }
    end
  end
end
