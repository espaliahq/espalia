# frozen_string_literal: true

require "test_helper"

class Frameworks::IllustrationArchivesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @ill_id = SecureRandom.uuid_v7
      h = Frameworks::CommandHandler.new
      h.create_framework(@framework_id, "Eng")
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      h.add_role_family(@framework_id, rfid, "Engineering")
      h.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      h.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "E1", "E1")
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      eid = SecureRandom.uuid_v7
      h.add_capability_category(@framework_id, cat_id, "Thinking")
      h.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      h.set_behavioural_expectation(@framework_id, eid, SecureRandom.uuid_v7, cap_id, 1, "Asks questions")
      h.add_role_illustration(@framework_id, @ill_id, SecureRandom.uuid_v7, eid, rid, 1, "Seeks guidance")
      h.publish_version(@framework_id, "seed")
    end
  end

  def illustration
    ActsAsTenant.with_tenant(@tenant) { FrameworkState::RoleIllustration.find_by(illustration_id: @ill_id) }
  end

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  context "POST create" do
    should "remove the illustration directly for an approver in editing mode" do
      sign_in @admin_user
      post framework_illustration_archives_path(framework_id: @framework_id),
           params: { archive: { illustration_id: @ill_id } }

      assert_redirected_to edit_framework_path(@framework_id)
      assert_match(/Archived the illustration/, flash[:notice])
      assert_nil illustration
    end

    should "propose the removal when the suggesting cookie is set" do
      sign_in @admin_user
      cookies[:framework_edit_mode] = "suggesting"
      post framework_illustration_archives_path(framework_id: @framework_id),
           params: { archive: { illustration_id: @ill_id } }

      assert_redirected_to edit_framework_path(@framework_id)
      assert_match(/Proposed archiving/, flash[:notice])
      assert_not_nil illustration, "a proposal must not remove the illustration"

      pending = ActsAsTenant.with_tenant(@tenant) do
        FrameworkState::SuggestedEdit.where(
          framework_id: @framework_id, kind: "delete", target_entity_id: @ill_id, status: "pending"
        ).count
      end
      assert_equal 1, pending
    end

    should "redirect a plain member (not authorized)" do
      sign_in @member_user
      post framework_illustration_archives_path(framework_id: @framework_id),
           params: { archive: { illustration_id: @ill_id } }

      assert_redirected_to root_path
      assert_not_nil illustration
    end

    should "redirect with an alert when the illustration belongs to another framework" do
      other_ill_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        other_fw = SecureRandom.uuid_v7
        h = Frameworks::CommandHandler.new
        h.create_framework(other_fw, "Design")
        rfid = SecureRandom.uuid_v7
        rid = SecureRandom.uuid_v7
        h.add_role_family(other_fw, rfid, "Design")
        h.add_role(other_fw, rid, rfid, "Product Designer", "PD", "ic")
        h.add_level(other_fw, SecureRandom.uuid_v7, rid, 1, "PD1", "PD1")
        cat = SecureRandom.uuid_v7
        cap = SecureRandom.uuid_v7
        eid = SecureRandom.uuid_v7
        h.add_capability_category(other_fw, cat, "Craft")
        h.add_capability(other_fw, cap, SecureRandom.uuid_v7, cat, "Visual Design")
        h.set_behavioural_expectation(other_fw, eid, SecureRandom.uuid_v7, cap, 1, "Sketches")
        h.add_role_illustration(other_fw, other_ill_id, SecureRandom.uuid_v7, eid, rid, 1, "Whiteboards")
        h.publish_version(other_fw, "seed")
      end

      sign_in @admin_user
      post framework_illustration_archives_path(framework_id: @framework_id),
           params: { archive: { illustration_id: other_ill_id } }

      assert_redirected_to edit_framework_path(@framework_id)
      assert_not_nil flash[:alert]
      assert_not_nil ActsAsTenant.with_tenant(@tenant) {
        FrameworkState::RoleIllustration.find_by(illustration_id: other_ill_id)
      }
    end
  end
end
