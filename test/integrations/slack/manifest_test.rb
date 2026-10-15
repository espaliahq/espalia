# frozen_string_literal: true

require "test_helper"

# The manifest only takes effect when someone pastes it into Slack's app
# settings, so a mistake surfaces there, after merge. Pin what Slack rejects
# and what the code depends on.
class Slack::ManifestTest < ActiveSupport::TestCase
  MANIFEST = YAML.load_file(Rails.root.join("app/integrations/slack/manifest.yml"))

  should "keep every shortcut within Slack's length limits" do
    MANIFEST.dig("features", "shortcuts").each do |shortcut|
      assert_operator shortcut["name"].length, :<=, 24, "Slack rejects a shortcut name over 24 characters: #{shortcut['name']}"
      assert_operator shortcut["description"].length, :<=, 150, "Slack rejects a shortcut description over 150 characters"
    end
  end

  should "declare the message shortcut the interactions controller listens for" do
    callback_ids = MANIFEST.dig("features", "shortcuts").map { |shortcut| shortcut["callback_id"] }
    assert_includes callback_ids, Slack::Feedback::MESSAGE_SHORTCUT
  end

  should "request exactly the scopes the install grants" do
    assert_equal Slack::BOT_SCOPES.sort, MANIFEST.dig("oauth_config", "scopes", "bot").sort
  end
end
