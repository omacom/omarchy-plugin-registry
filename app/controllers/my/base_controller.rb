module My
  # The signed-in web side of My Omarchy. Same session as the registry;
  # every page is per-account and never cacheable.
  class BaseController < ApplicationController
    layout "my"
    before_action :require_onboarded
    after_action { response.headers["Cache-Control"] = "no-store" }

    private

    # A name is all My Omarchy needs; the namespace claim is the registry's
    # concern and onboarding handles both in one step.
    def require_onboarded
      redirect_to onboarding_path unless Current.user.onboarded?
    end
  end
end
