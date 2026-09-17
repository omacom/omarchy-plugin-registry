class PublishersController < ApplicationController
  include ConditionalGet
  allow_unauthenticated_access

  def show
    @publisher = Publisher.find_by!(name: params[:name])
    # includes/with_attached: the shared plugin partial reads publisher and
    # preview for every row, and both formats render it.
    @plugins = @publisher.plugins.directory_visible
      .includes(:publisher).with_previews
      .order(downloads_count: :desc)
    freshen(@publisher, @plugins)
  end
end
