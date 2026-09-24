require "test_helper"

class My::VoiceTest < ActionDispatch::IntegrationTest
  setup do
    @user = create_my_user
    @token = account_token_for(@user, device: "framework")
  end

  test "disabled without a management key: pages say so, API says 501" do
    with_fake_open_router(nil) do
      get "/api/v1/my/voice", headers: bearer(@token)
      assert_response :not_implemented
      post "/api/v1/my/voice", headers: bearer(@token)
      assert_response :not_implemented
      sign_in_as @user
      get my_voice_path
      assert_response :success
      assert_match "isn't enabled", response.body
    end
  end

  test "mint in the browser, fetch from a machine, rotate, revoke" do
    with_fake_open_router do |fake|
      sign_in_as @user
      get my_voice_path
      assert_match "No voice key", response.body

      post my_voice_path
      assert_redirected_to my_voice_path
      follow_redirect!
      assert_match "sk-or-v1-", response.body, "secret shown once"
      key = @user.reload.voice_key
      assert key.active?
      create = fake.calls.find { |c| c.first == :create }.last
      assert_equal MyOmarchy.voice_monthly_limit_usd, create[:limit_usd]
      assert_equal "monthly", create[:limit_reset]
      assert_in_delta MyOmarchy.voice_key_ttl.from_now, create[:expires_at], 5
      assert_equal "voice_key.mint", AuditEvent.where(subject: key).last.action

      get my_voice_path
      assert_no_match key.secret, response.body, "secret is not re-shown on the page"
      assert_match key.label, response.body

      # A machine fetches the same key with the voxtype wiring
      get "/api/v1/my/voice", headers: bearer(@token)
      assert_response :success
      voice = response.parsed_body["voice"]
      assert_equal key.secret, voice["api_key"]
      assert_equal "remote", voice.dig("voxtype", "backend")
      assert_equal "https://openrouter.ai/api", voice.dig("voxtype", "remote_endpoint")
      assert_equal MyOmarchy.voice_model, voice["model"]

      # Rotation: the old key is deleted at the provider first
      old_hash = key.provider_hash
      post "/api/v1/my/voice", headers: bearer(@token, "X-Omarchy-Device" => "desktop")
      assert_response :created
      assert_not_equal key.secret, response.parsed_body.dig("voice", "api_key")
      assert_includes fake.calls, [ :delete, old_hash ]
      assert_equal 1, @user.voice_keys.active.count
      assert_nil key.reload.secret, "revoked secrets are wiped"
      assert_equal "desktop", @user.voice_key.device_name

      # Usage shows up on the page after a sync
      fake.spend!(@user.voice_key.provider_hash, monthly: 4.25)
      get my_voice_path
      assert_match "$4.25", response.body

      delete "/api/v1/my/voice", headers: bearer(@token)
      assert_response :no_content
      assert_nil @user.reload.voice_key
      get "/api/v1/my/voice", headers: bearer(@token)
      assert_nil response.parsed_body["voice"]
    end
  end

  test "minting needs a fresh second factor and a verified mailbox" do
    with_fake_open_router do |fake|
      sign_in_as @user, second_factor_verified: false
      post my_voice_path
      assert_redirected_to step_up_path
      assert_empty fake.calls

      @user.update!(verified_at: nil)
      post "/api/v1/my/voice", headers: bearer(@token)
      assert_response :forbidden
      assert_match(/verify your email/, response.parsed_body["error"])
      assert_empty fake.calls
    end
  end

  test "a provider failure mints nothing" do
    with_fake_open_router(FakeOpenRouter.new(fail_with: MyOmarchy::OpenRouter::Unavailable.new("down"))) do
      post "/api/v1/my/voice", headers: bearer(@token)
      assert_response :bad_gateway
      assert_equal 0, VoiceKey.count
      sign_in_as @user
      post my_voice_path
      assert_redirected_to my_voice_path
      assert_match(/unavailable/, flash[:alert])
    end
  end

  test "global capacity bounds the operator's liability" do
    with_fake_open_router do
      Rails.application.config.x.voice_max_active_keys = 1
      other = create_my_user(email: "o@example.com", handle: "o")
      MyOmarchy::VoiceKeys.mint!(user: other)
      post "/api/v1/my/voice", headers: bearer(@token)
      assert_response :forbidden
      assert_match(/capacity/, response.parsed_body["error"])
    ensure
      Rails.application.config.x.voice_max_active_keys = 2000
    end
  end

  test "suspension pulls the key at the provider" do
    with_fake_open_router do |fake|
      key = MyOmarchy::VoiceKeys.mint!(user: @user)
      admin = User.create!(email_address: "admin@example.com", name: "Admin", admin: true,
        otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
      sign_in_as admin
      post admin_suspend_user_path, params: { email_address: @user.email_address, reason: "abuse" }
      assert_includes fake.calls, [ :delete, key.provider_hash ]
      assert_not key.reload.active?
    end
  end

  test "the sweep finishes provider deletes and refreshes spend" do
    with_fake_open_router do |fake|
      live = MyOmarchy::VoiceKeys.mint!(user: @user)
      stale = create_my_user(email: "sweep@example.com", handle: "sweep").voice_keys.create!(
        provider: "openrouter", provider_hash: "f" * 64, secret: "x", monthly_limit_usd: 5,
        expires_at: 1.day.ago)
      fake.keys["f" * 64] = MyOmarchy::OpenRouter::Key.new(hash: "f" * 64, usage: 0, usage_monthly: 0)
      fake.spend!(live.provider_hash, monthly: 1.5)
      MyOmarchy::VoiceKeySweepJob.perform_now
      assert_equal 1.5, live.reload.usage_monthly_usd.to_f
      assert stale.reload.provider_deleted_at
      assert_nil stale.secret
      assert_includes fake.calls, [ :delete, "f" * 64 ]
    end
  end
end
