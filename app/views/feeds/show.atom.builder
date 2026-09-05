base = DataPlane.base_url

xml.instruct!
xml.feed xmlns: "http://www.w3.org/2005/Atom" do
  xml.title "Omarchy Hub — recent releases"
  xml.id "#{base}/feed.xml"
  xml.link rel: "self", href: "#{base}/feed.xml"
  xml.link rel: "alternate", href: base
  xml.updated((@versions.first&.published_at || Time.current).utc.iso8601)

  @versions.each do |version|
    plugin = version.plugin
    url = "#{base}#{package_path(plugin)}"
    xml.entry do
      xml.id "#{url}#v#{version.version}"
      xml.title "#{plugin.full_name} v#{version.version}"
      xml.link rel: "alternate", href: url
      xml.updated version.published_at.utc.iso8601
      xml.author { xml.name plugin.publisher.name }
      xml.summary plugin.summary.to_s
    end
  end
end
