module BulkActions
  # Declares which models bulk actions can target. Adding a new entity is a single `register` call.
  module EntityRegistry
    Entity = Struct.new(:name, :model_name, :updatable_fields, :filterable_fields, :dedupe_field, keyword_init: true) do
      def model
        model_name.constantize
      end
    end

    @entities = {}

    class << self
      def register(name, model:, updatable_fields:, filterable_fields: [], dedupe_field: nil)
        @entities[name.to_s] = Entity.new(
          name: name.to_s,
          model_name: model.to_s,
          updatable_fields: updatable_fields.map(&:to_s),
          filterable_fields: filterable_fields.map(&:to_s),
          dedupe_field: dedupe_field&.to_s
        )
      end

      def fetch(name)
        @entities.fetch(name.to_s) { raise InvalidRequest, "Unknown entity_type '#{name}'. Allowed: #{names.join(', ')}" }
      end

      def names
        @entities.keys
      end

      def all
        @entities.values
      end
    end
  end
end
