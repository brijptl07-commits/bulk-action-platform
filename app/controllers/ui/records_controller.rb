module Ui
  class RecordsController < ApplicationController
    def index
      @entity = BulkActions::EntityRegistry.fetch(params[:entity_type])
      @filters = @entity.filterable_fields.select { |f| @entity.field(f)&.dig("type") == "select" }
      scope = @entity.model.order(:id)
      @filters.each { |f| scope = scope.where(f => params[f]) if params[f].present? }
      scope = scope.where(id: params[:id]) if params[:id].present?
      @records = scope.page(params[:page]).per(50)
      @columns = @entity.fields.reject { |_name, spec| spec["type"] == "text" }.keys
    rescue BulkActions::InvalidRequest => e
      redirect_to root_path, alert: e.message
    end
  end
end
