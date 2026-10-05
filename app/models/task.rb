class Task < ApplicationRecord
  STATUSES = %w[todo in_progress done].freeze
  PRIORITIES = %w[low medium high].freeze

  validates :title, presence: true, length: { maximum: 255 }
  validates :status, inclusion: { in: STATUSES }
  validates :priority, inclusion: { in: PRIORITIES }
end
