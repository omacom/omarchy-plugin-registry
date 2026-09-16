module Registry
  # The go-live step: freeze the exact reviewed bytes to the data plane,
  # mark published, regenerate the index. Reviewed bytes are executed bytes.
  class ReleaseVersion
    def self.call(version, actor: nil)
      # All authorization gates re-run under the row lock so a concurrent
      # takedown can't slip between check and publish
      version.with_lock { locked_call(version, actor:) }
    end

    def self.locked_call(version, actor:)
      # Only the review pipeline or an atomic human approval may enter held.
      # Quarantine is NEVER releasable by a stale scheduled job or direct call.
      raise ArgumentError, "cannot release a #{version.state} version" unless version.held?
      if Revocation.exists?(plugin: version.plugin, version: version.version)
        raise ArgumentError, "version is on the kill list and can never be released"
      end
      # A quarantined placeholder (only rejected history besides this version)
      # reactivates when its correction releases; anything else must be active.
      placeholder_correction = version.plugin.quarantined? &&
        version.plugin.versions.where.not(state: :rejected).where.not(id: version.id).none?
      unless version.plugin.active? || placeholder_correction
        raise ArgumentError, "cannot release into a #{version.plugin.state} plugin"
      end
      # Suspension or membership loss between submit and release must stop the
      # release — the hold window exists precisely for this.
      raise ArgumentError, "publisher is suspended" if version.plugin.publisher.suspended?
      if (submitter = version.user) && !submitter.system?
        raise ArgumentError, "submitter is suspended" if submitter.suspended_at.present?
        unless submitter.member_of?(version.plugin.publisher)
          raise ArgumentError, "submitter is no longer a member of #{version.plugin.publisher.name}"
        end
        # Same bar as publishing: losing the second factor or a fresh sensitive
        # change pauses releases too, not just new submissions
        raise ArgumentError, "submitter can no longer publish (second factor or cooldown)" unless submitter.can_publish?
      end

      # Approval provenance is only honored while the APPROVER's authority
      # survives the hold window: a suspended or demoted admin's approval
      # returns the bytes to quarantine instead of publishing on dead
      # authority.
      approval_live = version.approved_at.present? &&
        version.approved_by&.admin? && version.approved_by.suspended_at.nil?
      if version.held? && version.approved_at.present? && !approval_live
        version.update!(state: :quarantined, hold_until: nil,
          review_notes: "#{version.review_notes} [approving admin no longer authorized]".strip)
        AuditEvent.record!(action: "version.approval_invalidated", subject: version,
          metadata: { plugin: version.plugin.full_name, version: version.version })
        return version
      end
      # The credential that carried the submission must still be alive when a
      # PIPELINE release fires: a token revoked during the hold window (stolen
      # token killed, trusted-publisher registration removed — which revokes
      # its minted tokens) quarantines the version for human review instead of
      # shipping. A LIVE admin approval is a human override — the bytes were
      # reviewed — and skips only this veto.
      if version.held? && !approval_live && version.api_token&.revoked_at&.present?
        version.update!(state: :quarantined, hold_until: nil,
          review_notes: "#{version.review_notes} [submitting credential revoked during hold]".strip)
        AuditEvent.record!(action: "version.credential_revoked", subject: version,
          metadata: { plugin: version.plugin.full_name, version: version.version })
        return version
      end

      if Rails.application.config.x.enforce_review_policy && !approval_live && !version.automated_review_passed?
        version.update!(state: :quarantined, hold_until: nil,
          review_notes: "automatic release stopped: complete review evidence is missing or outdated")
        AuditEvent.record!(action: "version.review_evidence_missing", subject: version,
          metadata: { plugin: version.plugin.full_name, version: version.version })
        return version
      end

      raise ArgumentError, "release has no hold deadline" unless version.hold_until
      return version if version.hold_until.future?

      bytes = version.tarball.download
      raise "tarball checksum mismatch at release" unless Digest::SHA256.hexdigest(bytes) == version.sha256

      ApplicationRecord.transaction do
        version.plugin.update!(state: :active) if placeholder_correction
        # Seeded imports go live under their ORIGINAL marketplace listing time
        # (provenance-recorded, system-seed only) so recency surfaces and
        # publish-date analytics survive the migration.
        version.update!(state: :published, published_at: version.seed_listed_at || Time.current, hold_until: nil)
        DataPlane.freeze_tarball(version, bytes)
        # refresh_latest_version! also applies page metadata from whichever
        # version is now the latest published one — only cleared code ever
        # shapes the public page.
        version.plugin.refresh_latest_version!
        AuditEvent.record!(actor:, action: "version.publish", subject: version, public: true,
          metadata: { plugin: version.plugin.full_name, version: version.version, sha256: version.sha256 })
      end
      DataPlane::RegenerateJob.perform_later(version.plugin)
      version
    end
    private_class_method :locked_call
  end
end
