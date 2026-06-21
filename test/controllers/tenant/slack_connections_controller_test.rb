# frozen_string_literal: true

require "test_helper"

class Tenant::SlackConnectionsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @admin = create(:user, password: "password123")
    @member = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member, role: :member)
    end
  end

  def with_slack_configured(&)
    Slack.stub(:configured?, true) do
      Slack.stub(:oauth_config, { client_id: "cid", client_secret: "secret", signing_secret: "sign" }, &)
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin }

    context "GET install" do
      should "redirect to Slack consent and store a state" do
        with_slack_configured do
          get tenant_slack_install_path
        end
        assert_response :redirect
        assert_match %r{\Ahttps://slack\.com/oauth/v2/authorize}, response.location
        assert_match(/state=\h+/, response.location)
      end

      should "request the pre-granted scopes so inbound features need no reinstall" do
        with_slack_configured do
          get tenant_slack_install_path
        end
        query = URI.decode_www_form(URI(response.location).query).to_h
        scope = query["scope"].split(",")
        # The grant comes from this list, not the manifest — it must carry every
        # scope a planned feature needs, or that feature would force a re-auth.
        assert_includes scope, "chat:write"
        assert_includes scope, "users:read"
        assert_includes scope, "users:read.email"
        assert_includes scope, "im:write"
        assert_includes scope, "commands"
        assert_includes scope, "im:history"
      end

      should "redirect back with an alert when Slack isn't configured" do
        Slack.stub(:configured?, false) do
          get tenant_slack_install_path
        end
        assert_redirected_to tenant_integrations_path
        assert_match(/not configured/i, flash[:alert])
      end
    end

    context "GET callback" do
      should "exchange the code and connect the workspace" do
        with_slack_configured do
          get tenant_slack_install_path
          state = response.location[/state=(\h+)/, 1]

          Slack::Client.stub(:exchange_oauth_code, { "bot_token" => "xoxb-9", "team_id" => "T9", "team_name" => "Acme" }) do
            get tenant_slack_callback_path, params: { code: "abc", state: state }
          end
        end

        assert_redirected_to tenant_integrations_path
        assert @tenant.reload.slack_connected?
        assert_equal "T9", @tenant.slack_team_id
      end

      should "reject a mismatched state without connecting" do
        with_slack_configured do
          get tenant_slack_callback_path, params: { code: "abc", state: "forged" }
        end
        assert_redirected_to tenant_integrations_path
        assert_match(/could not be verified/i, flash[:alert])
        assert_not @tenant.reload.slack_connected?
      end
    end

    context "DELETE destroy" do
      should "disconnect the workspace" do
        @tenant.connect_slack!(bot_token: "xoxb-1", team_id: "T1")
        delete tenant_slack_connection_path
        assert_redirected_to tenant_integrations_path
        assert_not @tenant.reload.slack_connected?
      end
    end
  end

  context "as a tenant member" do
    setup { sign_in @member }

    should "deny the install flow" do
      with_slack_configured do
        get tenant_slack_install_path
      end
      assert_redirected_to root_path
      assert_not @tenant.reload.slack_connected?
    end
  end
end
