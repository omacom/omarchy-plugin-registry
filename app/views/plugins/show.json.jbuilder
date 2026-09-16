# The plugin detail a native browser renders. Everything the web page shows,
# minus the chrome. Install-critical resolution still happens against the
# signed data plane (/index/<publisher>/<name>.json) — this payload is the
# human layer, and a client must not install from it.
json.schema_version 1

json.plugin do
  json.partial! "plugins/plugin", plugin: @plugin

  json.readme @plugin.readme

  json.notices @notices do |notice|
    json.kind notice.kind
    json.tone notice.tone
    json.title notice.title
    json.body notice.body
  end

  if @latest
    json.latest do
      json.partial! "plugins/version", version: @latest
      if @latest.capability_fingerprint.present?
        json.capabilities { json.partial! "plugins/capabilities", version: @latest }
      else
        json.capabilities nil
      end
      json.provenance @latest.provenance.presence
      json.compatibility_assessments @compatibility_entries
    end
  else
    json.latest nil
  end

  # Members and admins additionally see versions still in the pipeline; the
  # public list is published + yanked, exactly as on the page.
  json.versions @versions do |version|
    json.partial! "plugins/version", version: version
  end

  json.comments @comments do |comment|
    json.id comment.id
    json.body comment.body
    json.created_at comment.created_at
    if (report = comment.compatibility_report)
      assessment = report.compatibility_assessment
      json.compatibility do
        json.outcome report.outcome
        json.modified report.modified
        json.package_version assessment.plugin_version.version
        json.omarchy_version assessment.omarchy_release.version
        json.omarchy_build assessment.omarchy_release.build
        json.url absolute_url(compatibility_path(assessment))
      end
    end
    json.author do
      json.name comment.user.name
      json.publisher_member @publisher_member_ids.include?(comment.user_id)
    end
  end
end

json.publisher do
  json.partial! "publishers/publisher", publisher: @publisher
end

if authenticated?
  json.viewer do
    json.rating @my_rating&.value
    json.privileged @privileged
  end
end
