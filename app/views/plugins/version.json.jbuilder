# A single version, with the readme extracted from that version's own frozen
# tarball — old versions document themselves as they were.
json.schema_version 1
json.compatibility_assessments @compatibility_assessments.map(&:entry)

json.plugin do
  json.partial! "plugins/plugin", plugin: @plugin
end

json.version do
  json.partial! "plugins/version", version: @version
  json.latest(@latest.present? && @version.version == @latest.version)
  json.summary @version.manifest["description"].presence || @plugin.summary
  json.readme @readme
  if @version.capability_fingerprint.present?
    json.capabilities { json.partial! "plugins/capabilities", version: @version }
  else
    json.capabilities nil
  end
  json.provenance @version.provenance.presence
end

json.notices @notices do |notice|
  json.kind notice.kind
  json.tone notice.tone
  json.title notice.title
  json.body notice.body
end
