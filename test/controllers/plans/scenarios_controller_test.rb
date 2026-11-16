# frozen_string_literal: true

require "test_helper"

class Plans::ScenariosControllerTest < ActionDispatch::IntegrationTest
  class HeadcountCap < TeamPlanning::RuleKind
    def self.rule_name = "test_headcount_cap"
    def self.description = "The most people a unit may hold"
    def self.default = { "cap" => 10 }
  end

  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @outsider = account(role: :admin, name: "Ada Admin")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Pay review 2027", base_on: "2026-11-14")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                  ends_on: "2027-03-31")[:scenario_id]
    end
  end

  context "an editor" do
    setup { sign_in @editor.user }

    should "fork a scenario and land on its map" do
      post plan_scenarios_path(@plan_id), params: { scenario: { parent_id: @q1, relation: "then", name: "Q2 hires", ends_on: "2027-06-30" } }

      scenario = scenario_named("Q2 hires")
      assert_redirected_to map_plan_path(@plan_id, scenario: scenario.id)
      assert_equal "Q2 hires forked.", flash[:notice]
      assert_equal [ @q1, "then" ], [ scenario.parent_id, scenario.relation ]
    end

    should "start a first step after the base date, so Today carries on until then" do
      fresh = ActsAsTenant.with_tenant(@tenant) { call(Operations::TeamPlanning::CreatePlan, @editor, name: "Hiring 2027", base_on: "2026-11-14")[:plan_id] }
      get plan_path(fresh)
      assert_select "input[name='scenario[starts_on]'][value='2026-11-14'][min='2026-11-14']"

      post plan_scenarios_path(fresh), params: { scenario: { parent_id: fresh, relation: "then", name: "Q1 hires",
                                                             starts_on: "2026-12-01", ends_on: "2027-03-31" } }

      scenario = ActsAsTenant.with_tenant(@tenant) { TeamPlanningScenario.where(plan_id: fresh, relation: "then").sole }
      assert_redirected_to map_plan_path(fresh, scenario: scenario.id)
      assert_equal [ Date.new(2026, 12, 1), Date.new(2027, 3, 31) ], [ scenario.starts_on, scenario.ends_on ]
    end

    should "fork an alternative that keeps its parent's period, ignoring a blank end date" do
      post plan_scenarios_path(@plan_id), params: { scenario: { parent_id: @q1, relation: "instead", name: "Slower hiring", ends_on: "" } }

      assert_equal "instead", scenario_named("Slower hiring").relation
    end

    should "say why a fork was refused" do
      post plan_scenarios_path(@plan_id), params: { scenario: { parent_id: @plan_id, relation: "instead", name: "Nope" } },
                                          headers: { "HTTP_REFERER" => plan_url(@plan_id) }

      assert_redirected_to plan_url(@plan_id)
      assert_match(/\ACouldn't fork the scenario: /, flash[:alert])
      assert_nil scenario_named("Nope")
    end

    should "rename and describe a scenario and go back where they were" do
      patch plan_scenario_path(@plan_id, @q1), params: { scenario: { name: "Lean Q1", description: "Hire two seniors" } },
                                               headers: { "HTTP_REFERER" => map_plan_url(@plan_id, scenario: @q1) }

      assert_redirected_to map_plan_url(@plan_id, scenario: @q1)
      assert_equal "Saved Lean Q1.", flash[:notice]
      assert_equal "Hire two seniors", scenario_named("Lean Q1")&.description&.reveal
      assert_equal "Lean Q1", scenario_named("Lean Q1")&.name&.reveal
    end

    should "clear a description with a blank" do
      patch plan_scenario_path(@plan_id, @q1), params: { scenario: { name: "Q1 hires", description: "Hire two seniors" } }
      patch plan_scenario_path(@plan_id, @q1), params: { scenario: { name: "Q1 hires", description: "" } }

      assert_nil scenario_named("Q1 hires").description&.reveal
    end

    should "say why an edit was refused" do
      patch plan_scenario_path(@plan_id, @plan_id), params: { scenario: { name: "Now" } }

      assert_redirected_to plan_path(@plan_id)
      assert_equal "Couldn't save the scenario: The baseline can't be renamed", flash[:alert]

      patch plan_scenario_path(@plan_id, @q1), params: { scenario: { description: "x" * 501 } }
      assert_equal "Couldn't save the scenario: A scenario's description can be at most 500 characters", flash[:alert]
    end

    should "say the name was saved when only the description is refused" do
      patch plan_scenario_path(@plan_id, @q1), params: { scenario: { name: "First quarter", description: "x" * 501 } }

      assert_equal "Saved First quarter, but couldn't save its description: " \
                   "A scenario's description can be at most 500 characters", flash[:alert]
    end

    should "be offered the controls on the plan page and the map" do
      get plan_path(@plan_id)
      assert_select "button[data-modal-target-id='#{Views::Plans::ScenarioDialogs::FORK_ID}']", text: "New scenario"
      assert_select "form[action='#{plan_scenarios_path(@plan_id)}']"

      get map_plan_path(@plan_id, scenario: @q1)
      assert_select "button[data-rename-name='Q1 hires']", text: "Edit…"
    end
  end

  context "removing, as an editor" do
    setup do
      sign_in @editor.user
      @lean = ActsAsTenant.with_tenant(@tenant) do
        call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, parent_id: @q1, relation: "instead", name: "Lean Q1")[:scenario_id]
      end
    end

    should "remove a scenario and land on the plan page with Removed scenarios open" do
      delete plan_scenario_path(@plan_id, @lean)

      assert_redirected_to plan_path(@plan_id, removed_page: 1, anchor: "removed-scenarios")
      assert_response :see_other
      assert_equal "Removed Lean Q1.", flash[:notice]
      assert_nil scenario_named("Lean Q1")
      follow_redirect!
      assert_select "details#removed-scenarios[open] [data-removed-scenario='#{@lean}']", text: /Lean Q1/
    end

    should "say why a removal was refused, and remove nothing" do
      delete plan_scenario_path(@plan_id, @q1)
      assert_redirected_to plan_path(@plan_id)
      assert_equal "Couldn't remove the scenario: 1 scenario forks from this one: remove it first", flash[:alert]

      delete plan_scenario_path(@plan_id, @plan_id)
      assert_equal "Couldn't remove the scenario: The baseline can't be removed", flash[:alert]
      assert scenario_named("Q1 hires")
    end

    should "offer Remove for each scenario but the baseline, and name only the scenarios that block one" do
      get plan_path(@plan_id)

      assert_select "[role=menuitem][data-modal-target-id='remove-scenario-#{@lean}']", text: "Remove…"
      assert_select "[data-modal-target-id='remove-scenario-#{@plan_id}']", count: 0
      assert_select "#remove-scenario-#{@lean}" do
        assert_select "h2, h3", text: "Remove Lean Q1?"
        assert_select "p", text: /\AIt holds no changes\. It can't be restored/
        assert_select "form[action='#{plan_scenario_path(@plan_id, @lean)}'] button[type=submit]", text: "Remove scenario"
      end
      assert_select "#remove-scenario-#{@q1}" do
        assert_select "p", text: "1 scenario forks from it: Lean Q1. Remove that first."
        assert_select "form", count: 0
      end

      get map_plan_path(@plan_id, scenario: @lean)
      assert_select "button[data-modal-target-id='remove-scenario-#{@lean}']", text: "Remove…"
      assert_select "#remove-scenario-#{@lean}"
      assert_select "#remove-scenario-#{@q1}", count: 0
    end

    should "open the map's Remove dialog from a link whose id is in capitals" do
      get map_plan_path(@plan_id, scenario: @lean.upcase)

      assert_select "button[data-modal-target-id='remove-scenario-#{@lean}']", text: "Remove…"
      assert_select "#remove-scenario-#{@lean}"
    end

    should "count the changes that go with it" do
      TeamPlanning::RuleKinds.register(HeadcountCap)
      ActsAsTenant.with_tenant(@tenant) do
        TeamPlanning::CommandHandler.new(actor: AuthorizationContext.new(user: @editor.user, tenant_user: @editor, person: @editor.person))
          .set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id: @lean, subject_id: @plan_id,
                                                               end_state: { rule: HeadcountCap.rule_name, value: { cap: 8 } })
      end
      get plan_path(@plan_id)
      assert_select "#remove-scenario-#{@lean} p", text: /\AIts 1 change goes with it\./
    ensure
      TeamPlanning::RuleKinds.unregister(HeadcountCap)
    end

    should "offer no Remove once the plan is archived" do
      ActsAsTenant.with_tenant(@tenant) { call(Operations::TeamPlanning::ArchivePlan, @editor, plan_id: @plan_id) }

      get plan_path(@plan_id)
      assert_select "[id^='remove-scenario-']", count: 0
      assert_select "[data-modal-target-id^='remove-scenario-']", count: 0
      get map_plan_path(@plan_id, scenario: @lean)
      assert_select "[data-modal-target-id^='remove-scenario-']", count: 0
    end
  end

  context "a viewer" do
    setup { sign_in @viewer.user }

    should "be refused a removal, and offered no Remove" do
      delete plan_scenario_path(@plan_id, @q1)
      assert_redirected_to root_path
      assert scenario_named("Q1 hires")

      get plan_path(@plan_id)
      assert_select "[id^='remove-scenario-']", count: 0
    end

    should "be refused a fork and an edit" do
      post plan_scenarios_path(@plan_id), params: { scenario: { parent_id: @q1, relation: "then", name: "Q2 hires", ends_on: "2027-06-30" } }
      assert_redirected_to root_path
      patch plan_scenario_path(@plan_id, @q1), params: { scenario: { name: "Lean Q1", description: "Mine" } }
      assert_redirected_to root_path

      assert_nil scenario_named("Q1 hires").description&.reveal
      assert_nil scenario_named("Q2 hires")
      assert_nil scenario_named("Lean Q1")
    end

    should "not be offered the controls" do
      get plan_path(@plan_id)
      assert_select "button", text: "New scenario", count: 0
      assert_select "[data-modal-target-id]", count: 0

      get map_plan_path(@plan_id, scenario: @q1)
      assert_select "button", text: "Edit…", count: 0
    end
  end

  should "give someone outside the plan a 404, even a tenant admin" do
    sign_in @outsider.user
    get plans_path # an error response sets no session cookie, so the sign-in must land first
    post plan_scenarios_path(@plan_id), params: { scenario: { parent_id: @q1, relation: "then", name: "Q2 hires", ends_on: "2027-06-30" } }
    assert_response :not_found
    patch plan_scenario_path(@plan_id, @q1), params: { scenario: { name: "Lean Q1" } }
    assert_response :not_found
    delete plan_scenario_path(@plan_id, @q1)
    assert_response :not_found
  end

  private

  def scenario_named(name)
    ActsAsTenant.with_tenant(@tenant) { TeamPlanningScenario.where(plan_id: @plan_id).find { it.name&.reveal == name } }
  end

  def account(role: :member, name: "Someone", **grants)
    user = create(:user)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, role:, person:, **grants)
  end

  def call(operation, account, **params)
    context = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)
    operation.call(context:, params:)
  end
end
