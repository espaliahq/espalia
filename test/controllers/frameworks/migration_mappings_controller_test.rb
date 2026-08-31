# frozen_string_literal: true

require "test_helper"

class Frameworks::MigrationMappingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.publish_version(@framework_id, "seed")     # v1
      handler.start_draft(@framework_id, 2, "seed")      # open draft to map into
    end
    @from = SecureRandom.uuid_v7
    @to = SecureRandom.uuid_v7
  end

  def mappings
    ActsAsTenant.with_tenant(@tenant) { FrameworkState::MigrationMapping.where(framework_id: @framework_id) }
  end

  context "POST /frameworks/:framework_id/migration_mappings" do
    should "save a mapping for an admin and return to the review page" do
      sign_in @admin_user
      post framework_migration_mappings_path(framework_id: @framework_id),
           params: { migration_mapping: { from_stable_id: @from, mapping_type: "evolved", to_stable_id: @to } }

      assert_redirected_to new_framework_publication_path(@framework_id)
      assert_equal 1, mappings.count
      assert_equal "evolved", mappings.first.mapping_type
    end

    should "edit in place when a mapping_id is supplied" do
      sign_in @admin_user
      post framework_migration_mappings_path(framework_id: @framework_id),
           params: { migration_mapping: { from_stable_id: @from, mapping_type: "evolved", to_stable_id: @to } }
      mapping_id = mappings.first.mapping_id

      post framework_migration_mappings_path(framework_id: @framework_id),
           params: { migration_mapping: { from_stable_id: @from, mapping_type: "archived", mapping_id: mapping_id } }

      assert_equal 1, mappings.count
      assert_equal "archived", mappings.first.mapping_type
    end

    # A blank survivor is how the form submits when the field doesn't apply —
    # the controller compacts it, so the mapping saves.
    should "treat a blank survivor on a non-survivor mapping as absent" do
      sign_in @admin_user
      post framework_migration_mappings_path(framework_id: @framework_id),
           params: { migration_mapping: { from_stable_id: @from, mapping_type: "archived", to_stable_id: "" } }

      assert_redirected_to new_framework_publication_path(@framework_id)
      assert_equal "archived", mappings.first.mapping_type
      assert_nil mappings.first.to_stable_id
    end

    # A real survivor id alongside a mapping type that carries no ratings used
    # to be dropped silently; it now surfaces as a flash.
    should "flash when a non-survivor mapping names a surviving capability" do
      sign_in @admin_user
      post framework_migration_mappings_path(framework_id: @framework_id),
           params: { migration_mapping: { from_stable_id: @from, mapping_type: "archived", to_stable_id: @to } }

      assert_redirected_to new_framework_publication_path(@framework_id)
      assert_match(/does not take a surviving capability/, flash[:alert])
      assert_equal 0, mappings.count
    end

    should "redirect non-publisher members" do
      sign_in @member_user
      post framework_migration_mappings_path(framework_id: @framework_id),
           params: { migration_mapping: { from_stable_id: @from, mapping_type: "same" } }

      assert_redirected_to root_path
      assert_equal 0, mappings.count
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
