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

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
