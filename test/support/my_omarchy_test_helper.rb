# Shared setup for the My Omarchy suites: an onboarded user with a second
# factor, an account token for a named device, and header helpers.
module MyOmarchyTestHelper
  def create_my_user(email: "me@example.com", name: "Me", handle: "me")
    user = User.create!(email_address: email, name: name, verified_at: Time.current,
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    publisher = Publisher.create!(name: handle, kind: :personal)
    Membership.create!(publisher:, user:, role: :owner, founding: true)
    user
  end

  def account_token_for(user, device: "xps-14")
    ApiToken.mint!(user: user, purpose: :account, device_name: device)
  end

  def bearer(token, extra = {})
    { "Authorization" => "Bearer #{token.plaintext_token}" }.merge(extra)
  end

  def dotfile_bundle_bytes(files = { ".config/omarchy/shell.json" => "{}\n", ".config/hypr/bindings.lua" => "-- keys\n" })
    TarballBuilder.build(manifest: nil, files: files)
  end

  def with_fake_open_router(fake = FakeOpenRouter.new)
    previous = Rails.application.config.x.open_router_client
    Rails.application.config.x.open_router_client = fake
    yield fake
  ensure
    Rails.application.config.x.open_router_client = previous
  end
end

ActiveSupport.on_load(:action_dispatch_integration_test) { include MyOmarchyTestHelper }
ActiveSupport.on_load(:active_support_test_case) { include MyOmarchyTestHelper }
