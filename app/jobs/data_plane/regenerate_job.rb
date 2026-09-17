module DataPlane
  class RegenerateJob < ApplicationJob
    queue_as :critical
    # Release/takedown state must commit before a separate queue DB exposes
    # this work to a worker; otherwise it can sign the previous state.
    self.enqueue_after_transaction_commit = true
    # One regeneration at a time — concurrent regens could interleave files
    # from different generations across the index.
    limits_concurrency to: 1, key: "data_plane_regenerate"

    def perform(plugin = nil)
      plugin ? Regenerate.plugin(plugin) : Regenerate.all
    end
  end
end
