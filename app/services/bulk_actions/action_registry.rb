module BulkActions
  # Maps action_type => handler class. Adding a new bulk action is a new handler + a `register` call.
  module ActionRegistry
    @actions = {}

    class << self
      def register(name, handler_class_name)
        @actions[name.to_s] = handler_class_name.to_s
      end

      def fetch(name)
        @actions.fetch(name.to_s) { raise InvalidRequest, "Unknown action_type '#{name}'. Allowed: #{names.join(', ')}" }.constantize
      end

      def names
        @actions.keys
      end
    end
  end
end
