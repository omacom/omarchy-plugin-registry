json.schema_version 1

json.publisher do
  json.partial! "publishers/publisher", publisher: @publisher
  json.plugin_count @plugins.count { |package| !package.theme? }
  json.theme_count @plugins.count(&:theme?)
end

json.plugins @plugins.reject(&:theme?) do |plugin|
  json.partial! "plugins/plugin", plugin: plugin
end

json.themes @plugins.select(&:theme?) do |plugin|
  json.partial! "plugins/plugin", plugin: plugin
end
