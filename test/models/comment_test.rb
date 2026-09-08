require "test_helper"

class CommentTest < ActiveSupport::TestCase
  test "legacy control characters do not prevent moderation" do
    publisher = Publisher.create!(name: "comment-test-publisher", kind: :org)
    plugin = Plugin.create!(publisher:, name: "comment-test-plugin", summary: "Plugin for comment tests")
    user = User.create!(email_address: "comment-test@example.com", name: "Comment Tester")
    comment = Comment.create!(plugin:, user:, body: "A valid comment")
    comment.update_columns(body: "legacy\u0085comment")

    assert_changes -> { comment.reload.hidden_at }, from: nil do
      comment.hide!(actor: user)
    end
    assert Comment.find(comment.id).hidden_at.present?
  end
end
