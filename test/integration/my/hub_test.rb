require "test_helper"

# The web hub: hostname routing, sign-in gating, the overview and devices
# pages, and the shared header.
class My::HubTest < ActionDispatch::IntegrationTest
  setup { @user = create_my_user }

  test "the My hostname answers the hub at its root; the registry host keeps the directory" do
    get "http://my.test/"
    assert_response :success
    assert_match "things that should follow you", response.body

    get "http://registry.test/"
    assert_response :success
    assert_no_match "things that should follow you", response.body

    get "http://registry.test/my"
    assert_response :success
    assert_match "things that should follow you", response.body
  end

  test "signed in, the hub shows devices, dotfiles, snaps, and voice at a glance" do
    token = account_token_for(@user, device: "xps-14")
    token.touch(:last_used_at)
    sign_in_as @user
    get my_root_path
    assert_response :success
    assert_match "Hey, Me", response.body
    assert_match "xps-14", response.body
    assert_match "1 machine connected", response.body
    # One scrolling page: a showcase band per feature, no sub-navigation
    assert_select "section.showcase[aria-label='Snaps']"
    assert_select "section.showcase[aria-label='Dotfiles']"
    assert_select "section.showcase[aria-label='Devices']"
    assert_select "section.showcase[aria-label='Voice']"
    assert_select "nav[aria-label='My Omarchy']", count: 0
    assert_match "no-store", response.headers["Cache-Control"]
  end

  test "an un-onboarded account is sent through onboarding first" do
    fresh = User.create!(email_address: "fresh@example.com")
    sign_in_as fresh
    get my_root_path
    assert_redirected_to onboarding_path
    get my_devices_path
    assert_redirected_to onboarding_path
  end

  test "signed-out visitors are sent to sign in for account pages" do
    get my_devices_path
    assert_redirected_to new_session_path
    get my_setup_path
    assert_response :success
  end

  test "devices: list and disconnect (step-up gated)" do
    token = account_token_for(@user, device: "xps-14")
    sign_in_as @user, second_factor_verified: false
    get my_devices_path
    assert_response :success
    assert_match "xps-14", response.body
    delete my_device_path(token)
    assert_redirected_to step_up_path
    assert token.reload.usable?

    sign_in_as @user
    delete my_device_path(token)
    assert_redirected_to my_devices_path
    assert_not token.reload.usable?
    assert_equal "device.disconnect", AuditEvent.where(subject: token).last.action
  end

  test "the publishing dashboard no longer lists devices as publish tokens" do
    account_token_for(@user, device: "xps-14")
    publish = ApiToken.mint!(user: @user)
    sign_in_as @user
    get dashboard_path
    assert_match publish.token_hint, response.body
    assert_no_match "xps-14", response.body
  end

  # Integration cookie jars are bound to the first host used, so each host
  # gets its own test.
  test "the registry header links across to My Omarchy" do
    host! "registry.test"
    sign_in_as @user
    get "/dashboard"
    assert_response :success
    assert_select "a.omarchy-auth[href='http://my.test/']", text: "My Omarchy"
    assert_select "nav.omarchy-nav a[aria-current='page']", text: "Plugins"
  end

  test "the My header marks itself current and links back to publishing" do
    host! "my.test"
    sign_in_as @user
    get "/"
    assert_response :success
    assert_select "a.omarchy-auth[href='/'][aria-current='page']", text: "My Omarchy"
    assert_select "a.omarchy-auth[href='/dashboard']", text: "Publishing"
    assert_select "nav.omarchy-nav a[aria-current='page']", count: 0
  end

  test "passkey origins include both hosts" do
    assert_includes WebAuthn.configuration.allowed_origins, "http://my.test"
    assert_includes WebAuthn.configuration.allowed_origins, "http://registry.test"
  end
end
