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
      @from = SecureRandom.uuid_v7
      @other_from = SecureRandom.uuid_v7
      @to = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      cat_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Eng")
      handler.add_capability_category(@framework_id, cat_id, "Thinking")
      handler.add_capability(@framework_id, SecureRandom.uuid_v7, @from, cat_id, "Legacy Systems")
      handler.add_capability(@framework_id, SecureRandom.uuid_v7, @other_from, cat_id, "Old Tools")
      handler.add_capability(@framework_id, SecureRandom.uuid_v7, @to, cat_id, "Modern Platforms")
      handler.publish_version(@framework_id, "seed")     # v1
      handler.start_draft(@framework_id, 2, "seed")      # open draft to map into
    end
  end

  def mappings
    ActsAsTenant.with_tenant(@tenant) { FrameworkState::MigrationMapping.where(framework_id: @framework_id) }
  end

  def rows(*list)
    { migration_mappings: list.each_with_index.to_h { |row, i| [ i.to_s, row ] } }
  end

  context "POST /frameworks/:framework_id/migration_mappings" do
    should "save every changed row in one submit and return to the review page" do
      sign_in @admin_user
      post framework_migration_mappings_path(framework_id: @framework_id),
           params: rows({ from_stable_id: @from, mapping_type: "evolved", to_stable_id: @to },
                        { from_stable_id: @other_from, mapping_type: "archived", to_stable_id: "" })

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

    # An undecided row (no type chosen) is left alone; a row still waiting on
    # a survivor is left unsaved and named — neither blocks the others.
    should "save the complete rows, ignore undecided ones and name the incomplete ones" do
      third = SecureRandom.uuid_v7
      sign_in @admin_user
      post framework_migration_mappings_path(framework_id: @framework_id),
           params: rows({ from_stable_id: @from, mapping_type: "evolved", to_stable_id: "" },
                        { from_stable_id: @other_from, mapping_type: "archived", to_stable_id: "" },
                        { from_stable_id: third, mapping_type: "", to_stable_id: "" })

      assert_redirected_to new_framework_publication_path(@framework_id)
      assert_equal "Saved 1 mapping.", flash[:notice]
      assert_equal "Still needs a survivor: Legacy Systems.", flash[:alert]
      assert_equal [ @other_from ], mappings.pluck(:from_stable_id)
    end

    should "flash the operation's refusal and save nothing" do
      sign_in @admin_user
      post framework_migration_mappings_path(framework_id: @framework_id),
           params: rows({ from_stable_id: @other_from, mapping_type: "archived" },
                        { from_stable_id: @from, mapping_type: "evolved", to_stable_id: @from })

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
