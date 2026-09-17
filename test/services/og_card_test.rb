require "test_helper"
require "vips"

class OgCardTest < ActiveSupport::TestCase
  test "site card renders a PNG through the standalone processor" do
    bytes = Registry::OgCard.site(plugins: 12, publishers: 3, downloads: 1000)
    card = Vips::Image.new_from_buffer(bytes, "")
    assert_equal [ 1200, 630 ], [ card.width, card.height ]
  end

  test "plugin display text and an attached preview remain data during rendering" do
    publisher = Publisher.create!(name: "cardtest", kind: :org)
    plugin = publisher.plugins.create!(name: "weather", summary: "Weather & forecasts <daily>", kinds: [ "bar-widget" ])
    preview = Vips::Image.black(100, 100).webpsave_buffer
    plugin.preview_card.attach(io: StringIO.new(preview), filename: "card.webp", content_type: "image/webp")
    plugin.update!(preview_meta: { "card" => { "width" => 100, "height" => 100 } })
    bytes = Registry::OgCard.plugin(plugin)
    assert_equal "pngload_buffer", Vips::Image.new_from_buffer(bytes, "").get("vips-loader")
    plugin.preview_card.blob.analyze
    assert_not plugin.preview_card.blob.metadata.key?("width"), "Rails must not run its own native image analyzer"
  end
end
