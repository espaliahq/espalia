# frozen_string_literal: true

require "test_helper"

class Tenant::OrgGraphSettings::EditorsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @editor_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:person, tenant: @tenant, name: "Ada Admin")
      create(:tenant_user, tenant: @tenant, user: @admin_user, person: @admin, role: :admin)
      @member = create(:person, tenant: @tenant, name: "Mo Member")
      @member_account = create(:tenant_user, tenant: @tenant, person: @member, role: :member)
      @editor = create(:person, tenant: @tenant, name: "Eve Editor")
      @editor_account = create(:tenant_user, tenant: @tenant, user: @editor_user, person: @editor, role: :member,
                                             org_graph_editor: true)
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "make a member an editor" do
      post tenant_org_graph_settings_editors_path, params: { person_id: @member.id }

      assert_redirected_to tenant_org_graph_settings_path
      assert_equal "Mo Member may now edit the Org Graph.", flash[:notice]
      assert @member_account.reload.org_graph_editor?
    end

    should "remove an editor" do
      delete tenant_org_graph_settings_editor_path(@editor.id)

      assert_redirected_to tenant_org_graph_settings_path
      assert_equal "Eve Editor may no longer edit the Org Graph.", flash[:notice]
      assert_not @editor_account.reload.org_graph_editor?
    end

    should "say why an admin can't be added, without the parameter name" do
      post tenant_org_graph_settings_editors_path, params: { person_id: @admin.id }

      assert_redirected_to tenant_org_graph_settings_path
      assert_equal "The editor could not be added: admins may already edit the Org Graph", flash[:alert]
    end
  end

  context "as an Org Graph editor" do
    setup { sign_in @editor_user }

    should "not choose other editors" do
      post tenant_org_graph_settings_editors_path, params: { person_id: @member.id }

      assert_redirected_to root_path
      assert_not @member_account.reload.org_graph_editor?
    end
  end
end
