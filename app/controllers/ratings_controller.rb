class RatingsController < ApplicationController
  def create
    plugin = find_plugin
    rating = plugin.ratings.find_or_initialize_by(user: Current.user)
    rating.update!(value: params[:value].to_i.clamp(1, 5))
    redirect_to helpers.package_path(plugin), notice: "Rated #{rating.value}/5."
  end

  private

  def find_plugin
    Publisher.find_by!(name: params[:publisher]).plugins.find_by!(name: params[:name])
  end
end
