module BulkActions
  module Handlers
    # payload: { "fields" => { "status" => "customer", "age" => 30 } }
    #
    # Each record is validated in memory (so per-record errors are logged), then all valid
    # records in the batch are written with a single UPDATE ... WHERE id IN (...).
    #
    # Ordering guarantee: every write stamps `last_bulk_action_seq`, and the UPDATE only touches rows
    # whose stamp is not newer than this action's sequence. If two actions target the same record,
    # the later-started one wins even when the older one's batch runs afterwards; the older one logs
    # those records as skipped (superseded).
    class BulkUpdate < Base
      SEQ_COLUMN = "last_bulk_action_seq".freeze
      ID_COLUMN = "last_bulk_action_id".freeze

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
        writable = []
        unchanged_ids = Set.new

        records.each do |record|
          if superseded?(record)
            results << superseded(record, record[ID_COLUMN])
            next
          end

          record.assign_attributes(fields)
          if !record.changed?
            # Still stamped below, so an older action can't overwrite these values later.
            unchanged_ids << record.id
            writable << record
          elsif record.valid?
            writable << record
          else
            results << failure(record, record.errors.full_messages.to_sentence)
          end
        end

        results + write(writable, fields, unchanged_ids)
      end

      private

      def write(records, fields, unchanged_ids)
        return [] if records.empty?

        values = records.find { |r| !unchanged_ids.include?(r.id) }&.attributes&.slice(*fields.keys) || {}
        values = values.merge("updated_at" => Time.current)
        ids = records.map(&:id)
        scope = entity.model.where(id: ids)

        return apply(scope, values, records, unchanged_ids) unless ordered?

        values = values.merge(SEQ_COLUMN => sequence, ID_COLUMN => bulk_action.id)
        scope.where("#{SEQ_COLUMN} IS NULL OR #{SEQ_COLUMN} <= ?", sequence).update_all(values)

        # Rows a newer action wrote between our read and our UPDATE were left untouched by the guard.
        lost = entity.model.where(id: ids).where("#{SEQ_COLUMN} > ?", sequence).pluck(:id, ID_COLUMN).to_h
        records.map do |record|
          if lost.key?(record.id) then superseded(record, lost[record.id])
          elsif unchanged_ids.include?(record.id) then skipped(record, "No changes")
          else success(record)
          end
        end
      end

      def apply(scope, values, records, unchanged_ids)
        scope.where.not(id: unchanged_ids.to_a).update_all(values) if unchanged_ids.size < records.size
        records.map { |r| unchanged_ids.include?(r.id) ? skipped(r, "No changes") : success(r) }
      end

      def ordered?
        sequence.present? && entity.model.column_names.include?(SEQ_COLUMN)
      end

      def sequence
        bulk_action.sequence
      end

      def superseded?(record)
        ordered? && record[SEQ_COLUMN].present? && record[SEQ_COLUMN] > sequence
      end

      def superseded(record, newer_action_id)
        skipped(record, "Superseded by newer bulk action ##{newer_action_id}")
      end
    end
  end
end
