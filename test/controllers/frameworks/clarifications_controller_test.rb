# frozen_string_literal: true

require "test_helper"

# The explorer's "Discuss…" endpoint — opens a clarification anchored on a
# capability, one of its cells, or a role illustration. Answers 204 plus the new
# suggestion id so the modal can open that discussion's card.
class Frameworks::ClarificationsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @owner_user = create(:user, password: "password123")
    @outsider_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @owner_person = create(:person, tenant: @tenant, email: @owner_user.email)
      @outsider_person = create(:person, tenant: @tenant, email: @outsider_user.email)
      create(:tenant_user, tenant: @tenant, user: @owner_user, role: :member, person: @owner_person)
      create(:tenant_user, tenant: @tenant, user: @outsider_user, role: :member, person: @outsider_person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @exp_id = SecureRandom.uuid_v7
      @ill_id = SecureRandom.uuid_v7
      role_family_id = SecureRandom.uuid_v7
      role_id = SecureRandom.uuid_v7
      category_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, role_family_id, "Engineering")
      handler.add_role(@framework_id, role_id, role_family_id, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, role_id, 4, "Senior Engineer", "E4")
      handler.add_capability_category(@framework_id, category_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, category_id, "Navigating Ambiguity")
      handler.set_behavioural_expectation(@framework_id, @exp_id, SecureRandom.uuid_v7, @cap_id,
                                          4, "Shapes direction amid ambiguity")
      handler.add_role_illustration(@framework_id, @ill_id, SecureRandom.uuid_v7, @exp_id, role_id, 1,
                                    "Leads third-party integrations")
      handler.publish_version(@framework_id, "test")
      handler.add_collaborator(@framework_id, @owner_person.id.to_s, "owner",
                               added_by: @owner_person.id.to_s)
    end
  end

  context "as a framework owner" do
    setup { sign_in @owner_user }

    should "open a discussion on a cell and return the suggestion id" do
      post framework_clarifications_path(@framework_id), params: {
        clarification: { capability_id: @cap_id, level_ordinal: "4",
                         rationale: "Does this mean architecture or delivery?" }
      }

      assert_response :no_content
      suggestion_id = response.headers[Frameworks::ClarificationsController::SUGGESTION_ID_HEADER]
      assert suggestion_id.present?

      ActsAsTenant.with_tenant(@tenant) do
        row = FrameworkState::SuggestedEdit.find_by!(suggestion_id: suggestion_id)
        assert_equal "clarification", row.kind
        assert_equal "pending", row.status
        assert_equal @exp_id, row.target_entity_id
        assert_equal @owner_person.id.to_s, row.author_id
      end
    end

    should "open a discussion on an illustration" do
      post framework_clarifications_path(@framework_id), params: {
        clarification: { illustration_id: @ill_id,
                         rationale: "Is third-party integration the right L4 example?" }
      }

      assert_response :no_content
      ActsAsTenant.with_tenant(@tenant) do
        row = FrameworkState::SuggestedEdit.find_by!(
          suggestion_id: response.headers[Frameworks::ClarificationsController::SUGGESTION_ID_HEADER]
        )
        assert_equal "role_illustration", row.target_entity_type
        assert_equal @ill_id, row.target_entity_id
        assert_equal 4, row.proposed_attributes["level_ordinal"]
      end
    end

    # The operation takes an illustration's level from its owning expectation,
    # so a stray ordinal on the wire is ignored, not grounds for a 422.
    should "ignore a malformed level alongside an illustration anchor" do
      post framework_clarifications_path(@framework_id), params: {
        clarification: { illustration_id: @ill_id, level_ordinal: "L4",
                         rationale: "Is this the right example?" }
      }

      assert_response :no_content
      ActsAsTenant.with_tenant(@tenant) do
        row = FrameworkState::SuggestedEdit.find_by!(
          suggestion_id: response.headers[Frameworks::ClarificationsController::SUGGESTION_ID_HEADER]
        )
        assert_equal @ill_id, row.target_entity_id
        assert_equal 4, row.proposed_attributes["level_ordinal"],
                     "the level must come from the owning expectation, not the wire"
      end
    end

    should "open a capability-wide discussion when no level is chosen" do
      post framework_clarifications_path(@framework_id), params: {
        clarification: { capability_id: @cap_id, level_ordinal: "",
                         rationale: "How does this differ from Judgement?" }
      }

      assert_response :no_content
      ActsAsTenant.with_tenant(@tenant) do
        row = FrameworkState::SuggestedEdit.find_by!(
          suggestion_id: response.headers[Frameworks::ClarificationsController::SUGGESTION_ID_HEADER]
        )
        assert_equal @cap_id, row.target_entity_id
        assert_empty row.proposed_attributes
      end
    end

    should "reject a blank question without creating anything" do
      assert_no_difference -> { ActsAsTenant.with_tenant(@tenant) { FrameworkState::SuggestedEdit.count } } do
        post framework_clarifications_path(@framework_id), params: {
          clarification: { capability_id: @cap_id, level_ordinal: "4", rationale: "   " }
        }
      end

      assert_response :unprocessable_content
    end

    should "reject an illustration from outside this framework" do
      post framework_clarifications_path(@framework_id), params: {
        clarification: { illustration_id: SecureRandom.uuid_v7, rationale: "Whose example is this?" }
      }

      assert_response :unprocessable_content
    end
  end

  context "as a tenant member with no collaborator role" do
    should "be denied" do
      sign_in @outsider_user

      post framework_clarifications_path(@framework_id), params: {
        clarification: { capability_id: @cap_id, level_ordinal: "4", rationale: "?" }
      }

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end
end
