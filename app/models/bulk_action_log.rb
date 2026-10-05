class BulkActionLog < ApplicationRecord
  STATUSES = %w[success failed skipped].freeze

  belongs_to :bulk_action

  validates :status, inclusion: { in: STATUSES }

  def as_json(_options = {})
    {
      id: id,
      entity_id: entity_id,
      status: status,
      message: message,
      created_at: created_at
    }
  end
end
