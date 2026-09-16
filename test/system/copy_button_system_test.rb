require "application_system_test_case"

# The copy affordance runs real JavaScript (Clipboard API with a selection
# fallback) — proven in a real headless Chrome, not stubbed.
class CopyButtonSystemTest < ApplicationSystemTestCase
  test "directory commands copy the selected package type" do
    [ [ root_path, "plugin" ], [ themes_path, "theme" ] ].each do |path, type|
      visit path
      page.driver.browser.execute_cdp("Browser.grantPermissions", origin: page.current_url,
        permissions: [ "clipboardReadWrite", "clipboardSanitizedWrite" ])
      within(".hero__install") do
        find("button.copy-button").click
        assert_selector "button.copy-button--done"
      end
      copied = page.evaluate_async_script("navigator.clipboard.readText().then(arguments[0])")
      assert_equal "omarchy #{type} add publisher/name", copied
    end
  end

  test "install command copies and confirms" do
    dev = User.create!(email_address: "dev@example.com", name: "Dev",
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    publisher = Publisher.create!(name: "acme", kind: :org)
    Membership.create!(publisher:, user: dev, role: :owner, founding: true)
    perform_enqueued_jobs do
      Registry::PublishVersion.new(user: dev, publisher:, plugin_name: "weather",
        tarball_bytes: TarballBuilder.build).call
    end

    visit plugin_path("acme", "weather")
    within(".install-strip") do
      assert_text "omarchy plugin add acme/weather"
      find("button.copy-button").click
      assert_selector "button.copy-button--done"
    end
  end

  test "readme code blocks get an injected copy control" do
    dev = User.create!(email_address: "dev2@example.com", name: "Dev",
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    publisher = Publisher.create!(name: "bcme", kind: :org)
    Membership.create!(publisher:, user: dev, role: :owner, founding: true)
    readme = "# Widget

Great widget.

## Config

```
widget --set theme=tokyo-night
```
"
    perform_enqueued_jobs do
      Registry::PublishVersion.new(user: dev, publisher:, plugin_name: "widget",
        tarball_bytes: TarballBuilder.build(
          manifest: TarballBuilder.manifest(id: "bcme.widget"),
          files: { "Widget.qml" => "import QtQuick
Item {}
", "README.md" => readme }
        )).call
    end

    visit plugin_path("bcme", "widget")
    within(".readme .codeblock") do
      find("button.copy-button--floating").click
      assert_selector "button.copy-button--done"
    end
  end
end
