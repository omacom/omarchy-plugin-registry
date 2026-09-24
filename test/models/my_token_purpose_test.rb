require "test_helper"

class MyTokenPurposeTest < ActiveSupport::TestCase
  setup do
    @user = create_my_user
    @publisher = Publisher.create!(name: "acme", kind: :org)
    Membership.create!(publisher: @publisher, user: @user, role: :owner, founding: true)
  end

  test "account tokens carry the oma_ prefix, a 90-day life, and no publish scope" do
    token = ApiToken.mint!(user: @user, purpose: :account, device_name: "xps-14")
    assert token.plaintext_token.start_with?("oma_")
    assert token.purpose_account?
    assert_in_delta 90.days.from_now, token.expires_at, 5
    assert_equal "xps-14", token.device_name
    assert_not token.authorizes?(@publisher, "weather")
    assert_match(/my\.omarchy\.org/, token.scope_label)
  end

  test "authentication is purpose-bound in both directions" do
    account = ApiToken.mint!(user: @user, purpose: :account)
    publish = ApiToken.mint!(user: @user)
    assert_nil ApiToken.authenticate(account.plaintext_token)                  # default = publish
    assert_nil ApiToken.authenticate(account.plaintext_token, purpose: :publish)
    assert_equal account, ApiToken.authenticate(account.plaintext_token, purpose: :account)
    assert_nil ApiToken.authenticate(publish.plaintext_token, purpose: :account)
    assert_equal publish, ApiToken.authenticate(publish.plaintext_token)
  end

  test "an account token refuses a publish scope" do
    assert_raises(ActiveRecord::RecordInvalid) do
      ApiToken.mint!(user: @user, purpose: :account, publisher: @publisher)
    end
  end

  test "device names are hostnames or nothing" do
    assert_nil ApiToken.mint!(user: @user, purpose: :account, device_name: "<script>").device_name
    assert_nil ApiToken.mint!(user: @user, purpose: :account, device_name: "a" * 80).device_name
    assert_equal "my-box.local", ApiToken.mint!(user: @user, purpose: :account, device_name: " my-box.local ").device_name
  end

  test "device quota is separate from the publish-token quota" do
    ApiToken::MAX_ACCOUNT_TOKENS_PER_USER.times { ApiToken.mint!(user: @user, purpose: :account) }
    assert_raises(ActiveRecord::RecordInvalid) { ApiToken.mint!(user: @user, purpose: :account) }
    assert ApiToken.mint!(user: @user).persisted?, "publish tokens still mint"
  end

  test "publish-token quota ignores account tokens" do
    3.times { ApiToken.mint!(user: @user, purpose: :account) }
    ApiToken::MAX_USABLE_PER_USER.times { ApiToken.mint!(user: @user) }
    assert_raises(ActiveRecord::RecordInvalid) { ApiToken.mint!(user: @user) }
  end
end
