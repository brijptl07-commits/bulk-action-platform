require "test_helper"

class BulkActions::BatchJobTest < ActiveSupport::TestCase
  def planned_action(contacts, fields: { "status" => "customer" })
    create_action(fields: fields, total_count: contacts.size, planned_at: Time.current)
  end

  def perform(action, ids, duplicate_ids = [])
    BulkActions::BatchJob.new.perform(action.id, ids, duplicate_ids)
  end

  test "updates the records, writes one log per record and completes the action" do
    contacts = create_contacts(3)
    action = planned_action(contacts)

    perform(action, contacts.map(&:id))

    action.reload
    assert_equal "completed", action.status
    assert_equal [3, 3, 0, 0], [action.processed_count, action.success_count, action.failure_count, action.skipped_count]
    assert_equal %w[success] * 3, action.logs.pluck(:status)
    assert_equal %w[customer] * 3, Contact.pluck(:status)
  end

  test "missing and duplicate records are logged as skipped" do
    contact, copy = create_contacts(2)
    action = create_action(fields: { "status" => "customer" }, total_count: 3, planned_at: Time.current)

    perform(action, [contact.id, 999_999], [copy.id])

    messages = action.logs.order(:entity_id).pluck(:entity_id, :status, :message)
    assert_equal [[contact.id, "success", nil], [copy.id, "skipped", "Duplicate email"],
                  [999_999, "skipped", "Record not found"]], messages
    assert_equal [3, 1, 2], action.reload.values_at(:processed_count, :success_count, :skipped_count)
    assert_equal "lead", copy.reload.status
  end

  test "running the same batch twice counts and logs each record once" do
    contacts = create_contacts(2)
    action = create_action(fields: { "status" => "customer" }, total_count: 4, planned_at: Time.current)

    2.times { perform(action, contacts.map(&:id)) }

    assert_equal 2, action.reload.processed_count
    assert_equal 2, action.logs.count
  end

  test "concurrent deliveries of the same batch count each record once" do
    contacts = create_contacts(3)
    action = create_action(fields: { "status" => "customer" }, total_count: 4, planned_at: Time.current)
    ids = contacts.map(&:id) + [999_999]

    # Wrapped like Sidekiq runs jobs: inside the Rails executor, with the query cache on.
    Array.new(4) { Thread.new { Rails.application.executor.wrap { perform(action, ids) } } }.each(&:join)

    assert_equal [4, 3, 1], action.reload.values_at(:processed_count, :success_count, :skipped_count)
    assert_equal 4, action.logs.count
  end

  test "a failure part-way rolls back the whole batch, and a retry then succeeds" do
    contacts = create_contacts(2)
    action = planned_action(contacts)

    BulkActionLog.stub(:insert_all, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_raises(ActiveRecord::StatementInvalid) { perform(action, contacts.map(&:id)) }
    end

    assert_equal %w[lead lead], Contact.pluck(:status), "record updates are rolled back"
    assert_equal 0, action.reload.processed_count, "counters are rolled back"
    assert_equal 0, BulkFieldVersion.count, "field versions are rolled back"

    perform(action, contacts.map(&:id))

    assert_equal "completed", action.reload.status
    assert_equal 2, action.logs.count
  end

  test "a deadlock retries the whole batch" do
    contacts = create_contacts(2)
    action = planned_action(contacts)
    calls = 0
    original = BulkActionLog.method(:insert_all)
    deadlock_once = lambda do |*args, **kwargs|
      calls += 1
      raise ActiveRecord::Deadlocked, "deadlock" if calls == 1

      original.call(*args, **kwargs)
    end

    BulkActionLog.stub(:insert_all, deadlock_once) { perform(action, contacts.map(&:id)) }

    assert_equal 2, calls
    assert_equal [2, 2], action.reload.values_at(:processed_count, :success_count)
  end

  test "over the rate limit, the batch is rescheduled instead of processed" do
    contacts = create_contacts(3)
    action = planned_action(contacts)

    with_env("RATE_LIMIT_PER_MINUTE" => 2) { perform(action, contacts.map(&:id)) }

    rescheduled = BulkActions::BatchJob.jobs.sole
    assert_equal [action.id, contacts.map(&:id), []], rescheduled["args"]
    assert rescheduled["at"] > Time.current.to_f
    assert_equal 0, action.logs.count
  end

  test "batches of a cancelled action are ignored" do
    contacts = create_contacts(1)
    action = planned_action(contacts)
    action.update!(status: "cancelled")

    perform(action, contacts.map(&:id))

    assert_equal 0, action.logs.count
    assert_equal "lead", contacts.first.reload.status
  end
end
