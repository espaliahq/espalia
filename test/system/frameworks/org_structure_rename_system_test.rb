# frozen_string_literal: true

require "application_system_test_case"

# Inline rename of org-structure entities (role family + role in the left tree,
# level title in the matrix header) in edit mode. These are direct edits — the
# new value applies live (no pending decoration). View mode renders plain names
# with no edit affordance.
class Frameworks::OrgStructureRenameSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    @viewer_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @viewer_user, role: :member)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      @rf_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      @level_id = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, @rf_id, "Engineering")
      handler.add_role(@framework_id, @role_id, @rf_id, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, @level_id, @role_id, 1, "Engineer I", "E1", is_entry: true)
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, @role_id)
      handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                          cap_id, 1, "Asks clarifying questions")
      handler.publish_version(@framework_id, "test")
    end
  end

  context "edit mode" do
    should "rename a role family inline in the tree" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      submit_inline_rename("role-family-name-#{@rf_id}", "role_family[name]", "Platform Engineering")
      assert_text "Platform Engineering"
    end

    should "rename a role inline in the tree" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      submit_inline_rename("role-name-#{@role_id}", "role[name]", "Backend Engineer")
      assert_text "Backend Engineer"
    end

    should "rename a level title inline in the matrix header" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      submit_inline_rename("level-title-#{@level_id}", "level[title]", "Engineer One")
      assert_text "Engineer One"
    end

    # Regression: the level-title editor used a fixed sentence-width form
    # (w-80/w-96), which ballooned the narrow, centred header cell so the editor
    # rendered offset ("next to") rather than in place — and, in a level column,
    # widened the whole table. The shared editor is `w-full min-w-0` of its host,
    # so opening it must not change the header cell's width (#379).
    should "not widen the level column when the editor opens" do
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      header = find("turbo-frame#level-title-#{@level_id}").ancestor("th")
      width_before = header.evaluate_script("this.getBoundingClientRect().width")

      form = start_inline_edit("turbo-frame#level-title-#{@level_id} > div")
      assert_includes form[:class], "w-full"
      assert_in_delta width_before,
                      header.evaluate_script("this.getBoundingClientRect().width"), 1.0
    end
  end

  context "view mode" do
    should "render plain names with no edit affordance across the whole rename surface" do
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      assert_text "Software Engineer"
      # Tree: no role / role-family inline editors or pencils.
      assert_no_selector "turbo-frame#role-name-#{@role_id} [data-controller='inline-editor']"
      assert_no_selector "[aria-label='Edit role name']"
      assert_no_selector "[aria-label='Edit role family name']"
      # Matrix header: no level-title inline editor or pencil.
      assert_text "Engineer I"
      assert_no_selector "turbo-frame#level-title-#{@level_id} [data-editor-action]"
      assert_no_selector "[aria-label='Edit level title']"
    end
  end

  private

  # Open the shared inline editor on a turbo-frame's host and save the new
  # value — the JS-dispatch pattern the other inline editors use (Selenium
  # clicks on the opacity-0 pencil + send_keys both flake on starved CI).
  def submit_inline_rename(frame_id, field_name, value)
    form = start_inline_edit("turbo-frame##{frame_id} > div")
    assert_equal field_name, form.find("[data-editor-input]", visible: :all)[:name]
    # Org structure has no approval tier, so the editor always says "Save".
    assert_equal "Save", form.find("[data-editor-submit]").text
    submit_inline_edit(form, with: value)
  end
end
