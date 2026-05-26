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
      follow_redirect!  # / → /frameworks (member with no assessments)
      follow_redirect!
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
