module Registry
  # Tool-less review. A complete pass is required for automatic publication;
  # it cannot override deterministic findings. Output is data, never a command.
  class AiReview
    TIMEOUT_SECONDS = 900
    MAX_OUTPUT_BYTES = 1.megabyte

    Result = Struct.new(:verdict, :reasons, :coverage, :model, :reviewer_version) do
      def flagged? = verdict == "flag"
    end

    def self.enabled? = Rails.application.config.x.ai_review_command.present?

    def self.review(version:, tarball:, fingerprint:, scan_findings:, previous: nil, capability_growth: [], changed_files: [], previous_contents: {})
      return Result.new("skipped", [ "ai review disabled" ]) unless enabled?

      assets = Scanner.new(tarball).verified_assets
      incomplete = tarball.truncated + tarball.contents.filter_map do |path, content|
        path unless content.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      end
      incomplete -= assets
      if incomplete.any?
        return Result.new("flag", [ "incomplete source coverage: #{incomplete.first(10).join(', ')}" ], { "complete" => false })
      end
      payload = {
        plugin: version.plugin.full_name, version: version.version, sha256: tarball.sha256,
        manifest: tarball.manifest, fingerprint: fingerprint, scan_findings: scan_findings,
        previous: previous && { version: previous.version, fingerprint: previous.capability_fingerprint },
        changed_files:, previous_contents:, previous_contents_partial: previous.present?, capability_growth:,
        verified_assets: assets, incomplete_files: incomplete, sizes: tarball.sizes, digests: tarball.digests,
        files: tarball.contents.to_h { |path, content| [ path, assets.include?(path) ? "" : content.dup.force_encoding(Encoding::UTF_8) ] }
      }
      command = Rails.application.config.x.ai_review_command
      if Rails.env.production?
        unless command == Rails.root.join("script/ai_review_adapter").to_s
          raise ArgumentError, "production requires the bundled isolated adapter"
        end
        output = ProcessorSandbox.call(:ai, payload.to_json, timeout: TIMEOUT_SECONDS, max_output_bytes: MAX_OUTPUT_BYTES)
      else
        output = UntrustedProcess.call(command, payload.to_json, timeout: TIMEOUT_SECONDS, max_output_bytes: MAX_OUTPUT_BYTES)
      end
      parsed = JSON.parse(output)
      verdict = AiReviewer.parse_verdict(JSON.generate(parsed.slice("verdict", "reasons")))
      coverage = parsed["coverage"]
      if verdict["verdict"] == "pass" &&
          !(complete_coverage?(coverage, tarball.sha256, parsed["reviewer_version"]) &&
            coverage["source_files"] == tarball.contents.size - assets.size && coverage["asset_files"] == assets.size)
        return Result.new("flag", [ "AI reviewer did not attest complete coverage of this archive" ], coverage)
      end
      Result.new(verdict["verdict"], verdict["reasons"], coverage, parsed["model"].to_s.first(200), parsed["reviewer_version"])
    rescue StandardError => e
      Result.new("flag", [ "ai review unavailable (#{e.class})" ], { "complete" => false })
    end
    def self.complete_coverage?(coverage, sha256, reviewer_version)
      coverage.is_a?(Hash) && coverage["complete"] == true && coverage["archive_sha256"] == sha256 &&
        reviewer_version == AiReviewer::VERSION && coverage["chunks"].is_a?(Integer) && coverage["chunks"].positive? &&
        coverage["passes"].is_a?(Array) && coverage["passes"].map { |pass| pass.is_a?(Hash) && pass["id"] } == AiReviewer::PASSES &&
        coverage["passes"].all? { |pass| pass["verdict"] == "pass" && pass["chunks_completed"] == coverage["chunks"] && pass["chunks_total"] == coverage["chunks"] }
    end
  end
end
