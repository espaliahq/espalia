# frozen_string_literal: true

require "test_helper"

class Tenant::HrisConnectionsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
    end
  end

  def connection(overrides = {})
    { hris_connection: { provider: "hibob", service_user_id: "svc-1", api_token: "tok-secret",
                         webhook_secret: "", level_field_id: "column_9", sync_enabled: "1" }.merge(overrides) }
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "save settings and credentials in one write" do
      patch tenant_hris_connection_path, params: connection

      assert_redirected_to tenant_integration_path("hris")
      @tenant.reload
      assert_equal "hibob", @tenant.hris_config.provider
      assert_equal "column_9", @tenant.hris_config.level_field_id
      assert @tenant.hris_config.sync_enabled?
      assert_equal "svc-1", @tenant.hris_secrets.service_user_id
      assert_equal "tok-secret", @tenant.hris_secrets.api_token
      assert_nil @tenant.hris_secrets.webhook_secret
    end

    should "keep the stored level field when the form posts none, as when its picker failed to render" do
      @tenant.update_hris!(settings: { level_field_id: "work.customColumns.column_9" })

      patch tenant_hris_connection_path, params: { hris_connection: connection[:hris_connection].except(:level_field_id) }

      assert_equal "work.customColumns.column_9", @tenant.reload.hris_config.level_field_id
    end

    should "clear the level field when the form posts None" do
      @tenant.update_hris!(settings: { level_field_id: "work.customColumns.column_9" })

      patch tenant_hris_connection_path, params: connection(level_field_id: "")

      assert_nil @tenant.reload.hris_config.level_field_id
    end

    should "keep a stored credential when its field is blank" do
      @tenant.update_hris!(service_user_id: "svc-1", api_token: "tok-secret")

      patch tenant_hris_connection_path, params: connection(service_user_id: "", api_token: "")

      secrets = @tenant.reload.hris_secrets
      assert_equal "svc-1", secrets.service_user_id
      assert_equal "tok-secret", secrets.api_token
    end

    should "re-render the page with the message when the settings do not validate" do
      patch tenant_hris_connection_path, params: connection(provider: "workday")

      assert_response :unprocessable_content
      assert_includes response.body, "The connection could not be saved."
      assert_includes response.body, "Provider is not included in the list"
      assert_nil @tenant.reload.hris_config.provider
    end

    should "never echo a stored credential" do
      @tenant.update_hris!(service_user_id: "svc-1", api_token: "tok-secret", webhook_secret: "hook-secret")

      get tenant_integration_path("hris")

      assert_response :success
      assert_includes response.body, "Stored"
      assert_includes response.body, "Leave blank to keep the stored value."
      assert_not_includes response.body, "tok-secret"
      assert_not_includes response.body, "hook-secret"
      assert_not_includes response.body, "svc-1"
    end
  end

  context "DELETE as a tenant admin" do
    setup { sign_in @admin_user }

    should "disconnect: credentials gone, sync off, mappings kept" do
      @tenant.update_hris!(settings: { provider: "hibob", sync_enabled: true },
                           service_user_id: "svc-1", api_token: "tok-secret")

      delete tenant_hris_connection_path

      assert_redirected_to tenant_integration_path("hris")
      @tenant.reload
      assert_nil @tenant.hris_credentials
      assert_not @tenant.hris_config.sync_enabled?
      assert_equal "hibob", @tenant.hris_config.provider
    end
  end

  context "as a tenant member" do
    should "be denied" do
      sign_in @member_user

      patch tenant_hris_connection_path, params: connection

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
      assert_nil @tenant.reload.hris_config.provider
    end

    should "be denied the disconnect" do
      sign_in @member_user
      @tenant.update_hris!(service_user_id: "svc-1", api_token: "tok-secret")

      delete tenant_hris_connection_path

      assert_redirected_to root_path
      assert @tenant.reload.hris_secrets.complete?
    end
  end

  context "signed out" do
    should "be sent to sign in" do
      patch tenant_hris_connection_path, params: connection

      assert_redirected_to new_user_session_path
    end
  end
end
