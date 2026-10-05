module BulkActions
  # Turns the `filters` of a bulk action into an ActiveRecord relation.
  #
  # Supported filters (at least one is required, so nothing runs on a whole table by accident):
  #   { "ids" => [1, 2, 3] }
  #   { "where" => { "status" => "lead", "age" => [25, 30] } }   # equality / IN on filterable fields
  #   { "all" => true }
  class ScopeBuilder
    def self.validate!(entity, filters)
      new(entity, filters).validate!
    end

    def initialize(entity, filters)
      @entity = entity
      @filters = (filters || {}).to_h.stringify_keys
    end

    def validate!
      errors = []
      ids, where, all = @filters.values_at("ids", "where", "all")

      errors << "filters must include one of: ids, where, all" if ids.blank? && where.blank? && all != true
      errors << "filters.ids must be an array" if ids.present? && !ids.is_a?(Array)
      if where.present?
        if where.is_a?(Hash)
          unknown = where.keys.map(&:to_s) - @entity.filterable_fields
          errors << "Unknown filter fields: #{unknown.join(', ')}. Allowed: #{@entity.filterable_fields.join(', ')}" if unknown.any?
        else
          errors << "filters.where must be an object"
        end
      end

      raise InvalidRequest, errors if errors.any?

      true
    end

    def relation
      scope = @entity.model.all
      scope = scope.where(id: @filters["ids"]) if @filters["ids"].present?
      scope = scope.where(@filters["where"].slice(*@entity.filterable_fields)) if @filters["where"].present?
      scope
    end
  end
end
