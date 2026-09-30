# frozen_string_literal: true

require "test_helper"

# Declaring and closing an exploration from the lens banner (ADR-22), the
# banner's exploration line, and where an exploration shows on
# /assessments. Only the assessee, the reporting manager and a delegate get
# through; a view-only ancestor reads but never writes.
class Assessments::ExplorationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @fx = build_role_lens_framework(tenant: @tenant)
    @skip_user = create(:user, password: "password123")
    @manager_user = create(:user, password: "password123")
    @report_user = create(:user, password: "password123")
    @delegate_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      skip = create(:person, tenant: @tenant, email: @skip_user.email, name: "Sam Okafor")
      create(:tenant_user, tenant: @tenant, user: @skip_user, person: skip)
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, manager: skip, name: "Morgan Reyes")
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @report = create(:person, tenant: @tenant, email: @report_user.email, manager: @manager, name: "Alex Kim")
      create(:tenant_user, tenant: @tenant, user: @report_user, person: @report)
      delegate = create(:person, tenant: @tenant, email: @delegate_user.email)
      create(:tenant_user, tenant: @tenant, user: @delegate_user, person: delegate)
      @assignment, @cycle_id = enrol_in_role_lens_framework(@report, @fx, tenant: @tenant)
      create(:manager_assessment_delegation, tenant: @tenant, person_id: @report.id,
             framework_id: @fx.framework_id, delegate_person_id: delegate.id)
    end
    @pm_lens = { as_role: @fx.pm.role_id, as_level: 3 }
  end

  def exploration
    ActsAsTenant.with_tenant(@tenant) { AssessmentExploration.for_assignment(@assignment).order(:started_at).last }
  end

  def declare(user = @report_user, note: "Curious about discovery")
    sign_in user
    post assessment_explorations_path(@assignment), params: @pm_lens.merge(note: note)
  end

  context "POST explorations" do
    should "declare the lens as an exploration for the assessee and return to the lens" do
      declare

      assert_redirected_to assessment_path(@assignment, @pm_lens)
      assert_equal "You're exploring Product Manager · PM3 — Morgan can see it now.", flash[:notice]
      assert_equal "open", exploration.status
      assert_equal "Curious about discovery", exploration.start_note
    end

    should "let the manager share it, naming the assessee" do
      declare(@manager_user)

      assert_equal "You're exploring Product Manager · PM3 — Alex can see it now.", flash[:notice]
      assert_equal @manager.id, exploration.started_by_id
    end

    should "let a delegate share it" do
      declare(@delegate_user)

      assert_equal "open", exploration.status
    end

    should "deny a view-only ancestor" do
      declare(@skip_user)

      assert_equal "You are not authorized to perform this action.", flash[:alert]
      assert_nil exploration
    end

    should "refuse the record itself with the reason" do
      sign_in @report_user
      post assessment_explorations_path(@assignment), params: { as_level: 2 }

      assert_redirected_to assessment_path(@assignment, as_level: 2)
      assert_match(/E2 is the role and level/, flash[:alert])
    end
  end

  context "POST exploration closure" do
    setup do
      declare
      sign_out @report_user
    end

    should "close it with the outcome for the manager" do
      sign_in @manager_user
      post assessment_exploration_closure_path(@assignment, exploration.id),
           params: @pm_lens.merge(outcome: "not_now", note: "After the launch")

      assert_redirected_to assessment_path(@assignment, @pm_lens)
      assert_equal "Stopped exploring Product Manager · PM3.", flash[:notice]
      assert_equal "not_now", exploration.outcome
    end

    should "deny a view-only ancestor" do
      sign_in @skip_user
      post assessment_exploration_closure_path(@assignment, exploration.id), params: { outcome: "pursue" }

      assert_equal "You are not authorized to perform this action.", flash[:alert]
      assert_equal "open", exploration.status
    end

    should "refuse an exploration already closed" do
      sign_in @report_user
      post assessment_exploration_closure_path(@assignment, exploration.id), params: { outcome: "pursue" }
      post assessment_exploration_closure_path(@assignment, exploration.id), params: { outcome: "pursue" }

      assert_equal "That exploration is already closed", flash[:alert]
    end
  end

  context "the lens banner" do
    should "offer the assessee Keep exploring this until they declare, then name it and offer Stop" do
      sign_in @report_user
      get assessment_path(@assignment, @pm_lens)
      assert_select "#assessment-lens-exploration button", text: "Keep exploring this"
      assert_select "##{Views::Assessments::StartExplorationModal::ID}"

      post assessment_explorations_path(@assignment), params: @pm_lens
      get assessment_path(@assignment, @pm_lens)
      assert_select "#assessment-lens-exploration", text: /Exploring PM3 since .* · started by you/
      assert_select "#assessment-lens-exploration button", text: "Stop exploring"
      assert_select "##{Views::Assessments::StopExplorationModal::ID} input[name=outcome]", 3
    end

    should "offer the manager Share with Alex and name who started it" do
      sign_in @manager_user
      get assessment_path(@assignment, @pm_lens)
      assert_select "#assessment-lens-exploration button", text: "Share with Alex"

      sign_out @manager_user
      declare
      sign_out @report_user
      sign_in @manager_user
      get assessment_path(@assignment, @pm_lens)
      assert_select "#assessment-lens-exploration", text: /started by Alex/
    end

    should "show a view-only ancestor the exploration but no buttons" do
      declare
      sign_out @report_user
      sign_in @skip_user
      get assessment_path(@assignment, @pm_lens)

      assert_select "#assessment-lens-exploration", text: /Exploring PM3/
      assert_select "#assessment-lens-exploration button", count: 0
    end

    should "offer nothing on the record" do
      sign_in @report_user
      get assessment_path(@assignment)

      assert_select "#assessment-lens-exploration", count: 0
    end
  end

  context "GET /assessments" do
    setup { declare }

    should "list the person's own open exploration with its progress" do
      get assessments_path

      assert_select "#explorations a[href=?]", assessment_path(@assignment, @pm_lens), text: /Product Manager · PM3/
      assert_select "#explorations", text: /0 of 2 rated · started by you/
    end

    should "chip the report's team card for the manager" do
      sign_out @report_user
      sign_in @manager_user
      get assessments_path

      assert_select "#explorations", count: 0
      assert_select "a[data-exploration=PM3][href=?]", assessment_path(@assignment, @pm_lens), text: "Exploring PM3"
    end

    should "drop a closed exploration" do
      post assessment_exploration_closure_path(@assignment, exploration.id), params: { outcome: "moved" }
      get assessments_path

      assert_select "#explorations", count: 0
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  def sign_out(_user)
    delete destroy_user_session_path
  end
end
