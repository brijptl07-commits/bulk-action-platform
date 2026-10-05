class Opportunity < ApplicationRecord
  STAGES = %w[prospecting qualification proposal negotiation closed_won closed_lost].freeze

  belongs_to :company, optional: true

  validates :name, presence: true, length: { maximum: 255 }
  validates :amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :stage, inclusion: { in: STAGES }
  validates :probability, numericality: { only_integer: true, in: 0..100 }, allow_nil: true
end
