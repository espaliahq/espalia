# frozen_string_literal: true

require "test_helper"

# Unit + acts_as_tenant scoping checks for the read Operation.
# Pundit denial is exercised in the integration layer alongside the
# MCP tools/call → 403 mapping; here we focus on shape and scoping.
class Operations::Frameworks::ListTest < ActiveSupport::TestCase
  setup do
    @tenant_a = create(:tenant, name: "A")
    @tenant_b = create(:tenant, name: "B")
    @user = create(:user)
    @tenant_user = ActsAsTenant.with_tenant(@tenant_a) do
      create(:tenant_user, tenant: @tenant_a, user: @user, role: :member)
    end
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)

    ActsAsTenant.with_tenant(@tenant_a) do
      @fw1 = create(:framework_state, tenant: @tenant_a, framework_id: SecureRandom.uuid_v7,
                   name: "Engineering", current_published_version: 2)
      @fw2 = create(:framework_state, tenant: @tenant_a, framework_id: SecureRandom.uuid_v7,
                   name: "Apprenticeship", current_published_version: 1)
    end
    ActsAsTenant.with_tenant(@tenant_b) do
      create(:framework_state, tenant: @tenant_b, framework_id: SecureRandom.uuid_v7,
             name: "Off-tenant", current_published_version: 1)
    end
  end

  context "#perform" do
    should "return frameworks in the active tenant only, alphabetised by name" do
      result = ActsAsTenant.with_tenant(@tenant_a) do
        Operations::Frameworks::List.call(context: @context)
      end

      names = result.map { |row| row[:name] }
      assert_equal [ "Apprenticeship", "Engineering" ], names
      assert_not_includes names, "Off-tenant"
    end

    should "expose only the public identity + version fields" do
      result = ActsAsTenant.with_tenant(@tenant_a) do
        Operations::Frameworks::List.call(context: @context)
      end

      row = result.find { |r| r[:name] == "Engineering" }
      assert_equal @fw1.framework_id, row[:id]
      assert_equal 2, row[:current_published_version]
      assert_equal false, row[:draft_in_progress]
      assert_equal %i[id name current_published_version draft_in_progress].sort, row.keys.sort
    end
  end

  context "policy" do
    should "deny when the user has no tenant membership" do
      stranger = create(:user)
      no_context = AuthorizationContext.new(user: stranger, tenant_user: nil, person: nil)

      ActsAsTenant.with_tenant(@tenant_a) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::List.call(context: no_context)
        end
      end
    end
  end
end
