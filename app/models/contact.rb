class Contact < ApplicationRecord
  STATUSES = %w[lead prospect customer churned].freeze

  validates :name, presence: true, length: { maximum: 255 }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :age, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: 150 }, allow_nil: true
  validates :status, inclusion: { in: STATUSES }
end
