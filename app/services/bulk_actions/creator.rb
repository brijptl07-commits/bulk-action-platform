module BulkActions
  # Validates a request, persists the BulkAction and enqueues it (now, or at `scheduled_at`).
  class Creator
    def self.call(params)
      new(params).call
    end

    def initialize(params)
      @params = params.to_h.deep_stringify_keys
    end

    def call
      entity = EntityRegistry.fetch(@params["entity_type"])
      handler = ActionRegistry.fetch(@params["action_type"])
      payload = @params["payload"] || {}
      filters = @params["filters"] || {}

      errors = []
      errors << "account_id is required" if @params["account_id"].blank?
      raise InvalidRequest, errors if errors.any?

      ScopeBuilder.validate!(entity, filters)
      handler.validate_payload!(entity, payload)
      scheduled_at = parse_time(@params["scheduled_at"])

      bulk_action = BulkAction.create!(
        account_id: @params["account_id"],
        entity_type: entity.name,
        action_type: @params["action_type"].to_s,
        payload: payload,
        filters: filters,
        dedupe: ActiveModel::Type::Boolean.new.cast(@params["dedupe"]) || false,
        scheduled_at: scheduled_at,
        status: scheduled_at ? "scheduled" : "queued"
      )

      if scheduled_at
        PlanJob.perform_at(scheduled_at, bulk_action.id)
      else
        PlanJob.perform_async(bulk_action.id)
      end

      bulk_action
    end

    private

    def parse_time(value)
      return nil if value.blank?

      time = Time.zone.parse(value.to_s)
      raise InvalidRequest, "scheduled_at is not a valid time" unless time

      time > Time.current ? time : nil
    rescue ArgumentError
      raise InvalidRequest, "scheduled_at is not a valid time"
    end
  end
end
