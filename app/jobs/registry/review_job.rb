module Registry
  # The automated review pipeline, run on every version of every plugin —
  # updates never skip it. Deterministic scan -> capability fingerprint ->
  # delta check -> AI review -> hold window -> live.
  class ReviewJob < ApplicationJob
    queue_as :review
    discard_on ActiveJob::DeserializationError
    # One review per plugin at a time: concurrent reviews of back-to-back
    # submissions could both observe the same (or no) capability baseline.
    limits_concurrency to: 1, key: ->(version) { "review_plugin_#{version.plugin_id}" }

    def perform(version)
      return unless version.processing?
      # Semantic-version order: reviewing 1.2.0 before 1.1.0 finished would
      # compare both against the wrong predecessor and could hide growth
      if version.lower_version_in_review?
        self.class.set(wait: 1.minute).perform_later(version)
        return
      end
      plugin = version.plugin

      tarball = TarballInspector.inspect_bytes(version.tarball.download)
      raise TarballInspector::InvalidTarball, "tarball checksum mismatch at review" unless tarball.sha256 == version.sha256

      # 1. Deterministic scanning
      scanner = Scanner.new(tarball, plugin: plugin)
      scanner.scan
      findings = scanner.findings.map(&:as_json)

      # 2. Capability fingerprint + delta vs the last version that CLEARED
      # review. The baseline includes yanked and once-published-quarantined
      # versions: a takedown must not erase the baseline and let the next
      # submission inherit a smaller comparison surface.
      fingerprint = CapabilityFingerprint.compute(tarball)
      previous = version.review_baseline
      growth = CapabilityFingerprint.growth(previous&.capability_fingerprint, fingerprint)

      # 3. Advisory AI review of the current source. Updates also carry changed
      # paths and explicitly partial previous-source context.
      if scanner.verdict == :pass
        changed_files = changed_files_since(previous, tarball) if AiReview.enabled?
        ai = AiReview.review(version:, tarball:, fingerprint:, scan_findings: findings,
          previous: previous, capability_growth: growth, changed_files: changed_files || [],
          previous_contents: @previous_contents || {})
      else
        ai = AiReview::Result.new("skipped", [ "deterministic findings already require rejection or human review" ])
      end

      # An admin may have rejected or security-held this version while the
      # scan ran — never overwrite a terminal state with a pipeline outcome.
      version.with_lock do
        break unless version.processing?

        version.update!(
          capability_fingerprint: fingerprint,
          scan_results: { "findings" => findings, "capability_growth" => growth,
                          "ai" => { "verdict" => ai.verdict, "reasons" => ai.reasons, "coverage" => ai.coverage } }
        )

        # Legacy provenance is evidence for a HUMAN, never an exemption from
        # current findings or the first-release gate.
        case
        when scanner.verdict == :fail
          reject!(version, findings)
        when scanner.verdict == :flag
          quarantine!(version, "scanner flagged: #{findings.map { |f| f['rule'] }.uniq.join(', ')}")
        when previous && growth.any?
          quarantine!(version, "capability surface grew: #{growth.join(', ')}")
        when ai.flagged?
          quarantine!(version, "ai review flagged: #{ai.reasons.join('; ').first(300)}")
        when previous.nil? && !Rails.application.config.x.skip_first_release_gate && (!plugin.theme? || !AiReview.enabled?)
          quarantine!(version, "first release requires human review; AI cannot approve executable plugins")
        when (fingerprint["dynamic_exec"].present? || fingerprint["dynamic_network"].present?) &&
             !Rails.application.config.x.skip_first_release_gate
          # Static analysis cannot see the VALUES flowing into a dynamic call
          # site — a variable can turn malicious with no textual change at the
          # site. Plugins containing dynamic execution/network therefore never
          # ride pure-deterministic auto-release: every version needs judgment
          # from a human, whether or not the advisory AI is enabled.
          quarantine!(version, "contains dynamic execution/network call sites — requires judgment review on every version")
        else
          hold_or_release(version)
        end
      end
    rescue TarballInspector::InvalidTarball, ActiveStorage::IntegrityError
      version.with_lock do
        quarantine!(version, "archive integrity or inspection failed; review could not complete") if version.processing?
      end
    end

    private

    def changed_files_since(previous, tarball)
      return [] unless previous&.tarball&.attached?
      previous_inspection = TarballInspector.inspect_bytes(previous.tarball.download)
      previous_digests = previous_inspection.digests
      added = tarball.files - previous_digests.keys
      changed = tarball.files.select { |f| previous_digests[f] && previous_digests[f] != tarball.digests[f] }
      removed = previous_digests.keys - tarball.files
      # Bounded previous contents for changed files so the reviewer can diff
      # actual source, not just names
      @previous_contents = changed.first(20).index_with do |f|
        previous_inspection.contents[f].to_s.byteslice(0, 16.kilobytes).dup.force_encoding(Encoding::UTF_8).scrub
      end
      added.map { |f| "+#{f}" } + changed.map { |f| "~#{f}" } + removed.map { |f| "-#{f}" }
    rescue TarballInspector::InvalidTarball
      []
    end

    # Even a fully clean version waits out a short hold before going live —
    # worm-speed propagation dies to a cheap delay.
    def hold_or_release(version)
      hold = Rails.application.config.x.publish_hold
      # `held` marks "review passed" — the only state ReleaseVersion accepts.
      # Human approvals also enter held atomically with approval provenance.
      version.update!(state: :held, hold_until: hold.to_i.positive? ? hold.from_now : Time.current)
      if hold.to_i.positive?
        ReleaseJob.set(wait_until: version.hold_until).perform_later(version)
      else
        ReleaseVersion.call(version)
      end
    end

    def reject!(version, findings)
      version.update!(state: :rejected,
        review_notes: "auto-rejected: #{findings.select { |f| f['severity'] == 'fail' }.map { |f| f['detail'] }.join('; ').first(500)}")
      AuditEvent.record!(action: "version.auto_reject", subject: version, public: true,
        metadata: { plugin: version.plugin.full_name, version: version.version })
      # Ordinary rejected-only submissions drop out of directory_visible;
      # seeded ones revert to a visible placeholder (shared invariant).
      version.plugin.revert_to_placeholder_if_orphaned_seed!
    end

    def quarantine!(version, reason)
      version.update!(state: :quarantined, review_notes: reason)
      AuditEvent.record!(action: "version.auto_quarantine", subject: version,
        metadata: { plugin: version.plugin.full_name, version: version.version, reason: reason })
    end
  end
end
