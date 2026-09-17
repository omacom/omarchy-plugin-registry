class CommentsController < ApplicationController
  rate_limit to: 5, within: 1.hour, only: :create,
    with: -> { redirect_back fallback_location: root_path, alert: "Slow down — try again in a bit." }

  def create
    plugin = find_plugin
    comment = plugin.comments.new(user: Current.user, body: params[:body])
    if comment.save
      redirect_to helpers.package_path(plugin), notice: "Comment posted."
    else
      redirect_to helpers.package_path(plugin), alert: comment.errors.full_messages.join("; ")
    end
  end

  # Authors delete their own comments; moderation (hiding others') lives in the
  # MFA-gated admin controllers and always leaves an audit trail.
  def destroy
    comment = Current.user.comments.find(params[:id])
    comment.destroy!
    redirect_back fallback_location: root_path, notice: "Comment removed."
  end

  private

  def find_plugin
    Publisher.find_by!(name: params[:publisher]).plugins.find_by!(name: params[:name])
  end
end
