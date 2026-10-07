require "test_helper"

class BulkActions::CreatorTest < ActiveSupport::TestCase
  def params(**overrides)
    { account_id: "acc_1", entity_type: "contact", action_type: "bulk_update",
      payload: { fields: { status: "customer" } }, filters: { where: { status: "lead" } } }.merge(overrides)
  end

  test "creates a queued action and enqueues its plan" do
    action = BulkActions::Creator.call(params)

    assert_equal "queued", action.status
    assert_equal [[action.id]], BulkActions::PlanJob.jobs.map { |job| job["args"] }
  end

  test "a future scheduled_at creates a scheduled action that plans at that time" do
    at = 1.hour.from_now.change(usec: 0)
    action = BulkActions::Creator.call(params(scheduled_at: at.iso8601))

    assert_equal "scheduled", action.status
    assert_equal at.to_f, BulkActions::PlanJob.jobs.first["at"]
  end

  test "makes sure the recovery job is scheduled" do
    BulkActions::Creator.call(params)
    BulkActions::Creator.call(params)

    assert_equal 1, BulkActions::RecoveryJob.jobs.size
  end

  test "rejects invalid requests" do
    invalid = [
      params(account_id: ""),
      params(entity_type: "invoice"),
      params(action_type: "bulk_delete"),
      params(payload: { fields: { salary: 1 } }),
      params(filters: {}),
      params(filters: { where: { name: "x" } }),
      params(entity_type: "opportunity", payload: { fields: { stage: "won" } }, filters: { all: true }, dedupe: true),
      params(scheduled_at: "not a time")
    ]

    invalid.each do |request|
      assert_raises(BulkActions::InvalidRequest, request.inspect) { BulkActions::Creator.call(request) }
    end
    assert_equal 0, BulkAction.count
  end
end
