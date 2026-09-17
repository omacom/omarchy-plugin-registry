module Admin
  class CompatibilityChecksController < BaseController
    def create
      Registry::RecordCompatibilityChecks.call(actor: Current.user, document: params.expect(:evidence))
      redirect_to compatibilities_path, status: :see_other, notice: "Runner evidence recorded. Failures raise warnings; confirmation still requires an audited decision."
    rescue JSON::ParserError, ArgumentError, ActiveRecord::RecordInvalid => e
      render plain: e.message, status: :unprocessable_entity
    end
  end
end
