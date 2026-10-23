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

      assert_raises(Pundit::NotAuthorizedError) { update_theme(ctx, theme: "bento") }
      assert_equal "default", @tenant.reload.theme
    end

    should "permit global admins with no tenant_user" do
      gadmin = create(:user, global_admin: true)
      ctx = AuthorizationContext.new(user: gadmin, tenant_user: nil, person: nil)

      assert_equal @tenant.id, update_theme(ctx, theme: "bento")[:tenant_id]
    end
  end

  context "#perform" do
    should "persist the theme, role values and font, and return the theme as it now stands" do
      result = update_theme(@admin_ctx,
        theme: "custom",
        custom_theme: { "brand" => { "light" => "#112233", "dark" => "#445566" } },
        font_family: "Inter")

      @tenant.reload
      assert_equal "custom", @tenant.theme
      assert_equal({ "brand" => { "light" => "#112233", "dark" => "#445566" } }, @tenant.custom_theme)
      assert_equal "Inter", @tenant.font_family
      assert_equal [ :theme, :custom_theme, :font_family ], result[:updated]
      assert_equal({ theme: "custom", custom_theme: @tenant.custom_theme, font_family: "Inter" }, result[:theme])
    end

    should "merge custom_theme per role and scheme, and clear a value sent blank" do
      @tenant.update!(theme: "custom", custom_theme: {
        "brand" => { "light" => "#111111", "dark" => "#222222" },
        "nav-surface" => { "light" => "#333333" }
      })

      update_theme(@admin_ctx, custom_theme: { brand: { light: "#aaaaaa", dark: "" } })

      assert_equal({ "brand" => { "light" => "#aaaaaa" }, "nav-surface" => { "light" => "#333333" } },
        @tenant.reload.custom_theme)
    end

    should "leave everything alone when a field is nil" do
      @tenant.update!(theme: "custom", font_family: "Inter")

      update_theme(@admin_ctx, theme: nil, font_family: nil)

      assert_equal "custom", @tenant.reload.theme
      assert_equal "Inter", @tenant.font_family
    end

    should "reject an unknown theme as invalid input" do
      error = assert_raises(Operations::Base::ParameterError) { update_theme(@admin_ctx, theme: "neon") }
      assert_match(/theme/, error.message)
    end

    should "reject an unknown role or a malformed colour as invalid input, saving nothing" do
      assert_raises(Operations::Base::ParameterError) do
        update_theme(@admin_ctx, custom_theme: { "secondary" => { "light" => "#112233" } })
      end
      error = assert_raises(Operations::Base::ParameterError) do
        update_theme(@admin_ctx, theme: "custom", custom_theme: { "brand" => { "light" => "not-a-hex" } })
      end
      assert_match(/brand light must be a hex colour/, error.message)
      assert_equal "default", @tenant.reload.theme
    end

    should "leave the request's tenant as it was when the call is rejected" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Tenants::UpdateTheme.call(context: @admin_ctx,
            params: { theme: "custom", custom_theme: { "brand" => { "light" => "not-a-hex" } } })
        end

        assert_not ActsAsTenant.current_tenant.changed?
        assert_equal "default", ActsAsTenant.current_tenant.theme
      end
    end
  end

  private

  def update_theme(context, **params)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Tenants::UpdateTheme.call(context: context, params: params)
    end
  end
end
