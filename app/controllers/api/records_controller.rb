module Api
  class RecordsController < BaseController
    # GET /entities/:entity_type/records?status=lead&page=1&per_page=25
    # Any filterable field of the entity can be passed as a query param.
    def index
      entity = BulkActions::EntityRegistry.fetch(params[:entity_type])
      scope = entity.model.order(:id)
      entity.filterable_fields.each do |field|
        scope = scope.where(field => params[field].to_s.split(",")) if params[field].present?
      end
      scope = scope.page(page).per(per_page)

      render json: {
        data: scope.as_json(only: ["id", *entity.fields.keys, "updated_at"]),
        meta: pagination(scope)
      }
    end
  end
end
