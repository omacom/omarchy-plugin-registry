require "test_helper"

# Round 47: the cookie session resets at authentication boundaries and
# enrollment material is account-bound; deferred kinds are refused honestly.
class MomusRoundFortySevenTest < ActionDispatch::IntegrationTest
  test "a provisional TOTP secret recorded by user A can never enroll for user B" do
    a = User.create!(email_address: "a@example.com", name: "A", verified_at: Time.current)
    b = User.create!(email_address: "b@example.com", name: "B", verified_at: Time.current)

    sign_in_as a, second_factor_verified: false
    get settings_two_factor_path
    recorded = response.body[/Or enter the secret manually: <code>([A-Z2-7]+)<\/code>/, 1]
    assert recorded.present?
    sign_out

    # Same browser, next occupant — binding + boundary reset both stand guard
    sign_in_as b, second_factor_verified: false
    patch settings_two_factor_path, params: { code: ROTP::TOTP.new(recorded).now }
    assert_nil b.reload.otp_secret, "user A's recorded secret must be useless for user B"
    assert_not b.otp_enabled?
  end

  test "signing in through the login flow resets prior session state" do
    a = User.create!(email_address: "a2@example.com", name: "A", verified_at: Time.current)
    sign_in_as a, second_factor_verified: false
    get settings_two_factor_path
    recorded = response.body[/Or enter the secret manually: <code>([A-Z2-7]+)<\/code>/, 1]
    sign_out

    b = User.create!(email_address: "b2@example.com", name: "B", verified_at: Time.current)
    publisher = Publisher.create!(name: "bco", kind: :personal)
    Membership.create!(publisher:, user: b, role: :owner, founding: true)
    post session_path, params: { email_address: b.email_address }
    post authenticate_session_path, params: { code: emailed_login_code }

    # B's fresh enrollment page provisions its own secret, never A's leftovers
    get settings_two_factor_path
    fresh = response.body[/Or enter the secret manually: <code>([A-Z2-7]+)<\/code>/, 1]
    assert_not_equal recorded, fresh
  end

  test "a theme kind without the explicit theme package type is refused" do
    dev = User.create!(email_address: "dev@example.com", name: "Dev",
      otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    publisher = Publisher.create!(name: "acme", kind: :org)
    Membership.create!(publisher:, user: dev, role: :owner, founding: true)

    error = assert_raises(Registry::PublishVersion::PublishError) do
      Registry::PublishVersion.new(user: dev, publisher:, plugin_name: "nightfall",
        tarball_bytes: TarballBuilder.build(
          manifest: TarballBuilder.manifest(id: "acme.nightfall", kinds: [ "theme" ],
            entryPoints: { "theme" => "theme.json" }),
          files: { "theme.json" => "{}" }
        )).call
    end
    assert_match(/unknown kinds: theme/, error.message)
  end
end
