# frozen_string_literal: true

require "test_helper"

# SuggestEdit is the shared web + MCP surface for framework content edits
# (capability/category name + description, expectation text, illustration
# text): an author with approval authority in editing mode applies directly
# (auto-approved); suggesting mode — or no authority — lands a pending
# suggestion; a repeat edit on the same (entity, field) amends the author's
# pending proposal instead of stacking a second one.
class Operations::Frameworks::SuggestEditTest < ActiveSupport::TestCase
  setup do
    @owner_user = create(:user)
    @collab_user = create(:user)
    @member_user = create(:user)
    @tenant = create(:tenant)

    ActsAsTenant.with_tenant(@tenant) do
      @owner_person = create(:person, tenant: @tenant, email: @owner_user.email)
      @owner_tu = create(:tenant_user, tenant: @tenant, user: @owner_user, role: :member, person: @owner_person)
      # Suggest rights, but no approval authority.
      @collab_person = create(:person, tenant: @tenant)
      @collab_tu = create(:tenant_user, tenant: @tenant, user: @collab_user, role: :member, person: @collab_person)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @exp_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Critical Thinking")
      handler.set_behavioural_expectation(@framework_id, @exp_id, SecureRandom.uuid_v7, @cap_id, 1, "Asks clarifying questions")
      handler.add_collaborator(@framework_id, @owner_person.id.to_s, "owner", added_by: @owner_person.id.to_s)
      handler.add_collaborator(@framework_id, @collab_person.id.to_s, "collaborator", added_by: @owner_person.id.to_s)
      handler.publish_version(@framework_id, "seed")
    end

    @owner_ctx = AuthorizationContext.new(user: @owner_user, tenant_user: @owner_tu, person: @owner_person)
    @collab_ctx = AuthorizationContext.new(user: @collab_user, tenant_user: @collab_tu, person: @collab_person)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def suggest_edit(ctx, params)
    Operations::Frameworks::SuggestEdit.call(context: ctx, params: params)
  end

  def pending_edits
    FrameworkState::SuggestedEdit.pending.edits.where(framework_id: @framework_id)
  end

  context "as an author with approval authority (owner), editing mode" do
    should "apply a capability rename directly (auto-approved)" do
      ActsAsTenant.with_tenant(@tenant) do
        result = suggest_edit(@owner_ctx, {
          framework_id: @framework_id, entity_type: "capability", entity_id: @cap_id,
          field: "name", value: "Systems Thinking", mode: "editing"
        })

        assert result[:applied]
        assert_not result[:amended]
        assert_equal "Systems Thinking", FrameworkState::Capability.find_by(capability_id: @cap_id).name
        assert_empty pending_edits
        assert_equal "approved", FrameworkState::SuggestedEdit.find_by(suggestion_id: result[:suggestion_id]).status
      end
    end

    should "apply a capability description edit directly" do
      ActsAsTenant.with_tenant(@tenant) do
        result = suggest_edit(@owner_ctx, {
          framework_id: @framework_id, entity_type: "capability", entity_id: @cap_id,
          field: "description", value: "Weighs options and long-term impact", mode: "editing"
        })

        assert result[:applied]
        assert_equal "Weighs options and long-term impact",
                     FrameworkState::Capability.find_by(capability_id: @cap_id).description
      end
    end

    should "land a pending suggestion in suggesting mode despite authority" do
      ActsAsTenant.with_tenant(@tenant) do
        result = suggest_edit(@owner_ctx, {
          framework_id: @framework_id, entity_type: "behavioural_expectation", entity_id: @exp_id,
          field: "description", value: "Identifies root causes", mode: "suggesting"
        })

        assert_not result[:applied]
        assert_equal 1, pending_edits.count
        # The published text is untouched until a reviewer approves.
        assert_equal "Asks clarifying questions",
                     FrameworkState::BehaviouralExpectation.find_by(expectation_id: @exp_id).description
      end
    end
  end

  context "as a suggest-only collaborator" do
    should "land a pending suggestion even in editing mode (no authority)" do
      ActsAsTenant.with_tenant(@tenant) do
        result = suggest_edit(@collab_ctx, {
          framework_id: @framework_id, entity_type: "capability_category", entity_id: @cat_id,
          field: "name", value: "Thinking & Judgement", mode: "editing"
        })

        assert_not result[:applied]
        assert_equal 1, pending_edits.count
        assert_equal "Thinking", FrameworkState::CapabilityCategory.find_by(category_id: @cat_id).name
      end
    end

    should "amend the author's own pending edit on a repeat submit instead of stacking" do
      ActsAsTenant.with_tenant(@tenant) do
        first = suggest_edit(@collab_ctx, {
          framework_id: @framework_id, entity_type: "behavioural_expectation", entity_id: @exp_id,
          field: "description", value: "First proposal", mode: "suggesting"
        })
        second = suggest_edit(@collab_ctx, {
          framework_id: @framework_id, entity_type: "behavioural_expectation", entity_id: @exp_id,
          field: "description", value: "Refined proposal", mode: "suggesting"
        })

        assert second[:amended]
        assert_equal first[:suggestion_id], second[:suggestion_id]
        assert_equal 1, pending_edits.count
        assert_equal "Refined proposal",
                     FrameworkState::SuggestedEdit.find_by(suggestion_id: first[:suggestion_id]).suggested_value
      end
    end
  end

  context "parameter validation" do
    should "reject a field the entity type does not expose" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          suggest_edit(@owner_ctx, {
            framework_id: @framework_id, entity_type: "behavioural_expectation", entity_id: @exp_id,
            field: "name", value: "X"
          })
        end
      end
    end

    should "reject a blank name" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          suggest_edit(@owner_ctx, {
            framework_id: @framework_id, entity_type: "capability", entity_id: @cap_id,
            field: "name", value: "   "
          })
        end
      end
    end

    should "reject blank expectation text" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          suggest_edit(@owner_ctx, {
            framework_id: @framework_id, entity_type: "behavioural_expectation", entity_id: @exp_id,
            field: "description", value: ""
          })
        end
      end
    end

    should "404 an entity id outside this framework" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(ActiveRecord::RecordNotFound) do
          suggest_edit(@owner_ctx, {
            framework_id: @framework_id, entity_type: "capability", entity_id: SecureRandom.uuid_v7,
            field: "name", value: "X"
          })
        end
      end
    end
  end

  context "draft-added entities (Lesson 17)" do
    should "edit a capability added in the open draft (absent from the read model)" do
      ActsAsTenant.with_tenant(@tenant) do
        draft_cap_id = SecureRandom.uuid_v7
        Frameworks::CommandHandler.new.add_capability(
          @framework_id, draft_cap_id, SecureRandom.uuid_v7, @cat_id, "Draft-born"
        )
        assert_nil FrameworkState::Capability.find_by(capability_id: draft_cap_id)

        result = suggest_edit(@owner_ctx, {
          framework_id: @framework_id, entity_type: "capability", entity_id: draft_cap_id,
          field: "name", value: "Draft-born, renamed", mode: "editing"
        })

        assert result[:applied]
      end
    end
  end

  context "as plain member (no suggest rights)" do
    should "deny the edit" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          suggest_edit(@member_ctx, {
            framework_id: @framework_id, entity_type: "capability", entity_id: @cap_id,
            field: "name", value: "X"
          })
        end
      end
    end
  end
end
