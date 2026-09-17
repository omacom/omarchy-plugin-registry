class CompatibilityReport < ApplicationRecord
  belongs_to :compatibility_assessment
  belongs_to :user
  has_one :comment, dependent: :destroy
  # Never copy historical private reproduction details into comments.
  attr_writer :public_comment

  def public_comment
    defined?(@public_comment) ? @public_comment : comment&.body
  end

  validates :user_id, uniqueness: { scope: :compatibility_assessment_id }
  validates :outcome, inclusion: { in: %w[works problem] }
  validates :category, inclusion: { in: %w[appearance activation other none] }
  validates :details, length: { maximum: 4000 }
  validates :public_comment, length: { minimum: 3, maximum: 2000 }, allow_blank: true
  validate :problem_description
  validates :modified, inclusion: { in: [ true, false ] }
  validate :problem_category

  # User attestations, not proof of installation. Suspended and unverified
  # accounts and modified copies never influence public counts.
  scope :eligible, -> { joins(:user).where(modified: false, users: { suspended_at: nil }).where.not(users: { verified_at: nil }) }

  private

  def problem_description
    errors.add(:details, "or a public comment is required for a problem") if outcome == "problem" && details.blank? && public_comment.blank?
  end

  def problem_category
    errors.add(:category, "must describe the problem") if outcome == "problem" && category == "none"
  end
end
