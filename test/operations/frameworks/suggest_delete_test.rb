# frozen_string_literal: true

require "test_helper"

# SuggestDelete proposes deleting a capability or illustration as an
# always-pending suggestion (the direct-apply path is the archive tools).
# Nothing is removed until a reviewer approves.
class Operations::Frameworks::SuggestDeleteTest < ActiveSupport::TestCase
  setup do
    @owner_user = create(:user)
    @collab_user = create(:user)
    @member_user = create(:user)
    @tenant = create(:tenant)

    ActsAsTenant.with_tenant(@tenant) do
      @owner_person = create(:person, tenant: @tenant, email: @owner_user.email)
      @owner_tu = create(:tenant_user, tenant: @tenant, user: @owner_user, role: :member, person: @owner_person)
      @collab_person = create(:person, tenant: @tenant)
      @collab_tu = create(:tenant_user, tenant: @tenant, user: @collab_user, role: :member, person: @collab_person)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Critical Thinking")
      handler.add_collaborator(@framework_id, @owner_person.id.to_s, "owner", added_by: @owner_person.id.to_s)
      handler.add_collaborator(@framework_id, @collab_person.id.to_s, "collaborator", added_by: @owner_person.id.to_s)
      handler.publish_version(@framework_id, "seed")
    end

    @collab_ctx = AuthorizationContext.new(user: @collab_user, tenant_user: @collab_tu, person: @collab_person)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def suggest_delete(ctx, params)
    Operations::Frameworks::SuggestDelete.call(context: ctx, params: params)
  end

  def pending_deletes
    FrameworkState::SuggestedEdit.pending.deletes.where(framework_id: @framework_id)
  end

  context "as a suggest-rights collaborator" do
    should "land a pending deletion proposal without touching the capability" do
      ActsAsTenant.with_tenant(@tenant) do
        result = suggest_delete(@collab_ctx, {
          framework_id: @framework_id, entity_type: "capability", entity_id: @cap_id,
          rationale: "Superseded by Systems Thinking"
        })

        assert_equal "pending", result[:status]
        suggestion = pending_deletes.find_by!(suggestion_id: result[:suggestion_id])
        assert_equal @cap_id, suggestion.target_entity_id
        assert_equal "active", FrameworkState::Capability.find_by(capability_id: @cap_id).status
      end
    end

    should "reject a repeat proposal by the same author as invalid params" do
      ActsAsTenant.with_tenant(@tenant) do
        suggest_delete(@collab_ctx, {
          framework_id: @framework_id, entity_type: "capability", entity_id: @cap_id
        })

        assert_raises(Operations::Base::ParameterError) do
          suggest_delete(@collab_ctx, {
            framework_id: @framework_id, entity_type: "capability", entity_id: @cap_id
          })
        end
        assert_equal 1, pending_deletes.count
      end
    end

    should "404 an entity id outside this framework" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(ActiveRecord::RecordNotFound) do
          suggest_delete(@collab_ctx, {
            framework_id: @framework_id, entity_type: "capability", entity_id: SecureRandom.uuid_v7
          })
        end
      end
    end

    should "reject a non-deletable entity type at the parameter layer" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          suggest_delete(@collab_ctx, {
            framework_id: @framework_id, entity_type: "capability_category", entity_id: @cat_id
          })
        end
      end
    end
  end

  context "as plain member (no suggest rights)" do
    should "deny the proposal" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          suggest_delete(@member_ctx, {
            framework_id: @framework_id, entity_type: "capability", entity_id: @cap_id
          })
        end
      end
    end
  end
end
