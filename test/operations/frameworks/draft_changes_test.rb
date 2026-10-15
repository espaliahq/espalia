# frozen_string_literal: true

require "test_helper"

# The MCP twin of the publish-review page's "What changes in vN" (#497): an
# agent asking to publish reads what it is about to make live.
class Operations::Frameworks::DraftChangesTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @owner = create(:user)
    @outsider = create(:user)
    @handler = Frameworks::CommandHandler.new
    @framework_id = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(@tenant) do
      owner_person = create(:person, tenant: @tenant, email: @owner.email)
      @owner_context = AuthorizationContext.new(
        user: @owner, person: owner_person,
        tenant_user: create(:tenant_user, tenant: @tenant, user: @owner, person: owner_person, role: :member)
      )
      outsider_person = create(:person, tenant: @tenant, email: @outsider.email)
      @outsider_context = AuthorizationContext.new(
        user: @outsider, person: outsider_person,
        tenant_user: create(:tenant_user, tenant: @tenant, user: @outsider, person: outsider_person, role: :member)
      )

      family = SecureRandom.uuid_v7
      role = SecureRandom.uuid_v7
      cap = SecureRandom.uuid_v7
      @binding_id = SecureRandom.uuid_v7
      cat = SecureRandom.uuid_v7
      @handler.create_framework(@framework_id, "Data")
      @handler.add_role_family(@framework_id, family, "Data")
      @handler.add_role(@framework_id, role, family, "Analytics Engineer", "AE", "ic")
      @handler.add_level(@framework_id, SecureRandom.uuid_v7, role, 1, "AE I", "AE1", is_entry: true)
      @handler.add_capability_category(@framework_id, cat, "Engineering")
      @handler.add_capability(@framework_id, cap, SecureRandom.uuid_v7, cat, "System Design")
      @handler.create_capability_role_binding(@framework_id, @binding_id, cap, role)
      @handler.publish_version(@framework_id, "seed")
      @handler.add_collaborator(@framework_id, owner_person.id.to_s, "owner", added_by: owner_person.id.to_s)
    end
  end

  def run_as(context)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Frameworks::DraftChanges.call(context: context, params: { framework_id: @framework_id })
    end
  end

  should "say what the open draft changes" do
    ActsAsTenant.with_tenant(@tenant) { @handler.remove_capability_role_binding(@framework_id, @binding_id) }

    result = run_as(@owner_context)
    assert_equal 2, result[:draft_version]
    assert_equal [ { capability: "System Design", role: "Analytics Engineer", open_cycle_people: 0 } ],
                 result[:changes][:roles_removed]
  end

  should "answer every list empty when no draft is open" do
    result = run_as(@owner_context)
    assert_nil result[:draft_version]
    assert result[:changes].values.all?(&:empty?)
    assert_equal Frameworks::DraftChangesQuery::KINDS, result[:changes].keys
  end

  should "refuse someone who can't see the framework's drafts" do
    assert_raises(Pundit::NotAuthorizedError) { run_as(@outsider_context) }
  end
end
