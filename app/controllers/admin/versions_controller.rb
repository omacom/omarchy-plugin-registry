module Admin
  class VersionsController < BaseController
    before_action :set_version

    # The inspection view behind every approval: exact bytes, full findings,
    # capability delta, file listing, and a diff of files vs the previous release.
    def show
      @plugin = @version.plugin
      @tarball = Registry::TarballInspector.inspect_bytes(@version.tarball.download) if @version.tarball.attached?
      # Same baseline definition the pipeline used — the human sees the same
      # comparison the machine made
      previous = @version.review_baseline
      if previous&.tarball&.attached?
        @previous = previous
        previous_tarball = Registry::TarballInspector.inspect_bytes(previous.tarball.download)
        @added_files = (@tarball&.files || []) - previous_tarball.files
        @removed_files = previous_tarball.files - (@tarball&.files || [])
        # Full-content digests, never the truncated scan window — same-prefix
        # files with different tails must show as changed
        @changed_files = (@tarball&.files || []).select do |f|
          previous_tarball.digests.key?(f) && previous_tarball.digests[f] != @tarball.digests[f]
        end
      end
    end

    def download_tarball
      return head :not_found unless @version.tarball.attached?
      send_data @version.tarball.download, filename: @version.tarball_filename,
        type: "application/gzip", disposition: "attachment"
    end

    # Approve out of QUARANTINE only — held versions are clean and waiting out
    # the publish-delay window, which an admin click must not bypass. Approval
    # re-enters that same hold window: even human-approved bytes get the
    # worm-brake delay before going live.
    def approve
      return bad_transition! unless @version.quarantined?
      hold = Rails.application.config.x.publish_hold
      # Approval provenance survives the delayed hold: the release job knows a
      # human reviewed these bytes and skips the credential-liveness veto
      @version.update!(approved_at: Time.current, approved_by: Current.user)
      if hold.to_i.positive?
        @version.update!(state: :held, hold_until: hold.from_now)
        Registry::ReleaseJob.set(wait_until: @version.hold_until).perform_later(@version)
        audit "version.approve", public: true
        redirect_to admin_root_path, notice: "Approved — releases when the hold window expires."
      else
        Registry::ReleaseVersion.call(@version, actor: Current.user)
        audit "version.approve", public: true
        regenerate_and_redirect "Approved and published."
      end
    rescue ArgumentError => e
      redirect_to admin_root_path, alert: e.message
    end

    # Legal admin transitions only: rejected/yanked are terminal for these
    # actions, and quarantine applies to live versions. A version that ever
    # shipped can only be yanked/revoked — rejection would erase it from the
    # signed index as if it never existed, hiding the security notice.
    def reject
      return bad_transition! unless @version.releasable? || @version.processing?
      return bad_transition! if @version.published_at.present?
      return require_reason! unless params[:reason].present?
      @version.update!(state: :rejected, review_notes: params[:reason])
      @version.plugin.refresh_latest_version!
      @version.plugin.revert_to_placeholder_if_orphaned_seed!
      audit "version.reject", public: true, metadata: { reason: params[:reason] }
      regenerate_and_redirect "Rejected — version number stays burned."
    end

    def quarantine
      return bad_transition! unless @version.published?
      return require_reason! unless params[:reason].present?
      PluginVersion.transaction do
        changed = PluginVersion.where(id: @version.id, state: :published).update_all(
          state: PluginVersion.states.fetch(:quarantined), review_notes: params[:reason], updated_at: Time.current
        )
        return bad_transition! unless changed == 1

        @version.reload
        @version.plugin.refresh_latest_version!
        audit "version.quarantine", public: true, metadata: { reason: params[:reason] }
      end
      regenerate_and_redirect "Quarantined — drops from the index on regen."
    end

    # Yank progresses from live OR from quarantine-after-publish — the
    # documented investigate-then-withdraw sequence must not require
    # re-publishing the artifact first.
    def yank
      return bad_transition! unless @version.published? || (@version.quarantined? && @version.published_at.present?)
      return require_reason! unless params[:reason].present?
      @version.yank!(reason: params[:reason], actor: Current.user)
      regenerate_and_redirect "Yanked."
    end

    # The kill-bit: yank + revocation entry reaching already-installed copies.
    # Revocation targets bytes that may be INSTALLED somewhere — versions that
    # never published have no installed copies and get rejected instead
    # (yanking them would re-enter the signed index and restore their bytes).
    def revoke
      return bad_transition! unless @version.published? || @version.yanked? || @version.quarantined?
      return bad_transition! if @version.published_at.nil?
      return require_reason! unless params[:reason].present?
      reason = params[:reason]
      ApplicationRecord.transaction do
        if @version.published?
          @version.yank!(reason:, actor: Current.user)
        else
          # Revocation is terminal from any state: a revoked version must
          # never be approvable back into the index
          @version.update!(state: :yanked, yanked_at: Time.current, yank_reason: reason)
        end
        Revocation.find_or_create_by!(plugin: @version.plugin, version: @version.version) do |r|
          r.reason = reason
          r.created_by = Current.user
        end
        audit "version.revoke", public: true, metadata: { reason: }
      end
      regenerate_and_redirect "Revoked — kill list updated, installed copies will disable."
    end

    private

    def set_version
      @version = PluginVersion.find(params[:id])
    end

    def audit(action, public: false, metadata: {})
      AuditEvent.record!(actor: Current.user, action:, subject: @version, public:,
        metadata: { plugin: @version.plugin.full_name, version: @version.version }.merge(metadata))
    end

    def require_reason!
      redirect_to admin_version_path(@version), alert: "A public reason is required for takedown actions."
    end

    def bad_transition!
      redirect_to admin_version_path(@version), alert: "That action isn't valid from the #{@version.state} state."
    end

    def regenerate_and_redirect(notice)
      DataPlane::RegenerateJob.perform_later(@version.plugin)
      redirect_to admin_root_path, notice: notice
    end
  end
end
