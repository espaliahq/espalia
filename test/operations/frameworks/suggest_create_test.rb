# frozen_string_literal: true

require "test_helper"

# SuggestCreate proposes a new framework entity through the suggest/approve
# path. Defaults to suggesting (always pending — the direct add tools cover
# apply-immediately); editing mode auto-applies for an author with authority.
# proposed_attributes is content-validated in the Operation (missing/unknown
# keys → ParameterError, never an aggregate raise → internal error).
class Operations::Frameworks::SuggestCreateTest < ActiveSupport::TestCase
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
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking")
      handler.add_collaborator(@framework_id, @owner_person.id.to_s, "owner", added_by: @owner_person.id.to_s)
      handler.add_collaborator(@framework_id, @collab_person.id.to_s, "collaborator", added_by: @owner_person.id.to_s)
      handler.publish_version(@framework_id, "seed")
    end

    @owner_ctx = AuthorizationContext.new(user: @owner_user, tenant_user: @owner_tu, person: @owner_person)
    @collab_ctx = AuthorizationContext.new(user: @collab_user, tenant_user: @collab_tu, person: @collab_person)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def suggest_create(ctx, params)
    Operations::Frameworks::SuggestCreate.call(context: ctx, params: params)
  end

  def pending_creates
    FrameworkState::SuggestedEdit.pending.creates.where(framework_id: @framework_id)
  end

  context "default (suggesting) mode" do
    should "land a pending capability-creation proposal without touching the framework" do
      ActsAsTenant.with_tenant(@tenant) do
        result = suggest_create(@collab_ctx, {
          framework_id: @framework_id, entity_type: "capability",
          proposed_attributes: { "name" => "Systems Thinking", "description" => "Sees the whole" },
          parent_id: @cat_id, rationale: "Missing from the grid"
        })

        assert_not result[:applied]
        assert_nil result[:created_entity_id]
        suggestion = pending_creates.find_by!(suggestion_id: result[:suggestion_id])
        assert_equal "capability", suggestion.target_entity_type
        assert_equal @cat_id, suggestion.parent_id
        assert_equal "Systems Thinking", suggestion.proposed_attributes["name"]
        assert_nil FrameworkState::Capability.find_by(name: "Systems Thinking")
      end
    end

    should "stay pending for an authority-holder too (propose is propose)" do
      ActsAsTenant.with_tenant(@tenant) do
        result = suggest_create(@owner_ctx, {
          framework_id: @framework_id, entity_type: "capability",
          proposed_attributes: { "name" => "Prioritisation" }, parent_id: @cat_id
        })

        assert_not result[:applied]
        assert_equal 1, pending_creates.count
      end
    end
  end

  context "editing mode with authority" do
    should "apply the creation immediately and return the new entity id" do
      ActsAsTenant.with_tenant(@tenant) do
        result = suggest_create(@owner_ctx, {
          framework_id: @framework_id, entity_type: "capability",
          proposed_attributes: { "name" => "Prioritisation" }, parent_id: @cat_id,
          mode: "editing"
        })

        assert result[:applied]
        assert result[:created_entity_id].present?
        assert_empty pending_creates
      end
    end
  end

  context "proposed_attributes validation" do
    should "reject missing required keys as invalid params" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          suggest_create(@collab_ctx, {
            framework_id: @framework_id, entity_type: "capability",
            proposed_attributes: { "description" => "no name" }, parent_id: @cat_id
          })
        end
        assert_match(/missing required keys/, error.message)
      end
    end

    should "reject unknown keys by name instead of silently dropping them" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          suggest_create(@collab_ctx, {
            framework_id: @framework_id, entity_type: "capability",
            proposed_attributes: { "name" => "X", "title" => "smuggled" }, parent_id: @cat_id
          })
        end
        assert_match(/unknown keys.*title/, error.message)
      end
    end

    should "404 a parent id outside this framework" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(ActiveRecord::RecordNotFound) do
          suggest_create(@collab_ctx, {
            framework_id: @framework_id, entity_type: "capability",
            proposed_attributes: { "name" => "X" }, parent_id: SecureRandom.uuid_v7
          })
        end
      end
    end

    should "reject a parent_id on a framework-level entity type" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          suggest_create(@collab_ctx, {
            framework_id: @framework_id, entity_type: "capability_category",
            proposed_attributes: { "name" => "Delivery" }, parent_id: @cat_id
          })
        end
        assert_match(/takes no parent_id/, error.message)
      end
    end
  end

  context "as plain member (no suggest rights)" do
    should "deny the proposal" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          suggest_create(@member_ctx, {
            framework_id: @framework_id, entity_type: "capability_category",
            proposed_attributes: { "name" => "Delivery" }
          })
        end
      end
    end
  end
end
