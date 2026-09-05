module Registry
  # The publish pipeline, Phase 1 shape: authorize → inspect → validate →
  # freeze → index. Scanning (Phase 2) slots in between validate and freeze
  # behind the same API without touching clients.
  class PublishVersion
    class PublishError < StandardError
      attr_reader :status
      def initialize(message, status: :unprocessable_entity)
        super(message)
        @status = status
      end
    end

    attr_reader :version

    # system_seed skips membership/MFA/claim checks — used ONLY by the seed
    # importer; seeded versions still run the full review pipeline.
    # seed_provenance carries the legacy-marketplace lineage (source repo,
    # reviewed commit, original id, original listing time) — accepted only on
    # the system_seed path, never from a client-supplied publish.
    def initialize(user:, publisher:, plugin_name:, tarball_bytes:, token: nil, system_seed: false, seed_provenance: nil, package_type: nil)
      @user = user
      @publisher = publisher
      @plugin_name = plugin_name
      @tarball_bytes = tarball_bytes
      @token = token
      @system_seed = system_seed
      @seed_provenance = system_seed ? seed_provenance : nil
      @expected_package_type = package_type
    end

    def call
      authorize!
      inspect_tarball!
      find_or_build_plugin!
      check_version!
      validate_manifest!
      validate_preview!
      create_version!
      version
    end

    private

    attr_reader :user, :publisher, :plugin_name, :tarball_bytes, :token, :plugin, :tarball

    def authorize!
      fail! "publisher is suspended", status: :forbidden if publisher.suspended?
      # The seed system identity is permanently suspended (it can never sign
      # in) — its user-level checks are meaningless for seeding
      return if @system_seed
      fail! "account is suspended", status: :forbidden if user.suspended_at.present?
      fail! "namespace is unclaimed — prove control of the source repo to claim it", status: :forbidden unless publisher.claimed?
      membership = user.memberships.accepted.find_by(publisher: publisher)
      fail! "you are not a member of #{publisher.name}", status: :forbidden if membership.nil?
      # Roster changes are an account-takeover vector: freshly ACCEPTED members
      # wait out a cooldown before publishing through the namespace. Exemption
      # is the explicit founding marker set when the namespace was created —
      # never inferred, never drifting.
      if membership.accepted_at > User::PUBLISH_COOLDOWN.ago && !membership.founding?
        fail! "recently added members wait #{User::PUBLISH_COOLDOWN.inspect} before publishing to #{publisher.name}", status: :forbidden
      end
      fail! "add a passkey or enable two-factor authentication to publish", status: :forbidden unless user.second_factor?
      fail! "publishing is paused after a recent account change — try again later", status: :forbidden if user.in_publish_cooldown?
      if token && !token.authorizes?(publisher, plugin_name)
        fail! "token scope (#{token.scope_label}) does not cover #{publisher.name}/#{plugin_name}", status: :forbidden
      end
    end

    def inspect_tarball!
      @tarball = TarballInspector.inspect_bytes(tarball_bytes)
    rescue TarballInspector::InvalidTarball => e
      fail! e.message
    end

    # A quarantined plugin whose only history is seed failure/rejection is a
    # placeholder: once the namespace is claimed, its owner can publish a
    # corrected version and the plugin reactivates — but only AFTER the new
    # submission passes validation (see create_version!).
    def find_or_build_plugin!
      package_type = tarball.manifest.fetch("packageType", "plugin")
      fail! "packageType must be plugin or theme" unless Plugin::PACKAGE_TYPES.include?(package_type)
      if @expected_package_type && package_type != @expected_package_type
        fail! "this endpoint accepts #{@expected_package_type} packages, not #{package_type}"
      end
      @plugin = publisher.plugins.find_by(name: plugin_name)
      if plugin.nil?
        @plugin = publisher.plugins.new(name: plugin_name, package_type: package_type)
        # Seeds grandfather legacy omarchy-* names; interactive publishes don't
        plugin.allow_reserved = true if @system_seed
        fail! plugin.errors.full_messages.join("; ") unless plugin.valid?
      elsif plugin.quarantined? && plugin.versions.where.not(state: :rejected).none?
        # Placeholder correction: accept the submission but leave the plugin
        # quarantined — it only reactivates when the correction RELEASES
        # (ReleaseVersion), so a failed correction changes nothing publicly.
        nil
      elsif !plugin.active?
        fail! "#{plugin.full_name} is #{plugin.state.humanize.downcase} and cannot accept new versions", status: :forbidden
      end
      fail! "package type is immutable for #{plugin.full_name}" unless plugin.package_type == package_type
      check_submission_limits!
    end

    # Resource brakes: unbounded submissions would retain 10MB each and flood
    # the review queue. Publisher-wide limits apply to FIRST submissions too —
    # new plugin names are not an exemption.
    MAX_PENDING_PER_PLUGIN = 5
    MAX_SUBMISSIONS_PER_DAY = 12
    MAX_PUBLISHER_SUBMISSIONS_PER_DAY = 30
    MAX_USER_SUBMISSIONS_PER_DAY = 40
    MAX_PLUGINS_PER_PUBLISHER = 100
    # Bytes, not just rows: retained uploads (anything whose tarball we still
    # hold) are capped per account so deliberate quarantines can't fill the disk
    MAX_RETAINED_BYTES_PER_USER = 400 * 1024 * 1024

    def check_submission_limits!
      return if @system_seed

      # Per-ACCOUNT ceiling: creating extra orgs must not multiply quota
      user_daily = PluginVersion.where(user: user, created_at: 24.hours.ago..).count
      if user_daily >= MAX_USER_SUBMISSIONS_PER_DAY
        fail! "account-wide publish rate limit reached (#{MAX_USER_SUBMISSIONS_PER_DAY}/day)", status: :too_many_requests
      end

      # Rejected uploads count too while their bytes are still retained
      # (CleanupJob purges them after 30 days)
      retained = PluginVersion.where(user: user)
        .where("state != :rejected OR updated_at >= :cutoff",
          rejected: PluginVersion.states[:rejected], cutoff: 30.days.ago)
        .sum(:size_bytes)
      if retained + tarball.size_bytes > MAX_RETAINED_BYTES_PER_USER
        fail! "account storage quota reached (#{MAX_RETAINED_BYTES_PER_USER / 1024 / 1024}MB of retained uploads)", status: :too_many_requests
      end

      publisher_daily = PluginVersion.joins(:plugin)
        .where(plugins: { publisher_id: publisher.id }, created_at: 24.hours.ago..).count
      if publisher_daily >= MAX_PUBLISHER_SUBMISSIONS_PER_DAY
        fail! "publisher-wide publish rate limit reached (#{MAX_PUBLISHER_SUBMISSIONS_PER_DAY}/day)", status: :too_many_requests
      end
      if !plugin.persisted? && publisher.plugins.count >= MAX_PLUGINS_PER_PUBLISHER
        fail! "publisher has reached the #{MAX_PLUGINS_PER_PUBLISHER}-plugin limit", status: :too_many_requests
      end
      return unless plugin.persisted?

      if plugin.versions.where(state: [ :processing, :held, :quarantined ]).count >= MAX_PENDING_PER_PLUGIN
        fail! "too many versions awaiting review for #{plugin.full_name} — wait for the pipeline or the admin queue", status: :too_many_requests
      end
      if plugin.versions.where(created_at: 24.hours.ago..).count >= MAX_SUBMISSIONS_PER_DAY
        fail! "publish rate limit reached for #{plugin.full_name} (#{MAX_SUBMISSIONS_PER_DAY}/day)", status: :too_many_requests
      end
    end

    def check_version!
      candidate = tarball.manifest["version"].to_s
      fail! "manifest version must be strict semver (got #{candidate})" unless Semver.valid?(candidate)

      if plugin.persisted?
        fail! "#{plugin.full_name}@#{candidate} already exists — versions are immutable", status: :conflict if plugin.version_burned?(candidate)
        if (highest = plugin.highest_version) && Semver.parse(candidate) <= highest.semver
          fail! "version #{candidate} must be greater than #{highest.version}"
        end
      end
    end

    def validate_manifest!
      validator = ManifestValidator.new(manifest: tarball.manifest, publisher:, plugin_name:, tarball:)
      fail! validator.errors.join("; ") unless validator.valid?
    end

    # The preview is optional, but a broken one fails HERE — instant CLI
    # feedback — instead of freezing junk into an immutable release.
    def validate_preview!
      return if tarball.preview_bytes.nil?
      PreviewImage.validate!(tarball.preview_bytes, name: tarball.preview_name)
    rescue PreviewImage::InvalidPreview => e
      fail! e.message
    end

    # Structural validation is synchronous (instant CLI feedback); everything
    # judgment-shaped runs in the ReviewJob pipeline. The version lands in
    # `processing` and goes live only after scan + hold.
    def create_version!
      # Public plugin metadata (summary/kinds/repo/readme) is NOT touched here —
      # ReleaseVersion applies it when a version actually clears review, so a
      # rejected update can never deface the live page.
      ApplicationRecord.transaction do
        # Serialize an account's submissions: quotas re-checked under the USER
        # row lock so concurrent uploads can't all observe pre-commit counts
        user.lock!
        check_submission_limits!
        plugin.save! unless plugin.persisted?
        # Re-run the ordering checks under the row lock: two concurrent
        # submissions must not both pass the same pre-transaction baseline
        plugin.lock!
        candidate = tarball.manifest["version"].to_s
        fail! "#{plugin.full_name}@#{candidate} already exists — versions are immutable", status: :conflict if plugin.version_burned?(candidate)
        if (highest = plugin.highest_version) && Semver.parse(candidate) <= highest.semver
          fail! "version #{candidate} must be greater than #{highest.version}"
        end
        @version = plugin.versions.create!(
          user: user,
          version: tarball.manifest["version"],
          manifest: tarball.manifest,
          sha256: tarball.sha256,
          size_bytes: tarball.size_bytes,
          license: tarball.manifest["license"],
          min_omarchy_version: tarball.manifest["minOmarchyVersion"],
          provenance: @seed_provenance || token&.provenance,
          api_token: token,
          state: :processing
        )
        version.tarball.attach(
          io: StringIO.new(tarball_bytes),
          filename: version.tarball_filename,
          content_type: "application/gzip"
        )
        AuditEvent.record!(actor: user, action: "version.submit", subject: version,
          metadata: { plugin: plugin.full_name, version: version.version, sha256: version.sha256 })
      end
      ReviewJob.perform_later(version)
    rescue ActiveRecord::RecordNotUnique
      # Two concurrent publishes of the same version: the loser gets the same
      # answer a sequential attempt would
      fail! "#{plugin.full_name}@#{tarball.manifest['version']} already exists — versions are immutable", status: :conflict
    end

    def fail!(message, status: :unprocessable_entity)
      raise PublishError.new(message, status:)
    end
  end
end
