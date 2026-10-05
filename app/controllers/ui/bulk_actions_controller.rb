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
      @form = default_form
    end

    def create
      @form = form_params
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

    def default_form
      { "account_id" => "acc_1", "entity_type" => "contact", "action_type" => "bulk_update",
        "target" => "where", "where_status" => "lead", "fields" => {}, "dedupe" => "1" }
    end

    def form_params
      params.require(:form).permit(:account_id, :entity_type, :action_type, :target, :where_status, :ids,
                                   :dedupe, :scheduled_at, update: {}, fields: {}).to_h
    end

    # Converts the HTML form into the same request shape the JSON API accepts.
    def build_request(form)
      enabled = (form["update"] || {}).select { |_k, v| v == "1" }.keys
      fields = (form["fields"] || {}).slice(*enabled)

      filters = case form["target"]
                when "all" then { "all" => true }
                when "ids" then { "ids" => form["ids"].to_s.split(/[\s,]+/).reject(&:blank?).map(&:to_i) }
                else { "where" => { "status" => form["where_status"] } }
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
