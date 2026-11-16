# frozen_string_literal: true

require "test_helper"

class Plans::FundingsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    payments = SecureRandom.uuid_v7
    level = SecureRandom.uuid_v7
    travel_to Time.utc(2026, 11, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @outsider = account(role: :admin, name: "Ada Admin")
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.define_taxonomy([ { level_id: level, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(payments, "Payments", level_id: level, effective_on: "2026-01-01")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Pay review 2027", base_on: "2026-11-14")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                  ends_on: "2027-03-31")[:scenario_id]
      role = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      level = create(:framework_level, tenant: @tenant, role_id: role.role_id, ordinal: 2, title: "Engineer II")
      @platform = budget_line("Platform")
      @growth = budget_line("Growth")
      @position = call(Operations::TeamPlanning::SetPosition, @editor, plan_id: @plan_id, scenario_id: @q1, role_id: role.role_id,
                                                                     level_id: level.level_id, unit_id: payments, fte: 1, basis: "new")[:position_id]
    end
  end

  context "an editor" do
    setup { sign_in @editor.user }

    should "be offered Funding… on a scenario, with the position's lines and shares and no amount" do
      get budget_plan_path(@plan_id, scenario: @q1)

      assert_select "#funding-modal [data-funding-line='#{@platform}']", text: /Cost centre Platform/
      assert_select "#funding-modal input[name=?]", "funding[parts][#{@growth}]"
      assert_select "[data-funding-action=?]", plan_funding_path(@plan_id, @position)
      css_select("[data-funding-action]").each { assert_no_match(/\d{4}/, it["data-funding-draws"].gsub(/[0-9a-f-]{36}/, "")) }

      get budget_plan_path(@plan_id)
      assert_select "#funding-modal", count: 0
    end

    should "set one line to fund the whole position" do
      patch plan_funding_path(@plan_id, @position), params: { scenario_id: @q1, funding: { parts: { @platform => "100", @growth => "" } } }

      assert_redirected_to budget_plan_path(@plan_id, scenario: @q1)
      assert_equal "Funding set.", flash[:notice]
      assert_equal [ [ @platform, "1" ] ], draws
      assert_equal "set", funding[:source]
    end

    should "split the position between two lines" do
      patch plan_funding_path(@plan_id, @position), params: { scenario_id: @q1, funding: { parts: { @platform => "60", @growth => "40%" } } }

      assert_equal "Funding set.", flash[:notice]
      assert_equal [ [ @growth, "0.4" ], [ @platform, "0.6" ] ].sort, draws.sort
    end

    should "hand the funding back to the line the plan finds" do
      patch plan_funding_path(@plan_id, @position), params: { scenario_id: @q1, funding: { parts: { @growth => "100" } } }
      delete plan_funding_path(@plan_id, @position), params: { scenario_id: @q1 }

      assert_redirected_to budget_plan_path(@plan_id, scenario: @q1)
      assert_equal "Funding goes back to the line the plan finds.", flash[:notice]
      assert_equal "derived", funding[:source]
    end

    should "offer Clear only where this scenario sets the funding, not where it follows another's" do
      patch plan_funding_path(@plan_id, @position), params: { scenario_id: @q1, funding: { parts: { @growth => "100" } } }
      q2 = ActsAsTenant.with_tenant(@tenant) do
        call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2 hires",
                                                              ends_on: "2027-06-30")[:scenario_id]
      end

      get budget_plan_path(@plan_id, scenario: @q1)
      assert_select "[data-funding-action][data-funding-set=?]", "true"

      get budget_plan_path(@plan_id, scenario: q2)
      assert_select "[data-funding-action]"
      assert_select "[data-funding-set=?]", "true", count: 0
    end

    should "say why it refused parts that don't add up, or that aren't percentages" do
      patch plan_funding_path(@plan_id, @position), params: { scenario_id: @q1, funding: { parts: { @platform => "60", @growth => "30" } } }
      assert_equal "Couldn't set the funding: The parts add up to 100", flash[:alert]

      [ { @platform => "half", @growth => "50" }, { @platform => "150", @growth => "50" }, { @platform => "lots" } ].each do |parts|
        patch plan_funding_path(@plan_id, @position), params: { scenario_id: @q1, funding: { parts: } }
        assert_equal "Couldn't set the funding: Each part is a percentage above 0 and at most 100, such as 50", flash[:alert]
      end

      patch plan_funding_path(@plan_id, @position), params: { scenario_id: @q1, funding: { parts: { @platform => "", @growth => "0" } } }
      assert_equal "Couldn't set the funding: Give at least one line a part", flash[:alert]
      assert_equal "derived", funding[:source]
    end

    should "refuse Today" do
      patch plan_funding_path(@plan_id, @position), params: { scenario_id: @plan_id, funding: { parts: { @platform => "100" } } }

      assert_redirected_to budget_plan_path(@plan_id, scenario: @plan_id)
      assert_match(/\ACouldn't set the funding: /, flash[:alert])
    end
  end

  context "a viewer" do
    setup { sign_in @viewer.user }

    should "be refused and offered no Funding…" do
      get budget_plan_path(@plan_id, scenario: @q1)
      assert_select "#funding-modal", count: 0
      assert_select "[data-funding-action]", count: 0

      patch plan_funding_path(@plan_id, @position), params: { scenario_id: @q1, funding: { parts: { @platform => "100" } } }
      assert_redirected_to root_path
      assert_equal "derived", funding[:source]
    end
  end

  should "give someone outside the plan a 404, even a tenant admin" do
    sign_in @outsider.user
    patch plan_funding_path(@plan_id, @position), params: { scenario_id: @q1, funding: { parts: { @platform => "100" } } }
    assert_response :not_found
  end

  private

  def budget_line(cost_centre)
    BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2027-12-31", origin: "new", amount: 80_000, currency: "AUD",
                       period: "year", cost_centre:).id
  end

  def funding
    ActsAsTenant.with_tenant(@tenant) do
      call(Operations::TeamPlanning::Funding, @editor, plan_id: @plan_id, scenario_id: @q1)[:positions].find { it[:position_id] == @position }
    end
  end

  def draws = funding[:draws].map { [ it[:budget_line_id], it[:share] ] }

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
