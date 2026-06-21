# frozen_string_literal: true

require "application_system_test_case"

class Tenant::SlackConnectionSystemTest < ApplicationSystemTestCase
  setup do
    # The app server shares this process, so a set ENV makes Slack.configured? true.
    ENV["SLACK_CLIENT_ID"] = "test-client-id"
    ENV["SLACK_CLIENT_SECRET"] = "test-client-secret"

    @tenant = create(:tenant)
    @admin = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @admin, role: :admin) }
    sign_in_as(@admin)
  end

  teardown do
    ENV.delete("SLACK_CLIENT_ID")
    ENV.delete("SLACK_CLIENT_SECRET")
  end

  should "offer Connect Slack when not connected" do
    visit tenant_integrations_path
    assert_text "Slack"
    assert_selector "a", text: "Connect Slack"
  end

  should "let an admin disconnect a connected workspace" do
    @tenant.connect_slack!(bot_token: "xoxb-1", team_id: "T1", team_name: "Acme HQ")

    visit tenant_integrations_path
    assert_text "Connected to Acme HQ"

    # Retry the whole block: on a starved CI runner auto_confirm's window.confirm
    # stub can miss the click and a native dialog surfaces (UnexpectedAlertOpenError).
    click_with_retry(expect_text: "Connect Slack") do
      auto_confirm { find("a", text: "Disconnect").click }
    end
    assert_selector "a", text: "Connect Slack"
    assert_not @tenant.reload.slack_connected?
  end
end
