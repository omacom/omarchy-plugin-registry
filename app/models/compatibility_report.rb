class CompatibilityReport < ApplicationRecord
  belongs_to :compatibility_assessment
  belongs_to :user

  validates :user_id, uniqueness: { scope: :compatibility_assessment_id }
  validates :outcome, inclusion: { in: %w[works problem] }
  validates :category, inclusion: { in: %w[appearance activation other none] }
  validates :details, length: { maximum: 4000 }
  validates :details, presence: true, if: -> { outcome == "problem" }
  validates :modified, inclusion: { in: [ true, false ] }
  validate :problem_category

  # User attestations, not proof of installation. Suspended and unverified
  # accounts and modified copies never influence public counts.
  scope :eligible, -> { joins(:user).where(modified: false, users: { suspended_at: nil }).where.not(users: { verified_at: nil }) }

  private

  def problem_category
    errors.add(:category, "must describe the problem") if outcome == "problem" && category == "none"
  end
end
