# frozen_string_literal: true

require "test_helper"
require_relative "../../support/hris_mapping_fixtures"

class Tenant::HrisTitleMappingsControllerTest < ActionDispatch::IntegrationTest
  include HrisMappingFixtures

  setup { build_hris_mapping_tenant }

  def mapping_for(title) = @tenant.reload.hris_config.mapping_for(title)

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    context "POST /tenant/integrations/hris/title_mapping" do
      should "map the title and say who the next sync moves" do
        post tenant_hris_title_mapping_path, params: {
          hris_title_mapping: { title: "Engineering Manager (EM3)", framework_role_code: "EM", level_ordinal: "" }
        }

        assert_redirected_to tenant_integration_path("hris")
        assert_equal "EM", mapping_for("Engineering Manager (EM3)").framework_role_code
        assert_nil mapping_for("Engineering Manager (EM3)").level_ordinal, "blank is the HRIS level column"
        assert_equal "Mapped “Engineering Manager (EM3)” to EM (level from HRIS). " \
                     "The next sync moves Vera Renamed from E L3 to EM L3.", flash[:notice]
      end

      should "store a fixed level" do
        post tenant_hris_title_mapping_path, params: {
          hris_title_mapping: { title: "Analytics Lead", framework_role_code: "AE", level_ordinal: "3" }
        }

        assert_equal 3, mapping_for("Analytics Lead").level_ordinal
        assert_match(/Kit Unmapped from AE L2 to AE L3/, flash[:notice])
      end

      should "say so when a holder's HRIS level has no place on the role" do
        ActsAsTenant.with_tenant(@tenant) { @unmapped.update!(hris_level_ordinal: 7) }

        post tenant_hris_title_mapping_path, params: {
          hris_title_mapping: { title: "Analytics Lead", framework_role_code: "AE", level_ordinal: "" }
        }

        assert_match(/1 person can't be placed: AE has no level matching their HRIS level/, flash[:notice])
      end

      should "redirect back with the reason when the input is refused" do
        post tenant_hris_title_mapping_path, params: {
          hris_title_mapping: { title: "Analytics Lead", framework_role_code: "AE", level_ordinal: "9" }
        }

        assert_redirected_to tenant_integration_path("hris")
        assert_equal "The mapping could not be saved: level_ordinal: AE has no level 9", flash[:alert]
        assert_nil mapping_for("Analytics Lead")
      end
    end

    context "DELETE /tenant/integrations/hris/title_mapping" do
      should "remove the title and say who keeps their assignment" do
        delete tenant_hris_title_mapping_path, params: { hris_title_mapping: { title: "Software Engineer" } }

        assert_redirected_to tenant_integration_path("hris")
        assert_response :see_other
        assert_nil mapping_for("Software Engineer")
        assert_equal "Removed “Software Engineer”. The next sync skips the one person holding it, " \
                     "who keeps their current assignment.", flash[:notice]
      end

      should "explain a title nobody mapped" do
        delete tenant_hris_title_mapping_path, params: { hris_title_mapping: { title: "Analytics Lead" } }

        assert_match(/could not be removed: title: 'Analytics Lead' is not mapped/, flash[:alert])
      end
    end
  end

  context "as a member" do
    setup { sign_in @member_user }

    should "refuse to map a title" do
      post tenant_hris_title_mapping_path, params: {
        hris_title_mapping: { title: "Analytics Lead", framework_role_code: "AE", level_ordinal: "3" }
      }

      assert_equal "You are not authorized to perform this action.", flash[:alert]
      assert_nil mapping_for("Analytics Lead")
    end

    should "refuse to unmap a title" do
      delete tenant_hris_title_mapping_path, params: { hris_title_mapping: { title: "Software Engineer" } }

      assert_equal "You are not authorized to perform this action.", flash[:alert]
      assert mapping_for("Software Engineer")
    end
  end

  private

  # Signs in through the form, which also selects the user's tenant.
  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
