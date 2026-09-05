module Registry
  # Operator-imported evidence from disposable runners. This process NEVER
  # runs candidate Omarchy or package code. Checks can warn, never hard-block.
  class RecordCompatibilityChecks
    SCOPES = %w[theme-configs-v1 plugin-manifest-v1 desktop-activation-v1].freeze

    def self.call(actor:, document:)
      raise ActiveRecord::RecordNotFound unless actor.admin? && actor.suspended_at.nil?
      raise ArgumentError, "Evidence is limited to 100KB" unless document.is_a?(String) && document.bytesize <= 100_000
      payload = JSON.parse(document)
      unless payload.is_a?(Hash) && payload["schemaVersion"] == 1 && payload["target"].is_a?(Hash) &&
          payload["checks"].is_a?(Array) && payload["checks"].size.between?(1, 100) &&
          payload["runner"].is_a?(String) && payload["runner"].length.between?(1, 200)
        raise ArgumentError, "Invalid compatibility evidence envelope"
      end
      target = payload["target"]
      release = OmarchyRelease.find_by!(version: target["version"], build: target["build"])
      raise ArgumentError, "Runner APIs differ from the registered release" unless target["apis"] == release.apis
      CompatibilityAssessment.transaction do
        payload["checks"].each do |check|
          unless check.is_a?(Hash) && SCOPES.include?(check["scope"]) && %w[passed failed inconclusive].include?(check["status"]) &&
              (check.keys - %w[id vers sha256 packageType scope status summary]).empty? &&
              check["summary"].is_a?(String) && check["summary"].length.between?(1, 600)
            raise ArgumentError, "Invalid check scope, result or summary"
          end
          publisher, name = check["id"].to_s.split(".", 2)
          version = PluginVersion.joins(plugin: :publisher).where(state: [ :published, :yanked ])
            .find_by!(version: check["vers"], sha256: check["sha256"], publishers: { name: publisher },
              plugins: { name: name, package_type: check["packageType"] })
          assessment = version.compatibility_assessments.find_or_create_by!(omarchy_release: release)
          evidence = assessment.check_evidence.present? ? JSON.parse(assessment.check_evidence) : {}
          current = evidence[check["scope"]]
          # An infrastructure failure must not erase a reproducible failure.
          unless current && current["status"] == "failed" && check["status"] == "inconclusive"
            evidence[check["scope"]] = check.slice("status", "summary").merge("runner" => payload["runner"])
          end
          results = evidence.values.pluck("status")
          result = results.include?("failed") ? "failed" : (results.all?("passed") ? "passed" : "inconclusive")
          assessment.update!(check_result: result, check_evidence: JSON.generate(evidence))
          AuditEvent.record!(actor:, action: "compatibility.check", subject: assessment, public: true,
            metadata: check.slice("id", "vers", "sha256", "packageType", "scope", "status", "summary")
              .merge("omarchyVersion" => release.version, "omarchyBuild" => release.build, "runner" => payload["runner"]))
        end
      end
      DataPlane::RegenerateJob.perform_later
      CompatibilityAlertsJob.perform_later
    end
  end
end
