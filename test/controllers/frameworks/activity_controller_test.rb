# frozen_string_literal: true

require "test_helper"

class Frameworks::ActivityControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @outsider_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "E1", "E1")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_id, rid)
      handler.publish_version(@framework_id, "v1")
      handler.add_collaborator(@framework_id, @admin_person.id.to_s, "owner", added_by: @admin_person.id.to_s)
      handler.suggest_edit(@framework_id, SecureRandom.uuid_v7,
        "capability", @cap_id, "description",
        "Sharper wording", @admin_person.id.to_s, mode: :suggesting)
    end
  end

  context "as an owner collaborator" do
    should "render the activity panel with suggestion and structural entries" do
      sign_in @admin_user
      get framework_activity_path(@framework_id, layout: "panel")

      assert_response :success
      assert_select "turbo-frame#suggestion-panel"
      assert_select "[data-controller='framework-activity']"
      assert_match "All framework activity", response.body
      assert_match "Sharper wording", response.body
      assert_match "Added a capability", response.body
    end

    should "narrow to a capability under capability focus" do
      sign_in @admin_user
      get framework_activity_path(@framework_id, layout: "panel",
        focus: "capability", capability_id: @cap_id)

      assert_response :success
      assert_match "Strategic Thinking", response.body
    end
  end

  context "as a non-member" do
    should "deny access" do
      sign_in @outsider_user
      get framework_activity_path(@framework_id, layout: "panel")

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end
end
