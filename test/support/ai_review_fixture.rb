module AiReviewFixture
  def self.command
    [ RbConfig.ruby, Rails.root.join("test/fixtures/files/ai_pass_adapter.rb").to_s ].shelljoin
  end
end
