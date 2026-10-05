module Api
  class EntitiesController < BaseController
    # GET /entities — lists registered entities and actions (what the platform can do)
    def index
      render json: {
        data: {
          entities: BulkActions::EntityRegistry.all,
          actions: BulkActions::ActionRegistry.names
        }
      }
    end
  end
end
