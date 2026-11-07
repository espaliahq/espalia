# frozen_string_literal: true

require "test_helper"

# WCAG 2.4.2 — every page carries a descriptive, page-specific <title>
# (issue #321). The layout renders [@page_title, tenant, "Espalia"] joined
# with " · "; these tests pin the convention for the primary surfaces.
class PageTitlesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant, name: "Acme")
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Test User")
      create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: framework_id, name: "Engineering Growth")

      rf = create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      @role = create(:framework_role,
        role_family_id: rf.role_family_id, name: "Software Engineer", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 1, title: "Junior", code: "E1")

      handler = PersonDevelopment::CommandHandler.new
      handler.assign_to_framework(@person.id, framework_id, @role.role_id, @level.level_id)
      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end
    sign_in @user
  end

  # Extracts the rendered <title> text.
  # @return [String]
  def page_title
    @response.body[%r{<title>([^<]*)</title>}, 1]
  end

  context "signed-in pages" do
    should "title the home dashboard" do
      get root_path
      assert_equal "Home · Acme · Espalia", page_title
    end

    should "title the assessments index" do
      get assessments_path
      assert_equal "My Assessments · Acme · Espalia", page_title
    end

    should "title the own assessment page" do
      get assessment_path(@assignment)
      assert_equal "My Assessment · Acme · Espalia", page_title
    end

    should "title the framework explorer with the framework name" do
      get framework_path(@framework.framework_id)
      assert_equal "Engineering Growth · Acme · Espalia", page_title
    end

    should "title distinct pages distinctly" do
      get root_path
      home = page_title
      get assessments_path
      assert_not_equal home, page_title
    end
  end

  context "manager view" do
    setup do
      @report_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        report = create(:person, tenant: @tenant, email: @report_user.email,
          name: "Alex Report", manager: @person)
        handler = PersonDevelopment::CommandHandler.new
        handler.assign_to_framework(report.id, @framework.framework_id, @role.role_id, @level.level_id)
        @report_assignment = PersonFrameworkAssignment.for_person(report.id).first
      end
    end

    should "title the report's assessment with their name" do
      get assessment_path(@report_assignment)
      assert_equal "Alex Report · Assessment · Acme · Espalia", page_title
    end
  end

  context "signed out" do
    should "render a clean fallback title with no leading separator" do
      sign_out @user
      get new_user_session_path
      assert_equal "Espalia", page_title
    end
  end
end
