module Api
  class BaseController < ActionController::API
    # Must stay first: rescue_from handlers declared later take precedence.
    rescue_from StandardError do |e|
      Rails.logger.error("#{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
      message = Rails.env.production? ? "Internal server error" : "#{e.class}: #{e.message}"
      render json: { errors: [message] }, status: :internal_server_error
    end

    rescue_from ActionDispatch::Http::Parameters::ParseError do |e|
      render json: { errors: ["Malformed JSON body: #{e.message}"] }, status: :bad_request
    end

    rescue_from BulkActions::InvalidRequest do |e|
      render json: { errors: e.errors }, status: :unprocessable_entity
    end

    rescue_from ActiveRecord::RecordNotFound do |e|
      render json: { errors: [e.message] }, status: :not_found
    end

    rescue_from ActionController::ParameterMissing do |e|
      render json: { errors: [e.message] }, status: :bad_request
    end

    def route_not_found
      render json: { errors: ["No route matches #{request.request_method} #{request.path}"] }, status: :not_found
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
