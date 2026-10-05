class Lead < ApplicationRecord
  STATUSES = %w[new contacted qualified disqualified].freeze
  SOURCES = %w[website referral event cold_call campaign].freeze

  validates :name, presence: true, length: { maximum: 255 }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :source, inclusion: { in: SOURCES }, allow_blank: true
  validates :score, numericality: { only_integer: true, in: 0..100 }, allow_nil: true
  validates :status, inclusion: { in: STATUSES }
end
