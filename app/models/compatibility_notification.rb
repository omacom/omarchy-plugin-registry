class CompatibilityNotification < ApplicationRecord
  belongs_to :compatibility_assessment
  belongs_to :user
  validates :level, inclusion: { in: 1..3 }
end
