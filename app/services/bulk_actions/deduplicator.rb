module BulkActions
  # Splits planned rows into [process_ids, duplicate_ids] by the entity's dedupe field.
  # The first occurrence (lowest id, since planning walks ids in order) wins. A Redis set holds
  # the values seen so far, so memory stays flat even for millions of records.
  class Deduplicator
    def initialize(bulk_action)
      @key = "bulk_actions:dedupe:#{bulk_action.id}"
    end

    # rows: [[id, value], ...]
    def split(rows)
      with_value = rows.select { |_id, value| value.present? }
      added = if with_value.any?
                Sidekiq.redis do |r|
                  flags = r.pipelined { |p| with_value.each { |_id, value| p.call("SADD", @key, value.to_s.downcase.strip) } }
                  r.call("EXPIRE", @key, 86_400)
                  flags
                end
              else
                []
              end
      duplicate_ids = with_value.zip(added).filter_map { |(id, _), flag| id if flag.to_i.zero? }
      [rows.map(&:first) - duplicate_ids, duplicate_ids]
    end

    def cleanup
      Sidekiq.redis { |r| r.call("DEL", @key) }
    end
  end
end
