# frozen_string_literal: true

require "test_helper"

class Tenant::IntegrationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    @admin_user  = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @person = create(:person,
        tenant: @tenant,
        name: "Alice Engineer",
        email: "alice@example.com",
        job_title: "Software Engineer",
        hris_source: "hibob",
        status: "active"
      )
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    context "GET /integrations" do
      should "render the integrations index" do
        get tenant_integrations_path

        assert_response :success
        assert_includes response.body, "Integrations"
        assert_includes response.body, "HRIS"
      end

      should "show the Slack connect affordance when configured but not connected" do
        Slack.stub(:configured?, true) do
          get tenant_integrations_path
        end
        assert_includes response.body, "Slack"
        assert_includes response.body, "Connect Slack"
        assert_includes response.body, tenant_slack_install_path
      end

      should "show the connected workspace + disconnect when connected" do
        @tenant.connect_slack!(bot_token: "xoxb-1", team_id: "T1", team_name: "Acme HQ")
        Slack.stub(:configured?, true) do
          get tenant_integrations_path
        end
        assert_includes response.body, "Acme HQ"
        assert_includes response.body, "Disconnect"
      end
    end

    context "GET /integrations/hris" do
      should "render the HRIS detail page" do
        get tenant_integration_path("hris")

        assert_response :success
        assert_includes response.body, "HRIS Integration"
        assert_includes response.body, "Configuration"
        assert_includes response.body, "Role Mappings"
        assert_includes response.body, "Imported People"
        assert_includes response.body, "Alice Engineer"
        assert_includes response.body, "Software Engineer"
      end
    end

    context "GET /integrations/hris with a title nobody mapped" do
      setup do
        ActsAsTenant.with_tenant(@tenant) do
          create(:person, tenant: @tenant, name: "Una Mapped", email: "una@example.com",
                 job_title: "Chief Vibes Officer", hris_source: "hibob", status: "active")
        end
      end

      should "list it with a way to map it" do
        get tenant_integration_path("hris")

        assert_select "#unmapped-titles tr[data-unmapped-title='Chief Vibes Officer']" do
          assert_select "button[aria-label='Map Chief Vibes Officer to a role']"
        end
        assert_select "##{Views::Integrations::HrisMappingModal::ID} form[action='#{tenant_hris_title_mapping_path}']"
      end

      should "offer each mapped title as editable and removable" do
        get tenant_integration_path("hris")

        assert_select "[data-mapped-title='Software Engineer']" do
          assert_select "button[aria-label='Edit mapping for Software Engineer']"
          assert_select "button[aria-label='Remove mapping for Software Engineer']"
        end
      end
    end

    context "GET /integrations/unknown" do
      should "redirect to index with alert" do
        get tenant_integration_path("unknown")

        assert_redirected_to tenant_integrations_path
        follow_redirect!
        assert_includes response.body, "Unknown integration"
      end
    end

    context "POST /integrations/hris/sync" do
      should "enqueue HrisSyncJob and redirect with notice" do
        assert_enqueued_with(job: HrisSyncJob) do
          post sync_tenant_integration_path("hris")
        end

        assert_redirected_to tenant_integration_path("hris")
        follow_redirect!
        assert_includes response.body, "HRIS sync queued"
      end

      should "alert when integration is not configured" do
        @tenant.hris_credentials = nil
        @tenant.save!

        assert_no_enqueued_jobs only: HrisSyncJob do
          post sync_tenant_integration_path("hris")
        end

        assert_redirected_to tenant_integration_path("hris")
        follow_redirect!
        assert_includes response.body, "not fully configured"
      end
    end
  end

  context "as a tenant member" do
    setup { sign_in @member_user }

    should "deny GET /integrations" do
      get tenant_integrations_path
      assert_redirected_to root_path
      follow_redirect!  # / renders the Home dashboard, which shows the flash alert
      assert_includes response.body, "You are not authorized"
    end

    should "deny GET /integrations/hris" do
      get tenant_integration_path("hris")
      assert_redirected_to root_path
    end

    should "deny POST /integrations/hris/sync and not enqueue the job" do
      assert_no_enqueued_jobs only: HrisSyncJob do
        post sync_tenant_integration_path("hris")
      end
      assert_redirected_to root_path
    end
  end

  context "unauthenticated" do
    should "redirect /integrations to sign in" do
      get tenant_integrations_path
      assert_redirected_to new_user_session_path
    end

    should "redirect POST /integrations/hris/sync to sign in" do
      post sync_tenant_integration_path("hris")
      assert_redirected_to new_user_session_path
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
