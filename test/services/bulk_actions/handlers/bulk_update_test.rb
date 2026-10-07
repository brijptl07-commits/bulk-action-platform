require "test_helper"

class BulkActions::Handlers::BulkUpdateTest < ActiveSupport::TestCase
  Handler = BulkActions::Handlers::BulkUpdate

  def contact_entity
    BulkActions::EntityRegistry.fetch("contact")
  end

  def call_handler(action, records)
    ActiveRecord::Base.transaction { Handler.new(action, contact_entity).call(records) }
  end

  test "payload must name at least one updatable field" do
    assert_raises(BulkActions::InvalidRequest) { Handler.validate_payload!(contact_entity, { "fields" => {} }) }
    assert_raises(BulkActions::InvalidRequest) { Handler.validate_payload!(contact_entity, {}) }

    error = assert_raises(BulkActions::InvalidRequest) do
      Handler.validate_payload!(contact_entity, { "fields" => { "salary" => 1 } })
    end
    assert_match "salary", error.message
    assert_nil Handler.validate_payload!(contact_entity, { "fields" => { "status" => "customer" } })
  end

  test "updates records and skips the ones that already have the value" do
    lead, other = create_contacts(2)
    customer = create_contacts(1, status: "customer").first
    action = create_action(fields: { "status" => "customer" })

    results = call_handler(action, [lead, other, customer]).index_by(&:entity_id)

    assert_equal "success", results[lead.id].status
    assert_equal "success", results[other.id].status
    assert_equal ["skipped", "No changes"], results[customer.id].to_a.last(2)
    assert_equal %w[customer customer customer], Contact.order(:id).pluck(:status)
  end

  test "logs a validation failure per record and leaves it unchanged" do
    contacts = create_contacts(2)
    action = create_action(fields: { "age" => 200 })

    results = call_handler(action, contacts)

    assert_equal %w[failed failed], results.map(&:status)
    assert_match "Age must be less than 150", results.first.message
    assert_equal [30, 30], Contact.order(:id).pluck(:age)
  end

  test "a newer action keeps its fields even when an older one runs after it" do
    contact = create_contacts(1).first
    older = create_action(fields: { "name" => "Older", "age" => 41 })
    newer = create_action(fields: { "name" => "Newer" })

    call_handler(newer, [contact.reload])
    result = call_handler(older, [contact.reload]).first

    assert_equal "success", result.status
    assert_equal "name superseded by ##{newer.id}", result.message
    contact.reload
    assert_equal "Newer", contact.name
    assert_equal 41, contact.age
  end

  test "an older action is skipped entirely when every field belongs to a newer one" do
    contact = create_contacts(1).first
    older = create_action(fields: { "name" => "Older" })
    newer = create_action(fields: { "name" => "Newer" })

    call_handler(newer, [contact.reload])
    result = call_handler(older, [contact.reload]).first

    assert_equal ["skipped", "Superseded by newer bulk action ##{newer.id}"], result.to_a.last(2)
    assert_equal "Newer", contact.reload.name
  end

  test "a newer action that runs last simply overwrites the older one" do
    contact = create_contacts(1).first
    older = create_action(fields: { "name" => "Older" })
    newer = create_action(fields: { "name" => "Newer" })

    call_handler(older, [contact.reload])
    call_handler(newer, [contact.reload])

    assert_equal "Newer", contact.reload.name
  end
end
