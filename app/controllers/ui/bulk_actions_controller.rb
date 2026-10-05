module Ui
  class BulkActionsController < ApplicationController
    def index
      @status = params[:status].presence
      scope = BulkAction.recent
      scope = scope.where(status: @status == "active" ? BulkAction::ACTIVE_STATUSES : @status) if @status
      @bulk_actions = scope.page(params[:page]).per(20)
      @auto_refresh = @bulk_actions.any? { |a| !a.finished? }
    end

    def new
      @entity = selected_entity(params[:entity_type])
      @form = default_form(@entity)
    end

    def create
      @form = form_params
      @entity = selected_entity(@form["entity_type"])
      bulk_action = BulkActions::Creator.call(build_request(@form))
      redirect_to ui_bulk_action_path(bulk_action), notice: "Bulk action ##{bulk_action.id} created (#{bulk_action.status})."
    rescue BulkActions::InvalidRequest => e
      @errors = e.errors
      render :new, status: :unprocessable_entity
    end

    def show
      @bulk_action = BulkAction.find(params[:id])
      @log_status = params[:log_status].presence
      logs = @bulk_action.logs.order(:id)
      logs = logs.where(status: @log_status) if @log_status
      logs = logs.where(entity_id: params[:entity_id]) if params[:entity_id].present?
      @logs = logs.page(params[:page]).per(50)
      @auto_refresh = !@bulk_action.finished?
    end

    def cancel
      bulk_action = BulkAction.find(params[:id])
      if bulk_action.transition!(from: BulkAction::ACTIVE_STATUSES, to: "cancelled", completed_at: Time.current)
        redirect_to ui_bulk_action_path(bulk_action), notice: "Bulk action cancelled."
      else
        redirect_to ui_bulk_action_path(bulk_action), alert: "Bulk action is already #{bulk_action.status}."
      end
    end

    private

    def selected_entity(name)
      BulkActions::EntityRegistry.fetch(name.presence || BulkActions::EntityRegistry.names.first)
    rescue BulkActions::InvalidRequest
      BulkActions::EntityRegistry.all.first
    end

    def default_form(entity)
      { "account_id" => "acc_1", "entity_type" => entity.name, "action_type" => "bulk_update",
        "target" => "where", "where_field" => entity.filterable_fields.first, "fields" => {},
        "dedupe" => entity.dedupe_field ? "1" : "0" }
    end

    def form_params
      params.require(:form).permit(:account_id, :entity_type, :action_type, :target, :where_field, :where_value,
                                   :ids, :dedupe, :scheduled_at, update: {}, fields: {}).to_h
    end

    # Converts the HTML form into the same request shape the JSON API accepts.
    def build_request(form)
      enabled = (form["update"] || {}).select { |_k, v| v == "1" }.keys
      fields = (form["fields"] || {}).slice(*enabled)

      filters = case form["target"]
                when "all" then { "all" => true }
                when "ids" then { "ids" => form["ids"].to_s.split(/[\s,]+/).reject(&:blank?).map(&:to_i) }
                else { "where" => { form["where_field"].to_s => form["where_value"].to_s.split(",").map(&:strip) } }
                end

      scheduled_at = form["scheduled_at"].presence && Time.zone.parse(form["scheduled_at"])&.iso8601

      {
        "account_id" => form["account_id"],
        "entity_type" => form["entity_type"],
        "action_type" => form["action_type"],
        "dedupe" => form["dedupe"] == "1",
        "scheduled_at" => scheduled_at,
        "filters" => filters,
        "payload" => { "fields" => fields }
      }
    end
  end
end
