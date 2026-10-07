require "test_helper"

class BulkActionsApiTest < ActionDispatch::IntegrationTest
  def json
    JSON.parse(response.body)
  end

  test "create, process, then read stats and logs" do
    create_contacts(4)
    create_contacts(1, status: "churned")

    post "/bulk-actions", params: {
      account_id: "acc_1", entity_type: "contact", action_type: "bulk_update",
      payload: { fields: { status: "customer" } }, filters: { where: { status: "lead" } }
    }, as: :json

    assert_response :created
    id = json.dig("data", "id")
    assert_equal "queued", json.dig("data", "status")

    run_jobs

    get "/bulk-actions/#{id}/stats"
    assert_response :ok
    assert_equal({ "status" => "completed", "total" => 4, "processed" => 4, "success" => 4, "failed" => 0 },
                 json["data"].slice("status", "total", "processed", "success", "failed"))

    get "/bulk-actions/#{id}/logs", params: { status: "success", per_page: 2 }
    assert_response :ok
    assert_equal 2, json["data"].size
    assert_equal 4, json.dig("meta", "total_count")
  end

  test "invalid requests return 422 with the reasons" do
    post "/bulk-actions", params: { entity_type: "contact", action_type: "bulk_update",
                                    payload: { fields: { salary: 1 } }, filters: { all: true } }, as: :json

    assert_response :unprocessable_entity
    assert_includes json["errors"].join, "account_id is required"
  end

  test "unknown bulk action returns 404" do
    get "/bulk-actions/0"
    assert_response :not_found
  end
end
