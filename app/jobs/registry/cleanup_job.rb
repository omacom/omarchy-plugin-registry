module Registry
  # Recurring housekeeping: dead device-flow rows and stale login codes.
  class CleanupJob < ApplicationJob
    queue_as :critical

    def perform
      DeviceAuthorization.where(expires_at: ...1.day.ago).delete_all
      LoginCode.where(created_at: ...1.day.ago).delete_all
      # Tokens referenced by a version are provenance records — their
      # revocation state gates held releases — and the FK is restrictive;
      # only unreferenced expired tokens age out.
      ApiToken.where(expires_at: ...30.days.ago)
        .where.not(id: PluginVersion.where.not(api_token_id: nil).select(:api_token_id))
        .delete_all
      Session.expired.delete_all
      purge_expired_snaps
      purge_unverified_users
      purge_rejected_tarballs
      resume_stuck_pipeline_work
      Plugin.find_each(&:flush_cached_views!) if Rails.env.production?
    end

    private

    # A snap past its expiry is already invisible; drop its bytes too.
    def purge_expired_snaps
      Snap.expired.find_each do |snap|
        snap.image.purge if snap.image.attached?
        snap.preview.purge if snap.preview.attached?
        snap.destroy
      end
    end

    # A sign-in request creates the user row BEFORE mailbox ownership is
    # proven; rows that never redeem a code are pending, not permanent.
    # Membership/admin guards keep seeded principals and invitees safe.
    def purge_unverified_users
      User.where(verified_at: nil, admin: false)
        .where(created_at: ...2.days.ago)
        .where.missing(:memberships)
        .find_each do |user|
        user.destroy
      rescue ActiveRecord::InvalidForeignKey, ActiveRecord::DeleteRestrictionError
        nil
      end
    end

    # Storage retention is bounded for everything that never shipped:
    # - rejected uploads lose their bytes after 30 days (rows stay burned)
    # - NEVER-published quarantined uploads that nobody touched for 90 days
    #   expire to rejected and lose their bytes — the admin queue is not an
    #   indefinite free storage locker
    # Published/yanked bytes stay (reproducibility); once-published quarantined
    # bytes stay (under investigation, were public).
    def purge_rejected_tarballs
      PluginVersion.rejected.where(updated_at: ...30.days.ago).find_each do |version|
        version.tarball.purge if version.tarball.attached?
      end

      PluginVersion.quarantined.where(published_at: nil).where(updated_at: ...90.days.ago).find_each do |version|
        version.update!(state: :rejected, review_notes: "#{version.review_notes} [expired unreviewed after 90 days]".strip)
        version.tarball.purge if version.tarball.attached?
        AuditEvent.record!(action: "version.quarantine_expired", subject: version, public: true,
          metadata: { plugin: version.plugin.full_name, version: version.version })
        version.plugin.revert_to_placeholder_if_orphaned_seed!
      end
    end

    # A lost enqueue must never strand a version: re-drive processing versions
    # through review and overdue held versions through release.
    #
    # "Stuck" means NO job is waiting for it — not merely "old". Two things
    # break the naive reading: seeded imports backdate created_at to their
    # original marketplace listing date, so they are born months "old", and a
    # bulk import leaves thousands of versions legitimately queued behind a
    # slow reviewer. Re-driving those added ~1,400 redundant jobs an hour,
    # growing without bound for as long as the backlog lasted.
    def resume_stuck_pipeline_work
      PluginVersion.processing.where(updated_at: ...10.minutes.ago)
        .where.not(id: version_ids_with_pending_review).find_each do |version|
        ReviewJob.perform_later(version)
      end
      PluginVersion.held.where(hold_until: ...5.minutes.ago).find_each do |version|
        ReleaseJob.perform_later(version)
      end
    end

    # Version ids that already have an unfinished ReviewJob queued. Read once
    # per sweep: the alternative is a LIKE against every row per version.
    #
    # Empty when the queue backend cannot be read (another adapter, or the
    # test environment) — that degrades to the old unconditional re-drive,
    # which is the safe direction: a redundant job no-ops, a missing one
    # strands a version in processing forever.
    def version_ids_with_pending_review
      return [] unless defined?(SolidQueue::Job) && SolidQueue::Job.table_exists?
      SolidQueue::Job.where(class_name: "Registry::ReviewJob", finished_at: nil)
        .pluck(:arguments).filter_map do |raw|
          # The column is JSON: some adapters hand back the decoded Hash and
          # some the raw string. Parsing blindly turns a Hash into a
          # ParserError, which would silently empty this list and re-drive
          # every queued version — the exact amplification this prevents.
          payload = raw.is_a?(String) ? JSON.parse(raw) : raw
          payload.dig("arguments", 0, "_aj_globalid")&.split("/")&.last&.to_i
        rescue JSON::ParserError, TypeError
          nil
        end
    rescue ActiveRecord::ActiveRecordError
      []
    end
  end
end
