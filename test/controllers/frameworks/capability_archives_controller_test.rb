# frozen_string_literal: true

require "test_helper"

class Frameworks::CapabilityArchivesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @survivor_stable = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, cat_id, "Legacy Systems")
      handler.add_capability(@framework_id, SecureRandom.uuid_v7, @survivor_stable, cat_id, "Platform Eng")
      # A role + level + binding so the capability actually renders a matrix row
      # — the archive response streams that row back, and a framework with no
      # levels renders the matrix's empty state instead.
      rf_id = SecureRandom.uuid_v7
      role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, role_id, rf_id, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, role_id, 1, "Engineer I", "E1")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_id, role_id)
      handler.publish_version(@framework_id, "seed")
    end
  end

  def framework
    ActsAsTenant.with_tenant(@tenant) { FrameworkState::Framework.find_by!(framework_id: @framework_id) }
  end

  def post_archive(user, archive)
    sign_in user
    post framework_capability_archives_path(framework_id: @framework_id), params: { archive: archive }
  end

  context "POST create" do
    should "archive with an evolved mapping, auto-open a draft, and record the mapping" do
      post_archive(@admin_user,
        { capability_id: @cap_id, reason: "Retired", mapping_type: "evolved", to_stable_id: @survivor_stable })

      # The struck row + the draft pill, streamed in place — no navigation (#381).
      assert_write_toast(/^.*Archived/)
      assert_no_navigation
      assert_turbo_stream_action("replace", "capability-row-#{@cap_id}")
      assert_turbo_stream_action("replace", "framework-draft-badge")
      assert framework.draft_in_progress

      mapping = ActsAsTenant.with_tenant(@tenant) do
        FrameworkState::MigrationMapping.find_by(framework_id: @framework_id, to_stable_id: @survivor_stable)
      end
      assert_not_nil mapping
      assert_equal "evolved", mapping.mapping_type
    end

    should "archive with no survivor for an archived mapping" do
      post_archive(@admin_user, { capability_id: @cap_id, reason: "Retired", mapping_type: "archived" })

      assert_write_toast
      mapping = ActsAsTenant.with_tenant(@tenant) do
        FrameworkState::MigrationMapping.find_by(framework_id: @framework_id, mapping_type: "archived")
      end
      assert_not_nil mapping
      assert_nil mapping.to_stable_id
    end

    should "propose (not apply) the archive when the suggesting cookie is set" do
      sign_in @admin_user
      cookies[:framework_edit_mode] = "suggesting"
      post framework_capability_archives_path(framework_id: @framework_id),
           params: { archive: { capability_id: @cap_id, reason: "Retire" } }

      assert_write_toast(/Proposed archiving/)
      assert_no_navigation
      assert_turbo_stream_action("replace", "capability-row-#{@cap_id}")
      assert_not framework.draft_in_progress, "a proposal must not open a draft"

      pending = ActsAsTenant.with_tenant(@tenant) do
        FrameworkState::SuggestedEdit.where(
          framework_id: @framework_id, kind: "delete", target_entity_id: @cap_id, status: "pending"
        ).count
      end
      assert_equal 1, pending
    end

    should "redirect a plain member (not authorized) and not open a draft" do
      post_archive(@member_user, { capability_id: @cap_id, reason: "x", mapping_type: "archived" })

      assert_redirected_to root_path
      assert_not framework.draft_in_progress
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
