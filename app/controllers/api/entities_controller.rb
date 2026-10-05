module Api
  class EntitiesController < BaseController
    # GET /entities — lists registered entities and actions (what the platform can do)
    def index
      render json: {
        data: {
          entities: BulkActions::EntityRegistry.all.map(&:to_h).map { |e| e.except(:model_name) },
          actions: BulkActions::ActionRegistry.names
        }
      }
    end
  end
end
