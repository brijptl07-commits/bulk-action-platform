module BulkActions
  # Declares which models bulk actions can target. Adding a new entity is a single `register` call;
  # the API, UI form, record browser, validation and processing all read from here.
  #
  #   register :contact,
  #     model: "Contact",
  #     fields: { name: :string, age: :integer, status: %w[lead customer] },  # Array => allowed options
  #     filterable_fields: %i[status],
  #     dedupe_field: :email
  module EntityRegistry
    Entity = Struct.new(:name, :label, :model_name, :fields, :updatable_fields, :filterable_fields, :dedupe_field,
                        keyword_init: true) do
      def model
        model_name.constantize
      end

      def field(name)
        fields[name.to_s]
      end

      def as_json(_options = {})
        {
          name: name,
          label: label,
          fields: fields,
          updatable_fields: updatable_fields,
          filterable_fields: filterable_fields,
          dedupe_field: dedupe_field
        }
      end
    end

    @entities = {}

    class << self
      def register(name, model:, fields:, label: nil, updatable_fields: nil, filterable_fields: [], dedupe_field: nil)
        normalized = fields.to_h { |field, spec| [field.to_s, normalize_field(spec)] }

        @entities[name.to_s] = Entity.new(
          name: name.to_s,
          label: label || name.to_s.pluralize.humanize,
          model_name: model.to_s,
          fields: normalized,
          updatable_fields: (updatable_fields || normalized.keys).map(&:to_s),
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

      private

      def normalize_field(spec)
        case spec
        when Array then { "type" => "select", "options" => spec.map(&:to_s) }
        when Hash then spec.deep_stringify_keys
        else { "type" => spec.to_s }
        end
      end
    end
  end
end
