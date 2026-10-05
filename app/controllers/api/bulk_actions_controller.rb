module Api
  class BulkActionsController < BaseController
    # GET /bulk-actions?status=in_progress&account_id=acc_1&page=1&per_page=25
    def index
      scope = BulkAction.recent
      scope = scope.where(status: params[:status].to_s.split(",")) if params[:status].present?
      scope = scope.where(account_id: params[:account_id]) if params[:account_id].present?
      scope = scope.where(entity_type: params[:entity_type]) if params[:entity_type].present?
      scope = scope.page(page).per(per_page)

      render json: { data: scope, meta: pagination(scope) }
    end

    # POST /bulk-actions
    def create
      bulk_action = BulkActions::Creator.call(create_params)
      render json: { data: bulk_action }, status: :created
    end

    # GET /bulk-actions/:id
    def show
      render json: { data: bulk_action }
    end

    # GET /bulk-actions/:id/stats
    def stats
      render json: { data: bulk_action.stats }
    end

    # GET /bulk-actions/:id/logs?status=failed&entity_id=42&page=1&per_page=50
    def logs
      scope = bulk_action.logs.order(:id)
      scope = scope.where(status: params[:status].to_s.split(",")) if params[:status].present?
      scope = scope.where(entity_id: params[:entity_id]) if params[:entity_id].present?
      scope = scope.page(page).per(per_page)

      render json: { data: scope, meta: pagination(scope) }
    end

    # POST /bulk-actions/:id/cancel
    def cancel
      if bulk_action.transition!(from: BulkAction::ACTIVE_STATUSES, to: "cancelled", completed_at: Time.current)
        render json: { data: bulk_action }
      else
        render json: { errors: ["Bulk action is already #{bulk_action.status}"] }, status: :unprocessable_entity
      end
    end

    private

    def bulk_action
      @bulk_action ||= BulkAction.find(params[:id])
    end

    def create_params
      source = params[:bulk_action].presence || params
      source.permit(:account_id, :entity_type, :action_type, :dedupe, :scheduled_at,
                    payload: {}, filters: {}).to_h
    end
  end
end
