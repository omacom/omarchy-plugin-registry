module DataPlane
  class Compatibility
    class ContinuityError < StandardError; end
    IDENTITY = %w[id vers sha256 omarchyVersion omarchyBuild].freeze

    def self.write(generator)
      entries = CompatibilityAssessment.includes(:omarchy_release, plugin_version: { plugin: :publisher }).map(&:entry)
      releases = OmarchyRelease.order(:id).map(&:entry)
      verify_continuity!(entries, releases)
      DataPlane.write("compatibility.json", JSON.generate({ "schemaVersion" => 1,
        "releases" => releases, "assessments" => entries }.merge(generator.freshness(24.hours))))
    end

    def self.verify_continuity!(entries, releases)
      DataPlane.heal_interrupted_write!("compatibility.json")
      path = DataPlane.root.join("compatibility.json")
      sig = DataPlane.root.join("compatibility.json.sig")
      return unless path.exist? || sig.exist?
      unless path.exist? && sig.exist? && Signer.verify_any?(path.read, sig.read)
        raise ContinuityError, "compatibility.json does not verify; restore its signed pair"
      end
      previous = JSON.parse(path.read)
      unless previous["schemaVersion"] == 1 && previous["assessments"].is_a?(Array) && previous["releases"].is_a?(Array)
        raise ContinuityError, "malformed compatibility catalog"
      end
      unless (previous["releases"] - releases).empty?
        raise ContinuityError, "surviving Omarchy release contracts differ from database; restore the catalog"
      end
      current = entries.index_by { |entry| entry.values_at(*IDENTITY) }
      previous["assessments"].each do |old|
        next if old.fetch("revision") == 0
        fresh = current[old.values_at(*IDENTITY)]
        unless fresh && fresh["revision"] >= old["revision"] &&
            (fresh["revision"] > old["revision"] || fresh.slice("reason", "status") == old.slice("reason", "status") ||
              (old["status"] != "incompatible" && fresh["reason"] == old["reason"]))
          raise ContinuityError, "compatibility decision missing or older in database; restore its audited revision"
        end
      end
    rescue JSON::ParserError, KeyError, TypeError => e
      raise ContinuityError, "malformed compatibility catalog: #{e.message}"
    end
  end
end
