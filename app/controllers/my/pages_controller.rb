module My
  class PagesController < BaseController
    allow_unauthenticated_access
    skip_before_action :require_onboarded

    def setup
    end
  end
end
