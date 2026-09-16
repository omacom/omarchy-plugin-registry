module CompatibilityHelper
  def compatibility_bounds(version)
    contract = version.manifest["compatibility"] || {}
    [ contract["minOmarchyVersion"] || version.manifest["minOmarchyVersion"], contract["maxOmarchyVersionExclusive"] ]
  end

  def compatibility_requirements(version)
    minimum, maximum = compatibility_bounds(version)
    if minimum && maximum
      "Omarchy #{minimum} up to, but not including, #{maximum}"
    elsif minimum
      "Omarchy #{minimum} and newer"
    elsif maximum
      "Omarchy earlier than #{maximum}"
    else
      "No supported Omarchy versions declared."
    end
  end

  def outside_compatibility_range?(version, release)
    minimum, maximum = compatibility_bounds(version)
    current = Semver.parse(release.version)
    (minimum && current < Semver.parse(minimum)) || (maximum && current >= Semver.parse(maximum))
  end

  def compatibility_evidence_label(assessment, counts:)
    return "No reports yet" unless assessment
    return "Confirmed incompatible" if assessment.status(counts) == "incompatible"
    return "Compatibility warning" if assessment.status(counts) == "suspected"
    parts = []
    parts << "#{pluralize(counts.fetch('works', 0), 'working report')}" if counts.fetch("works", 0).positive?
    parts << "#{pluralize(counts.fetch('problem', 0), 'problem report')}" if counts.fetch("problem", 0).positive?
    parts.presence&.join(" · ") || "No user reports yet"
  end
end
