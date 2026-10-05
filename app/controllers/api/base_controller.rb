module Api
  class BaseController < ActionController::API
    rescue_from BulkActions::InvalidRequest do |e|
      render json: { errors: e.errors }, status: :unprocessable_entity
    end

    rescue_from ActiveRecord::RecordNotFound do |e|
      render json: { errors: [e.message] }, status: :not_found
    end

    rescue_from ActionController::ParameterMissing do |e|
      render json: { errors: [e.message] }, status: :bad_request
    end

    private

    def page
      [params.fetch(:page, 1).to_i, 1].max
    end

    def per_page
      params.fetch(:per_page, 25).to_i.clamp(1, 500)
    end

    def pagination(relation)
      { page: relation.current_page, per_page: relation.limit_value, total_count: relation.total_count, total_pages: relation.total_pages }
    end
  end
end
