# frozen_string_literal: true

require "test_helper"

class FeedbackExchange::TextFormatTest < ActiveSupport::TestCase
  FIXTURES = Rails.root.join("test/fixtures/files/feedback_exchange")

  context "shared fixtures" do
    Dir[FIXTURES.join("*.txt")].sort.each do |path|
      name, format = File.basename(path, ".txt").split(".")

      should "convert #{name} (#{format})" do
        expected = File.read(FIXTURES.join("#{name}.md"))
        assert_equal expected, FeedbackExchange::TextFormat.to_markdown(File.read(path), format: format)
      end
    end
  end

  context "slack mentions" do
    setup do
      @tenant = create(:tenant)
      ActsAsTenant.current_tenant = @tenant
      person = create(:person, tenant: @tenant, name: "Priya Nair")
      create(:tenant_user, tenant: @tenant, person: person, slack_user_id: "U0PRIYA")
    end

    teardown { ActsAsTenant.current_tenant = nil }

    should "name a person this tenant knows by their Slack id" do
      assert_equal "Thanks Priya Nair for the review",
        FeedbackExchange::TextFormat.to_markdown("Thanks <@U0PRIYA> for the review", format: "slack")
    end

    should "fall back to @someone for an id nobody here holds" do
      assert_equal "Thanks @someone", FeedbackExchange::TextFormat.to_markdown("Thanks <@U0ELSE>", format: "slack")
    end
  end

  should "render what it produces as the same words through Prose" do
    markdown = FeedbackExchange::TextFormat.to_markdown("*Great* work on <https://x.io/rfc|the RFC>", format: "slack")
    assert_equal "Great work on the RFC (https://x.io/rfc)", Prose.to_plain(markdown)
  end

  should "treat an unknown format as plain" do
    assert_equal "a \\*b\\*", FeedbackExchange::TextFormat.to_markdown("a *b*", format: "html")
  end

  should "return an empty string for nil" do
    assert_equal "", FeedbackExchange::TextFormat.to_markdown(nil, format: "slack")
  end
end
