# frozen_string_literal: true

require "test_helper"

class Tenant::OrgGraphSettingsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)
    @editor_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      admin = create(:person, tenant: @tenant, name: "Ada Admin")
      create(:tenant_user, tenant: @tenant, user: @admin_user, person: admin, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member,
                           person: create(:person, tenant: @tenant, name: "Mo Member"))
      create(:tenant_user, tenant: @tenant, user: @editor_user, role: :member, org_graph_editor: true,
                           person: create(:person, tenant: @tenant, name: "Eve Editor"))
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "list the admins and editors, and offer only members who aren't editors yet" do
      get tenant_org_graph_settings_path

      assert_response :success
      panel = Nokogiri::HTML5(response.body).at_css("#org-graph-editors")
      assert_includes panel.text, "Ada Admin"
      assert_includes panel.text, "Eve Editor"
      assert_equal [ "Mo Member" ], panel.css("select[name='person_id'] option").map(&:text)
    end
  end

  context "as an Org Graph editor" do
    setup { sign_in @editor_user }

    should "be turned away, as the screen is for admins" do
      get tenant_org_graph_settings_path

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  context "as a member" do
    setup { sign_in @member_user }

    should "be turned away" do
      get tenant_org_graph_settings_path

      assert_redirected_to root_path
    end
  end
end
