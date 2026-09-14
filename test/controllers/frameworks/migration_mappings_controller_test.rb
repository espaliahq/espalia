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

  def rows(*list)
    { migration_mappings: list.each_with_index.to_h { |row, i| [ i.to_s, row ] } }
  end

  context "POST /frameworks/:framework_id/migration_mappings" do
    should "save every changed row in one submit and return to the review page" do
      other_from = SecureRandom.uuid_v7
      sign_in @admin_user
      post framework_migration_mappings_path(framework_id: @framework_id),
           params: rows({ from_stable_id: @from, mapping_type: "evolved", to_stable_id: @to, name: "A" },
                        { from_stable_id: other_from, mapping_type: "archived", to_stable_id: "", name: "B" })

      assert_redirected_to new_framework_publication_path(@framework_id)
      assert_equal "Saved 2 mappings.", flash[:notice]
      assert_nil flash[:alert]
      assert_equal %w[archived evolved], mappings.pluck(:mapping_type).sort
    end

    should "edit in place when a mapping_id is supplied and skip unchanged rows" do
      sign_in @admin_user
      post framework_migration_mappings_path(framework_id: @framework_id),
           params: rows({ from_stable_id: @from, mapping_type: "evolved", to_stable_id: @to })
      mapping_id = mappings.first.mapping_id

      post framework_migration_mappings_path(framework_id: @framework_id),
           params: rows({ from_stable_id: @from, mapping_type: "evolved", to_stable_id: @to, mapping_id: mapping_id })
      assert_equal "No mapping changes to save.", flash[:notice]

      post framework_migration_mappings_path(framework_id: @framework_id),
           params: rows({ from_stable_id: @from, mapping_type: "archived", to_stable_id: "", mapping_id: mapping_id })

      assert_equal "Saved 1 mapping.", flash[:notice]
      assert_equal 1, mappings.count
      assert_equal "archived", mappings.first.mapping_type
      assert_nil mappings.first.to_stable_id
    end

    # A row still waiting on a survivor must not block the others, nor be saved
    # half-done: it is left alone and named.
    should "save the complete rows and name the ones still needing a survivor" do
      other_from = SecureRandom.uuid_v7
      sign_in @admin_user
      post framework_migration_mappings_path(framework_id: @framework_id),
           params: rows({ from_stable_id: @from, mapping_type: "evolved", to_stable_id: "", name: "Legacy Systems" },
                        { from_stable_id: other_from, mapping_type: "archived", to_stable_id: "", name: "Old Tools" })

      assert_redirected_to new_framework_publication_path(@framework_id)
      assert_equal "Saved 1 mapping.", flash[:notice]
      assert_equal "Still needs a survivor: Legacy Systems.", flash[:alert]
      assert_equal [ other_from ], mappings.pluck(:from_stable_id)
    end

    should "flash the operation's refusal for a self-mapping" do
      sign_in @admin_user
      post framework_migration_mappings_path(framework_id: @framework_id),
           params: rows({ from_stable_id: @from, mapping_type: "evolved", to_stable_id: @from })

      assert_redirected_to new_framework_publication_path(@framework_id)
      assert_match(/own survivor/, flash[:alert])
      assert_equal 0, mappings.count
    end

    should "redirect non-publisher members" do
      sign_in @member_user
      post framework_migration_mappings_path(framework_id: @framework_id),
           params: rows({ from_stable_id: @from, mapping_type: "archived" })

      assert_redirected_to root_path
      assert_equal 0, mappings.count
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
