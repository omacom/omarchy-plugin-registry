module Registry
  # Releases a version once its hold window has passed — unless review or an
  # admin changed its state in the meantime.
  class ReleaseJob < ApplicationJob
    queue_as :critical
    self.enqueue_after_transaction_commit = true
    discard_on ActiveJob::DeserializationError

    def perform(version)
      version.with_lock do
        return unless version.held?
        return if version.hold_until&.future?
        begin
          ReleaseVersion.call(version)
        rescue ArgumentError => e
          # Refusal and state transition use the same snapshot/lock too.
          version.update!(state: :quarantined, hold_until: nil, review_notes: "release blocked: #{e.message}")
          AuditEvent.record!(action: "version.release_blocked", subject: version,
            metadata: { plugin: version.plugin.full_name, version: version.version, reason: e.message })
        end
      end
    end
  end
end
