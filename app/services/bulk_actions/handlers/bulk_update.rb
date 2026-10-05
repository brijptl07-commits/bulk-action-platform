module BulkActions
  module Handlers
    # payload: { "fields" => { "status" => "customer", "age" => 30 } }
    #
    # Each record is validated in memory (so per-record errors are logged), then all valid
    # records in the batch are written with a single UPDATE ... WHERE id IN (...).
    class BulkUpdate < Base
      def self.validate_payload!(entity, payload)
        fields = payload.is_a?(Hash) ? payload["fields"] : nil
        raise InvalidRequest, "payload.fields must be a non-empty object" unless fields.is_a?(Hash) && fields.any?

        unknown = fields.keys.map(&:to_s) - entity.updatable_fields
        return if unknown.empty?

        raise InvalidRequest, "Fields not updatable for #{entity.name}: #{unknown.join(', ')}. " \
                              "Allowed: #{entity.updatable_fields.join(', ')}"
      end

      def call(records)
        fields = payload["fields"].stringify_keys
        results = []
        valid = []

        records.each do |record|
          record.assign_attributes(fields)
          if !record.changed?
            results << skipped(record, "No changes")
          elsif record.valid?
            valid << record
          else
            results << failure(record, record.errors.full_messages.to_sentence)
          end
        end

        if valid.any?
          casted = valid.first.attributes.slice(*fields.keys)
          entity.model.where(id: valid.map(&:id)).update_all(casted.merge("updated_at" => Time.current))
          valid.each { |record| results << success(record) }
        end

        results
      end
    end
  end
end
