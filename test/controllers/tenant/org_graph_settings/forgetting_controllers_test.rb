# frozen_string_literal: true

require "test_helper"

# The forgetting panel's writes and its lazy count.
class Tenant::OrgGraphSettings::ForgettingControllersTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  PROVENANCE = { provider: "espalia", effective_on: "2020-01-01" }.freeze

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @editor_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @editor_user, role: :member, org_graph_editor: true)
      leaver = create(:person, tenant: @tenant)
      handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      handler.sync_person(leaver.id, **PROVENANCE, employment_status: "employed")
      handler.sync_person(leaver.id, **PROVENANCE, employment_status: "left", left_on: "2010-01-01")
    end
  end

  def config = @tenant.reload.org_graph_config

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "set the retention period, or never" do
      patch tenant_org_graph_settings_retention_path, params: { retention: "3" }
      assert_equal "Leavers are now forgotten 3 years after they leave.", flash[:notice]
      assert_equal 3, config.retention_years

      patch tenant_org_graph_settings_retention_path, params: { retention: "never" }
      assert_equal "Leavers are no longer forgotten.", flash[:notice]
      assert_nil config.retention_years
    end

    should "say when a shorter period turns the schedule off" do
      @tenant.update!(org_graph_config: { scheduled_forgetting: true })
      patch tenant_org_graph_settings_retention_path, params: { retention: "1" }

      assert_equal "Leavers are now forgotten 1 year after they leave. Scheduled forgetting is off until you check " \
                   "who is due and turn it on again.", flash[:notice]
      assert_not config.scheduled_forgetting
    end

    should "offer to turn the schedule off while it is on, even with no key or a period of never" do
      @tenant.update!(org_graph_config: { scheduled_forgetting: true, retention_years: nil })
      OrgGraph::Forgetting.stub(:key, nil) do
        get tenant_org_graph_settings_path
      end

      assert_select "#org-graph-forgetting", text: /Forgetting isn't set up/
      assert_select "#org-graph-forgetting", text: /nobody is forgotten while the period is never/
      assert_select "#org-graph-forgetting-off"
    end

    should "count the leavers due today" do
      get tenant_org_graph_settings_forgetting_due_path, headers: { "Turbo-Frame" => "org-graph-forgetting-due" }

      assert_response :success
      frame = Nokogiri::HTML5(response.body).at_css("turbo-frame#org-graph-forgetting-due")
      assert_includes frame.text, "1 person reaches their date today"
      assert_equal "1", frame.at_css("input[name='confirm_count']")["value"]
    end

    should "say plainly when the key is missing, without saying where it lives" do
      OrgGraph::Forgetting.stub(:key, nil) do
        get tenant_org_graph_settings_forgetting_due_path, headers: { "Turbo-Frame" => "org-graph-forgetting-due" }
        assert_includes Nokogiri::HTML5(response.body).text, "Forgetting isn't set up on this server"

        get tenant_org_graph_settings_path
        assert_includes Nokogiri::HTML5(response.body).text, "Forgetting isn't set up"
      end
      assert_no_match(/credentials|ORG_GRAPH_FORGETTING_KEY|forgetting_key/, response.body)
    end

    should "turn the schedule on for the count seen, and off" do
      post tenant_org_graph_settings_forgetting_schedule_path, params: { confirm_count: 1 }
      assert_equal "Scheduled forgetting is on.", flash[:notice]
      assert config.scheduled_forgetting

      delete tenant_org_graph_settings_forgetting_schedule_path
      assert_redirected_to tenant_org_graph_settings_path
      assert_not config.scheduled_forgetting
    end

    should "refuse to turn it on for a count that has moved" do
      post tenant_org_graph_settings_forgetting_schedule_path, params: { confirm_count: 0 }

      assert_equal "Scheduled forgetting was not turned on: 1 leavers are due now, not 0: run the dry run again", flash[:alert]
      assert_not config.scheduled_forgetting
    end
  end

  context "as an Org Graph editor" do
    setup { sign_in @editor_user }

    should "neither set retention nor schedule forgetting" do
      patch tenant_org_graph_settings_retention_path, params: { retention: "never" }
      assert_redirected_to root_path
      post tenant_org_graph_settings_forgetting_schedule_path, params: { confirm_count: 1 }
      assert_redirected_to root_path
      get tenant_org_graph_settings_forgetting_due_path
      assert_redirected_to root_path

      assert_equal OrgGraphConfig::DEFAULT_RETENTION_YEARS, config.retention_years
      assert_not config.scheduled_forgetting
    end
  end
end
