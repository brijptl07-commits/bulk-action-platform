module BulkActions
  module Handlers
    # payload: { "fields" => { "status" => "customer", "age" => 30 } }
    #
    # Each record is validated in memory (so per-record errors are logged), then valid records are
    # written with one UPDATE ... WHERE id IN (...) per distinct set of applicable fields (normally one).
    # FieldVersionGuard makes sure a field already written by a newer bulk action is never overwritten.
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
        guard = FieldVersionGuard.new(bulk_action, entity)

        guard.track(records, fields.keys) do
          results = []
          groups = Hash.new { |h, k| h[k] = [] }
          notes = {}

          records.each do |record|
            allowed, superseded_by = guard.partition(record.id, fields.keys)
            if allowed.empty?
              results << skipped(record, "Superseded by newer bulk action #{superseded_by.map { |id| "##{id}" }.join(', ')}")
              next
            end
            notes[record.id] = "#{(fields.keys - allowed).join(', ')} superseded by #{superseded_by.map { |id| "##{id}" }.join(', ')}" if superseded_by.any?

            record.assign_attributes(fields.slice(*allowed))
            if !record.changed?
              guard.touch(record.id, allowed)
              results << skipped(record, ["No changes", notes[record.id]].compact.join("; "))
            elsif record.valid?
              groups[allowed] << record
            else
              results << failure(record, record.errors.full_messages.to_sentence)
            end
          end

          groups.each do |allowed, valid|
            casted = valid.first.attributes.slice(*allowed)
            entity.model.where(id: valid.map(&:id)).update_all(casted.merge("updated_at" => Time.current))
            valid.each do |record|
              guard.touch(record.id, allowed)
              results << success(record, notes[record.id])
            end
          end

          results
        end
      end
    end
  end
end
