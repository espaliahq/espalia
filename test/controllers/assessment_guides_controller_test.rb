# frozen_string_literal: true

require "test_helper"

class AssessmentGuidesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      person = create(:person, tenant: @tenant, email: @user.email, name: "Test User")
      create(:tenant_user, tenant: @tenant, user: @user, person: person)
    end
  end

  context "GET /assessments/how-it-works" do
    should "walk a member through the four steps" do
      sign_in @user
      get assessment_guide_path

      assert_response :success
      assert_select "h1", text: /One cycle\. Four steps\./
      %w[setup rate align close].each do |anchor|
        assert_select "nav a[href='##{anchor}']"
        assert_select "section##{anchor} h2"
      end
    end

    should "name the performance state in the tenant's own words" do
      @tenant.update!(performing_label: "On track")
      sign_in @user
      get assessment_guide_path

      assert_includes response.body, "On track at E3"
    end

    should "not be mistaken for an assessment id" do
      assert_equal "assessment_guides", Rails.application.routes.recognize_path("/assessments/how-it-works")[:controller]
    end

    should "redirect a visitor who is not signed in" do
      get assessment_guide_path

      assert_redirected_to new_user_session_path
    end
  end
end
