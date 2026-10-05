class Company < ApplicationRecord
  STATUSES = %w[prospect active inactive].freeze
  INDUSTRIES = %w[technology logistics manufacturing retail finance healthcare].freeze

  has_many :opportunities, dependent: :nullify

  validates :name, presence: true, length: { maximum: 255 }
  validates :domain, format: { with: /\A[a-z0-9-]+(\.[a-z0-9-]+)+\z/i }, allow_blank: true
  validates :industry, inclusion: { in: INDUSTRIES }, allow_blank: true
  validates :employee_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :status, inclusion: { in: STATUSES }
end
