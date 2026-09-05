# The directory a native browser lists from. Same query parameters as the web
# page (q, sort, category, tag, page) — including the typed search operators
# (@publisher, tag:, kind:, category:) — so the two surfaces can never disagree
# about what a search returns.
json.schema_version 1

json.query do
  json.q @query
  json.sort @sort
  json.category @category
  json.tag @tag
  json.package_type @package_type
end

json.page do
  json.number @page
  json.per_page @per_page
  json.total @total
  json.more @more
end

json.stats @stats

# The curated browse vocabulary. Published here so a client can render facet
# chips without hardcoding a copy that drifts when governance adds a category.
json.taxonomy do
  json.sorts HomeController::SORTS.keys
  json.categories Registry::Taxonomy::CATEGORIES do |slug|
    json.slug slug
    json.label Registry::Taxonomy.label(slug)
    json.count @category_counts.fetch(slug, 0)
  end
  json.tags Registry::Taxonomy::TAGS
  json.max_tags Registry::Taxonomy::MAX_TAGS
  json.package_types Plugin::PACKAGE_TYPES
end

json.packages @plugins do |plugin|
  json.partial! "plugins/plugin", plugin: plugin
end

json.plugins @plugins.reject(&:theme?) do |plugin|
  json.partial! "plugins/plugin", plugin: plugin
end

json.themes @plugins.select(&:theme?) do |plugin|
  json.partial! "plugins/plugin", plugin: plugin
end

# The "new this fortnight" strip and the popular shelf, present only on the
# unfiltered first page — same rule as the web directory.
json.recent(@recent || []) do |plugin|
  json.partial! "plugins/plugin", plugin: plugin
end

json.popular(@popular || []) do |plugin|
  json.partial! "plugins/plugin", plugin: plugin
end
