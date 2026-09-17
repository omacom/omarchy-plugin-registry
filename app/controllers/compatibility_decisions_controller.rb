class CompatibilityDecisionsController < ApplicationController
  before_action :require_recent_second_factor
  before_action :require_no_sensitive_cooldown

  def create
    assessment = CompatibilityAssessment.find(params.expect(:compatibility_assessment_id))
    attributes = params.expect(decision: %i[decision reason])
    assessment.decide!(actor: Current.user, **attributes.to_h.symbolize_keys)
    redirect_to compatibility_path(assessment), status: :see_other, notice: "Audited decision saved. Signed advisories are rebuilding."
  rescue ActiveRecord::RecordInvalid, ArgumentError => e
    render plain: e.message, status: :unprocessable_entity
  end
end
