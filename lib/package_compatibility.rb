# Bounded version requirements, deliberately not a general semver DSL.
module PackageCompatibility
  KEYS = %w[minOmarchyVersion maxOmarchyVersionExclusive apiVersion].freeze

  def self.errors(manifest)
    return [] unless manifest.key?("compatibility")
    contract = manifest["compatibility"]
    return [ "compatibility must be an object" ] unless contract.is_a?(Hash)
    errors = []
    errors << "unknown compatibility fields" if (contract.keys - KEYS).any?
    api = contract["apiVersion"]
    errors << "compatibility.apiVersion must be an integer from 1 to 10000" unless api.is_a?(Integer) && (1..10000).cover?(api)
    KEYS.first(2).each do |key|
      errors << "compatibility.#{key} must be strict semver" if contract.key?(key) && !Semver.valid?(contract[key])
    end
    minimum = contract["minOmarchyVersion"] || manifest["minOmarchyVersion"]
    maximum = contract["maxOmarchyVersionExclusive"]
    if Semver.valid?(minimum) && Semver.valid?(maximum) && Semver.parse(minimum) >= Semver.parse(maximum)
      errors << "compatibility maximum must be greater than minimum"
    end
    if manifest["minOmarchyVersion"] && contract["minOmarchyVersion"] && manifest["minOmarchyVersion"] != contract["minOmarchyVersion"]
      errors << "minOmarchyVersion declarations must agree"
    end
    errors
  end
end
