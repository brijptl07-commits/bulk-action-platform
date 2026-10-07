require "test_helper"

class BulkActions::RecoveryJobTest < ActiveSupport::TestCase
  test "re-sends only the records whose batch was lost" do
    contacts = create_contacts(4)
    action = create_action(fields: { "status" => "customer" }, total_count: 4, planned_at: Time.current)
    BulkActions::BatchJob.new.perform(action.id, contacts.first(2).map(&:id), [])
    action.update_columns(updated_at: 20.minutes.ago)

    report = BulkActions::Recovery.call

    assert_equal 2, report[:records_resent]
    assert_equal [action.id, contacts.last(2).map(&:id), []], BulkActions::BatchJob.jobs.sole["args"]

    BulkActions::BatchJob.drain
    assert_equal "completed", action.reload.status
    assert_equal 4, action.processed_count
  end

  test "re-sent batches keep their duplicate decisions" do
    first = Contact.create!(name: "A", email: "a@example.com", status: "lead")
    copy = Contact.create!(name: "A2", email: "a@example.com", status: "lead")
    action = create_action(fields: { "status" => "customer" }, dedupe: true, total_count: 2,
                           planned_at: Time.current, updated_at: 20.minutes.ago)

    BulkActions::Recovery.call

    assert_equal [action.id, [first.id], [copy.id]], BulkActions::BatchJob.jobs.sole["args"]
  end

  test "completes an action whose records were all processed" do
    contacts = create_contacts(2)
    action = create_action(fields: { "status" => "customer" }, total_count: 2, planned_at: nil)
    BulkActions::BatchJob.new.perform(action.id, contacts.map(&:id), [])
    action.update_columns(planned_at: Time.current)

    assert_equal 1, BulkActions::Recovery.call[:completed]
    assert_equal "completed", action.reload.status
  end

  test "restarts a planner that died, and lost scheduled or queued plans" do
    create_contacts(2)
    dead = create_action(fields: { "age" => 50 }, planned_at: nil, updated_at: 5.minutes.ago)
    scheduled = create_action(fields: { "age" => 51 }, status: "scheduled", scheduled_at: 5.minutes.ago)
    queued = create_action(fields: { "age" => 52 }, status: "queued", created_at: 1.hour.ago)

    report = BulkActions::Recovery.call

    assert_equal({ plans_restarted: 2, planners_resumed: 1 }, report.to_h)
    assert_equal [dead.id, scheduled.id, queued.id].sort, BulkActions::PlanJob.jobs.map { |job| job["args"].first }.sort

    run_jobs
    assert_equal %w[completed] * 3, [dead, scheduled, queued].map { |a| a.reload.status }
  end

  test "leaves healthy actions alone" do
    create_contacts(2)
    create_action(fields: { "age" => 50 }, total_count: 2, planned_at: Time.current)
    planning = create_action(fields: { "age" => 51 }, planned_at: nil, updated_at: 5.minutes.ago)
    BulkActions::RedisLease.acquire(BulkActions::PlanJob.lease_key(planning.id), ttl: 60)
    create_action(fields: { "age" => 52 }, status: "scheduled", scheduled_at: 1.hour.from_now)
    create_action(fields: { "age" => 53 }, status: "queued")

    assert_empty BulkActions::Recovery.call
    assert_empty BulkActions::PlanJob.jobs
    assert_empty BulkActions::BatchJob.jobs
  end

  test "only one recovery chain stays scheduled" do
    BulkActions::RecoveryJob.ensure_scheduled
    BulkActions::RecoveryJob.ensure_scheduled
    assert_equal 1, BulkActions::RecoveryJob.jobs.size

    job = BulkActions::RecoveryJob.jobs.shift
    BulkActions::RecoveryJob.new.tap { |j| j.jid = job["jid"] }.perform
    BulkActions::RecoveryJob.new.tap { |j| j.jid = "overlapping" }.perform

    next_run = BulkActions::RecoveryJob.jobs.sole
    assert next_run["at"] > Time.current.to_f
  end
end
