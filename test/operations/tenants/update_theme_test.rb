# frozen_string_literal: true

require "test_helper"

class Operations::Tenants::UpdateThemeTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @admin_tu = ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
    end
    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
  end

  context "policy" do
    should "deny when the user is a tenant member, not admin" do
      member = create(:user)
      member_tu = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: member, role: :member)
      end
      ctx = AuthorizationContext.new(user: member, tenant_user: member_tu, person: nil)

      assert_raises(Pundit::NotAuthorizedError) do
        ActsAsTenant.with_tenant(@tenant) do
          Operations::Tenants::UpdateTheme.call(
            context: ctx,
            params: { primary_color: "#123456" }
          )
        end
      end
    end

    should "permit global admins with no tenant_user" do
      gadmin = create(:user, global_admin: true)
      ctx = AuthorizationContext.new(user: gadmin, tenant_user: nil, person: nil)

      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Tenants::UpdateTheme.call(
          context: ctx,
          params: { primary_color: "#abcdef" }
        )
        assert_equal @tenant.id, result[:tenant_id]
      end
    end
  end

  context "#perform" do
    should "persist supplied color and font fields on tenant.settings" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Tenants::UpdateTheme.call(
          context: @admin_ctx,
          params: {
            primary_color: "#112233",
            secondary_color_dark: "#445566",
            font_family: "Inter"
          }
        )

        @tenant.reload
        assert_equal "#112233", @tenant.primary_color
        assert_equal "#445566", @tenant.secondary_color_dark
        assert_equal "Inter", @tenant.font_family
        assert_equal [ :primary_color, :secondary_color_dark, :font_family ], result[:updated]
        assert_equal @tenant.id, result[:tenant_id]
      end
    end

    should "drop nil params so blank fields don't clobber existing values" do
      ActsAsTenant.with_tenant(@tenant) do
        @tenant.update!(primary_color: "#aaaaaa")

        Operations::Tenants::UpdateTheme.call(
          context: @admin_ctx,
          params: { primary_color: nil, secondary_color: "#bbbbbb" }
        )

        @tenant.reload
        assert_equal "#aaaaaa", @tenant.primary_color
        assert_equal "#bbbbbb", @tenant.secondary_color
      end
    end

    should "raise RecordInvalid on a malformed hex color" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(ActiveRecord::RecordInvalid) do
          Operations::Tenants::UpdateTheme.call(
            context: @admin_ctx,
            params: { primary_color: "not-a-hex" }
          )
        end
      end
    end
  end
end
