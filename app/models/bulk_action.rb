class BulkAction < ApplicationRecord
  STATUSES = %w[scheduled queued in_progress completed failed cancelled].freeze
  ACTIVE_STATUSES = %w[scheduled queued in_progress].freeze
  FINISHED_STATUSES = %w[completed failed cancelled].freeze

  has_many :logs, class_name: "BulkActionLog", dependent: :delete_all

  validates :account_id, :entity_type, :action_type, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(id: :desc) }

  STATUSES.each do |s|
    define_method("#{s}?") { status == s }
  end

  def payload
    super || {}
  end

  def filters
    super || {}
  end

  def finished?
    FINISHED_STATUSES.include?(status)
  end

  def progress_percent
    return (finished? ? 100 : 0) if total_count.zero?

    ((processed_count.to_f / total_count) * 100).round(2)
  end

  def entity_config
    BulkActions::EntityRegistry.fetch(entity_type)
  end

  def handler_class
    BulkActions::ActionRegistry.fetch(action_type)
  end

  # Atomic, conditional status transition; returns true if this caller won the race.
  def transition!(from:, to:, **attrs)
    updated = self.class.where(id: id, status: Array(from)).update_all(attrs.merge(status: to, updated_at: Time.current))
    reload if updated.positive?
    updated.positive?
  end

  # Marks the action completed once planning is done and every planned record is processed.
  def self.complete_if_done!(id)
    where(id: id, status: "in_progress")
      .where.not(planned_at: nil)
      .where("processed_count >= total_count")
      .update_all(status: "completed", completed_at: Time.current, updated_at: Time.current)
  end

  def stats
    {
      id: id,
      status: status,
      total: total_count,
      processed: processed_count,
      success: success_count,
      failed: failure_count,
      skipped: skipped_count,
      pending: [total_count - processed_count, 0].max,
      progress_percent: progress_percent
    }
  end

  def as_json(_options = {})
    {
      id: id,
      account_id: account_id,
      entity_type: entity_type,
      action_type: action_type,
      status: status,
      payload: payload,
      filters: filters,
      dedupe: dedupe,
      stats: stats.except(:id, :status),
      scheduled_at: scheduled_at,
      started_at: started_at,
      completed_at: completed_at,
      error_message: error_message,
      created_at: created_at,
      updated_at: updated_at
    }
  end
end
