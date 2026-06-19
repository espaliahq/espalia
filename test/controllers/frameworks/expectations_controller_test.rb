# frozen_string_literal: true

require "test_helper"

class Frameworks::ExpectationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @owner_person = create(:person, tenant: @tenant, email: @user.email)
      create(:tenant_user, tenant: @tenant, user: @user, role: :admin, person: @owner_person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      @eid = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "E1", "E1")
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, rid)
      handler.set_behavioural_expectation(@framework_id, @eid, SecureRandom.uuid_v7, cap_id, 1, "Asks clarifying questions")
      handler.add_collaborator(@framework_id, @owner_person.id.to_s, "owner", added_by: @owner_person.id.to_s)
      handler.publish_version(@framework_id, "test")
    end
  end

  context "PATCH /frameworks/:framework_id/expectations/:id" do
    should "submit a suggest_edit and return the re-rendered text frame" do
      sign_in @user
      patch framework_expectation_path(framework_id: @framework_id, id: @eid),
            params: { behavioural_expectation: { description: "Asks better clarifying questions" } }

      assert_response :success
      assert_includes response.body, "expectation-text-#{@eid}"
      assert_includes response.body, "Asks better clarifying questions"
    end

    should "keep the edit pending when the suggesting cookie is set" do
      sign_in @user
      cookies[:framework_edit_mode] = "suggesting"
      patch framework_expectation_path(framework_id: @framework_id, id: @eid),
            params: { behavioural_expectation: { description: "Proposed only" } }

      ActsAsTenant.with_tenant(@tenant) do
        suggestion = FrameworkState::SuggestedEdit.where(
          framework_id: @framework_id,
          target_entity_type: "behavioural_expectation",
          target_entity_id: @eid
        ).last
        assert_equal "pending", suggestion.status
      end
    end

    should "reject blank descriptions" do
      sign_in @user
      patch framework_expectation_path(framework_id: @framework_id, id: @eid),
            params: { behavioural_expectation: { description: "" } }

      assert_response :unprocessable_content
    end

    should "deny non-contributor viewers" do
      viewer = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: viewer, role: :member)
      end
      sign_in viewer

      patch framework_expectation_path(framework_id: @framework_id, id: @eid),
            params: { behavioural_expectation: { description: "blocked" } }

      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
    end
  end

  context "POST /frameworks/:framework_id/expectations" do
    should "author an expectation on an empty cell and redirect" do
      sign_in @user
      post framework_expectations_path(framework_id: @framework_id),
           params: { behavioural_expectation: { capability_id: cap_id, level_ordinal: 2,
                                                description: "Identifies root causes" } }

      assert_redirected_to edit_framework_path(@framework_id)
      assert_match(/Added an expectation/, flash[:notice])
    end

    should "redirect with an alert on a malformed level ordinal (no silent 0)" do
      sign_in @user
      post framework_expectations_path(framework_id: @framework_id),
           params: { behavioural_expectation: { capability_id: cap_id, level_ordinal: "abc", description: "x" } }

      assert_redirected_to edit_framework_path(@framework_id)
      assert_match(/level must be a positive number/i, flash[:alert])
    end

    should "redirect with an alert when the cell already has an expectation" do
      sign_in @user
      post framework_expectations_path(framework_id: @framework_id),
           params: { behavioural_expectation: { capability_id: cap_id, level_ordinal: 1, description: "Dup" } }

      assert_redirected_to edit_framework_path(@framework_id)
      assert_match(/already has an expectation/i, flash[:alert])
    end

    should "deny non-contributor viewers" do
      viewer = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: viewer, role: :member)
      end
      sign_in viewer

      post framework_expectations_path(framework_id: @framework_id),
           params: { behavioural_expectation: { capability_id: cap_id, level_ordinal: 2, description: "x" } }

      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
    end

    should "edit a draft-added (read-model-deferred) expectation without 404ing" do
      sign_in @user
      # Author a new expectation — shape-changing, so it's deferred from the AR
      # read model until publish but lives in the graph.
      post framework_expectations_path(framework_id: @framework_id),
           params: { behavioural_expectation: { capability_id: cap_id, level_ordinal: 2, description: "Drafted" } }

      new_eid = ActsAsTenant.with_tenant(@tenant) do
        exp = Frameworks::ExplorerGraph.load(@framework_id)
          .capability_categories.flat_map(&:capabilities).flat_map(&:expectations)
          .find { |e| e.level_ordinal == 2 }
        assert_nil FrameworkState::BehaviouralExpectation.find_by(expectation_id: exp.expectation_id),
                   "precondition: the new expectation is deferred from the read model"
        exp.expectation_id
      end

      patch framework_expectation_path(framework_id: @framework_id, id: new_eid),
            params: { behavioural_expectation: { description: "Edited the draft expectation" } }

      assert_response :success
      assert_includes response.body, "Edited the draft expectation"
    end
  end

  private

  def cap_id
    ActsAsTenant.with_tenant(@tenant) do
      FrameworkState::Capability.find_by!(name: "Strategic Thinking").capability_id
    end
  end

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
