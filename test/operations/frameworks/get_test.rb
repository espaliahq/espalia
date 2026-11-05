# frozen_string_literal: true

require "test_helper"

# Confirms the top-level disclosure shape: a framework returns its role
# families and capability categories with one level of ID+name recursion
# inside each (roles inside families, capabilities inside categories) —
# and no further (no expectations, no illustrations). That's the
# load-bearing contract for context-budget management.
class Operations::Frameworks::GetTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email)
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @person, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: @framework_id, name: "Engineering",
                          current_published_version: 2)
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      @role  = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      create(:framework_role, role_family_id: rf.role_family_id, name: "Manager", code: "EM", track: "management")

      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability, category_id: cat.category_id, name: "Strategic Thinking")
    end
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def call_op
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Frameworks::Get.call(context: @context, params: { framework_id: @framework_id })
    end
  end

  context "structure" do
    should "return the framework summary + role families + categories" do
      result = call_op

      assert_equal "Engineering", result[:name]
      assert_equal 2, result[:current_published_version]
      assert_equal [ "Eng" ], result[:role_families].map { |f| f[:name] }
      assert_equal [ "SWE", "Manager" ].sort, result[:role_families].first[:roles].map { |r| r[:name] }.sort
      assert_equal [ "Thinking" ], result[:categories].map { |c| c[:name] }
      assert_equal [ "Critical Thinking", "Strategic Thinking" ].sort,
        result[:categories].first[:capabilities].map { |c| c[:name] }.sort
    end

    should "stop at one level of recursion — no inline expectations or illustrations" do
      result = call_op
      capability = result[:categories].first[:capabilities].first

      # Capability rows expose just identity — no expectations / illustrations
      # / bindings. Deeper drill-in lives behind a separate tool.
      assert_equal %i[id stable_id name].sort, capability.keys.sort
    end

    should "list each category's capabilities in the framework's order, not by name" do
      ActsAsTenant.with_tenant(@tenant) do
        cat = create(:framework_capability_category, framework_id: @framework_id, name: "Delivery", ordinal: 2)
        create(:framework_capability, category_id: cat.category_id, name: "Strategic Thinking", ordinal: 1)
        create(:framework_capability, category_id: cat.category_id, name: "Data Informed", ordinal: 2)
        create(:framework_capability, category_id: cat.category_id, name: "Commit, Deliver, Celebrate", ordinal: 3)
        create(:framework_capability, category_id: cat.category_id, name: "Added Later", ordinal: nil)
      end

      delivery = call_op[:categories].find { |c| c[:name] == "Delivery" }
      assert_equal [ "Strategic Thinking", "Data Informed", "Commit, Deliver, Celebrate", "Added Later" ],
        delivery[:capabilities].map { |c| c[:name] }
    end

    should "list categories without an ordinal last, in the order they were added" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:framework_capability_category, framework_id: @framework_id, name: "Zeta", ordinal: nil)
        create(:framework_capability_category, framework_id: @framework_id, name: "Alpha", ordinal: nil)
      end

      assert_equal [ "Thinking", "Zeta", "Alpha" ], call_op[:categories].map { |c| c[:name] }
    end

    should "omit archived categories from the payload" do
      ActsAsTenant.with_tenant(@tenant) do
        archived = create(:framework_capability_category, framework_id: @framework_id,
                                                          name: "Retired", ordinal: 2)
        archived.update!(status: "archived")
      end

      result = call_op
      assert_not_includes result[:categories].map { |c| c[:name] }, "Retired"
    end
  end

  context "versions" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        stream = EventStreamNaming.framework_stream(@framework_id)
        Rails.configuration.event_store.append(
          Frameworks::Events::FrameworkVersionPublished.new(
            data: { framework_id: @framework_id, version: 1 },
            metadata: { tenant_id: @tenant.id, actor_id: @person.id, timestamp: Time.utc(2026, 3, 1) }
          ),
          stream_name: stream
        )
        Rails.configuration.event_store.append(
          Frameworks::Events::FrameworkVersionPublished.new(
            data: { framework_id: @framework_id, version: 2, published_by: @person.id },
            metadata: { tenant_id: @tenant.id, timestamp: Time.utc(2026, 9, 1) }
          ),
          stream_name: stream
        )
      end
    end

    should "list every published version, newest first, with when and by whom" do
      versions = call_op[:versions]

      assert_equal [ 2, 1 ], versions.map { |v| v[:version] }
      assert_equal "2026-09-01T00:00:00Z", versions.first[:published_at]
      assert_equal @person.id, versions.first.dig(:published_by, :id)
      assert_equal @person.id, versions.last.dig(:published_by, :id), "an older event names its publisher only in metadata"
    end
  end

  context "policy" do
    should "deny callers without tenant membership" do
      stranger = create(:user)
      ctx = AuthorizationContext.new(user: stranger, tenant_user: nil, person: nil)

      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::Get.call(context: ctx, params: { framework_id: @framework_id })
        end
      end
    end
  end
end
