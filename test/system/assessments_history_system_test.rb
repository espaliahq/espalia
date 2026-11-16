# frozen_string_literal: true

require "application_system_test_case"

class AssessmentsHistorySystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Alice")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test Framework")
      rf_id = SecureRandom.uuid_v7
      role_id = SecureRandom.uuid_v7
      level_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, role_id, rf_id, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, level_id, role_id, 1, "Engineer 1", "E1", is_entry: true)

      @stable_ids = []
      @categories = [ "Thinking", "Delivering" ].each_with_index.map do |name, index|
        cat_id = SecureRandom.uuid_v7
        handler.add_capability_category(@framework_id, cat_id, name, ordinal: index + 1)
        cap_id = SecureRandom.uuid_v7
        @stable_ids << SecureRandom.uuid_v7
        handler.add_capability(@framework_id, cap_id, @stable_ids.last, cat_id, "#{name} capability")
        handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, role_id, weight: 1.0)
        handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, cap_id, 1, "#{name} expectation")
        cat_id
      end
      handler.publish_version(@framework_id, "test")

      PersonDevelopment::CommandHandler.new.assign_to_framework(@person.id, @framework_id, role_id, level_id)
      cycle_id = SecureRandom.uuid_v7
      cycles = AssessmentCycles::CommandHandler.new
      cycles.define_cycle(cycle_id, @framework_id, "Q1", "regular", 1, defined_by: @person.id)
      cycles.enroll(cycle_id, @person.id, enrolled_by: @person.id)
      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end

    sign_in_as(@user)
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "leave the assessment in one Back after clicks inside it, and return to the same place on Forward" do
        visit assessments_path
        assert_text "My Assessments"
        visit assessment_path(@assignment)
        await_matrix

        click_inside_assessment
        assert_current_category @categories.last
        url_inside = current_url

        page.go_back
        assert_current_path assessments_path
        assert_text "My Assessments"

        page.go_forward
        assert_equal url_inside, current_url
        await_matrix
        assert_current_category @categories.last
        assert_equal url_inside, current_url
      end

      should "open a shared link on the category it names" do
        visit assessment_path(@assignment, category: @categories.last)
        await_matrix
        assert_current_category @categories.last
        assert_operator evaluate_script("document.getElementById('category-#{@categories.last}').getBoundingClientRect().top"), :<, size.last
        assert_includes current_url, "category=#{@categories.last}"
      end

      should "mark the chip of the card a link opens on, when the link also names another category" do
        visit assessment_path(@assignment, category: @categories.last, capability: @stable_ids.first)
        await_matrix
        assert_selector "section#category-#{@categories.first} [data-matrix-target='card'][data-focused='true']"
        assert_current_category @categories.first
      end
    end
  end

  private

  def await_matrix
    assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
    wait_for_stimulus "matrix"
    wait_for_stimulus "category-nav"
  end

  def click_inside_assessment
    @categories.each do |category|
      execute_script("document.querySelector('nav#category-tabs [data-category-id=\"#{category}\"]').click()")
      assert_current_category category
      execute_script("document.querySelector('section#category-#{category} [data-action=\"click->matrix#focusCapability\"]').click()")
      assert_selector "section#category-#{category} [data-matrix-target='card'][data-focused='true']"
    end
  end

  def assert_current_category(category)
    assert_selector "nav#category-tabs a[data-category-id='#{category}'][aria-current='page']", visible: :all
  end
end
