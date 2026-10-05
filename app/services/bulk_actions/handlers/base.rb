module BulkActions
  module Handlers
    # Contract for every bulk action. The framework (planning, batching, retries, rate limiting,
    # de-duplication, logging, stats) is shared; a handler only implements the per-batch work.
    class Base
      Result = Struct.new(:entity_id, :status, :message)

      # Validate the request payload before the action is accepted. Raise InvalidRequest on error.
      def self.validate_payload!(_entity, _payload); end

      attr_reader :bulk_action, :entity, :payload

      def initialize(bulk_action, entity)
        @bulk_action = bulk_action
        @entity = entity
        @payload = bulk_action.payload
      end

      # records: Array of loaded model instances for one batch.
      # Must return Array<Result> with one entry per record.
      def call(_records)
        raise NotImplementedError
      end

      private

      def success(record, message = nil)
        Result.new(record.id, "success", message)
      end

      def failure(record, message)
        Result.new(record.id, "failed", message)
      end

      def skipped(record, message)
        Result.new(record.id, "skipped", message)
      end
    end
  end
end
