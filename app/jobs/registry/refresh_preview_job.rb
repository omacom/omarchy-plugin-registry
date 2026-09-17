module Registry
  # Regenerates a plugin's preview renditions from whatever version is NOW the
  # latest published one. Enqueued whenever that changes (release, yank,
  # takedown); everything is re-derived from current state, so a stale or
  # duplicate run converges on the same result.
  class RefreshPreviewJob < ApplicationJob
    # NOT the review queue: a preview is cosmetic and quick, and sharing a
    # queue with multi-pass AI reviews meant a bulk import buried every
    # thumbnail behind thousands of slow jobs. Same reasoning that keeps
    # mailers off it.
    queue_as :previews
    discard_on ActiveJob::DeserializationError
    # Serialized per plugin: two racing runs could interleave purge/attach and
    # leave a card without its detail image.
    limits_concurrency to: 1, key: ->(plugin) { "preview_plugin_#{plugin.id}" }

    def perform(plugin)
      plugin.reload
      latest = plugin.active? ? plugin.latest_published_version : nil
      renditions = []
      if latest&.tarball&.attached?
        tarball = TarballInspector.inspect_bytes(latest.tarball.download)
        raise TarballInspector::InvalidTarball, "preview archive checksum mismatch" unless tarball.sha256 == latest.sha256
        renditions = tarball.previews.map { |name, bytes| PreviewImage.process(bytes, name:) }
      end
      replace!(plugin, latest, renditions)
    rescue TarballInspector::InvalidTarball, PreviewImage::InvalidPreview, ActiveStorage::IntegrityError
      # Historic tarball unreadable or preview no longer processable — cosmetic
      # only, never worth failing the job (and never worth keeping a preview
      # that belongs to a different version).
      replace!(plugin, latest, [])
    end

    private

    def replace!(plugin, latest, renditions)
      # Processing is outside the transaction. Publish the complete gallery
      # together, only if it still belongs to the effective latest release.
      plugin.with_lock do
        current = plugin.active? ? plugin.latest_published_version : nil
        if current&.id != latest&.id
          self.class.perform_later(plugin)
          next
        end
        cover, *others = renditions
        plugin.preview_card = attachment(cover[:card], "#{plugin.name}-card.webp") if cover
        plugin.preview_detail = attachment(cover[:detail], "#{plugin.name}-detail.webp") if cover
        plugin.preview_card = plugin.preview_detail = nil unless cover
        plugin.preview_screenshots = others.map do |rendition|
          filename = "#{File.basename(rendition[:meta].fetch('source'), '.*')}-detail.webp"
          rendition[:meta]["detail_file"] = filename
          attachment(rendition[:detail], filename)
        end
        plugin.preview_meta = cover ? cover[:meta].merge("version" => latest.version, "screenshots" => others.map { |r| r[:meta] }) : {}
        plugin.save!
      end
    end

    def attachment(bytes, filename)
      { io: StringIO.new(bytes), filename:, content_type: "image/webp", identify: false, metadata: { analyzed: true } }
    end
  end
end
