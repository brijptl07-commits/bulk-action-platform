require "test_helper"

class BulkActions::PlanJobTest < ActiveSupport::TestCase
  def batch_args
    BulkActions::BatchJob.jobs.map { |job| job["args"].drop(1) }
  end

  test "splits the target records into batches and records the exact total" do
    contacts = create_contacts(5)
    create_contacts(2, status: "customer")
    action = create_action(fields: { "age" => 50 }, filters: { "where" => { "status" => "lead" } }, status: "queued")

    with_env("BULK_BATCH_SIZE" => 2) { BulkActions::PlanJob.new.perform(action.id) }

    ids = contacts.map(&:id)
    assert_equal [[ids[0..1], []], [ids[2..3], []], [ids[4..4], []]], batch_args
    action.reload
    assert_equal "in_progress", action.status
    assert_equal 5, action.total_count
    assert action.planned_at
  end

  test "with dedupe, later records with the same email are sent as duplicates" do
    first = Contact.create!(name: "A", email: "a@example.com", status: "lead")
    second = Contact.create!(name: "B", email: "b@example.com", status: "lead")
    copy = Contact.create!(name: "A2", email: "A@Example.com", status: "lead")
    action = create_action(fields: { "age" => 50 }, status: "queued", dedupe: true)

    BulkActions::PlanJob.new.perform(action.id)

    assert_equal [[[first.id, second.id], [copy.id]]], batch_args
  end

  test "enqueues every batch up front; batches over the rate limit move to the next minute" do
    create_contacts(6)
    action = create_action(fields: { "age" => 50 }, status: "queued")

    with_env("RATE_LIMIT_PER_MINUTE" => 4, "BULK_BATCH_SIZE" => 2) do
      BulkActions::PlanJob.new.perform(action.id)
      assert_equal 3, BulkActions::BatchJob.jobs.size

      BulkActions::BatchJob.jobs.dup.each do |job|
        BulkActions::BatchJob.jobs.delete(job)
        BulkActions::BatchJob.new.perform(*job["args"])
      end
    end

    assert_equal 4, action.reload.processed_count, "two batches fit in this minute"
    rescheduled = BulkActions::BatchJob.jobs.sole
    assert rescheduled["at"] > Time.current.to_f, "the third waits for the next minute"
  end

  test "a planner that died part-way is resumed from the start" do
    create_contacts(3)
    action = create_action(fields: { "age" => 50 }, status: "in_progress", planned_at: nil, total_count: 3)

    BulkActions::PlanJob.new.perform(action.id)

    assert_equal 1, BulkActions::BatchJob.jobs.size
    assert action.reload.planned_at
    assert_equal 3, action.total_count
  end

  test "does nothing while another planner holds the lease, or once planning finished" do
    create_contacts(2)
    action = create_action(fields: { "age" => 50 }, status: "in_progress", planned_at: nil)
    lease = BulkActions::RedisLease.acquire(BulkActions::PlanJob.lease_key(action.id), ttl: 60)

    BulkActions::PlanJob.new.perform(action.id)
    assert_empty BulkActions::BatchJob.jobs

    lease.release!
    action.update!(planned_at: Time.current)
    BulkActions::PlanJob.new.perform(action.id)
    assert_empty BulkActions::BatchJob.jobs
  end

  test "a cancelled action is not planned" do
    create_contacts(2)
    action = create_action(fields: { "age" => 50 }, status: "cancelled")

    BulkActions::PlanJob.new.perform(action.id)

    assert_empty BulkActions::BatchJob.jobs
  end
end
