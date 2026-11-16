# frozen_string_literal: true

require "test_helper"

class Plans::SplitControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      squads = SecureRandom.uuid_v7
      @pods = SecureRandom.uuid_v7
      @payments = SecureRandom.uuid_v7
      org = OrgGraph::CommandHandler.new(actor: SYSTEM)
      structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      @brook = create(:person, tenant: @tenant, name: "Brook Tamsin")
      structure.define_taxonomy([ { level_id: squads, name: "Squad" }, { level_id: @pods, name: "Pod" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: squads, effective_on: "2026-01-01")
      [ @ada, @brook ].each do
        org.record_person(it.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", title: "Engineer")
        org.set_membership(it.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
      end

      @editor = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @outsider = account(role: :admin, name: "Olly Outsider")
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Next year", base_on: "2026-03-02")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                  ends_on: "2026-06-30")[:scenario_id]
      @creates = planned(Operations::TeamPlanning::SetUnit, name: "Platform", top_level: true, level_id: squads)
      @platform = TeamPlanningOverride.find_by!(event_id: @creates).subject_id
      @to_platform = place(@brook, @platform)
      @to_payments = place(@ada, @payments)
    end
  end

  context "an editor" do
    setup { sign_in @editor.user }

    should "find the split in a scenario's menu, never the baseline's" do
      get plan_path(@plan_id)

      assert_select "a[href='#{split_plan_path(@plan_id, scenario_id: @q1)}']", text: "Split off the agreed part…"
      assert_select "a[href='#{split_plan_path(@plan_id, scenario_id: @plan_id)}']", count: 0
    end

    should "open a page that names the scenario and lists each change with what it needs" do
      get split_plan_path(@plan_id, scenario_id: @q1)

      assert_response :success
      assert_select "h3", text: "Split Q1 hires"
      assert_select "input[name='event_ids[]']", count: 3
      assert_select "[data-split-change='#{@to_platform}'] [data-split-needs]", text: /needs Platform: Unit/
      assert_select "[data-split-change='#{@to_payments}'] [data-split-needs]", count: 0
      assert_select "input[name='name'][value='Q1 hires, agreed part']"
      assert_select "button[type='submit']", text: "Split off the chosen changes"
    end

    should "say a scenario with one change has nothing to split off, and offer no form" do
      solo = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q3 move",
                                                                   parent_id: @q1, ends_on: "2026-09-30")[:scenario_id]
      call(Operations::TeamPlanning::SetAssignment, @editor, plan_id: @plan_id, scenario_id: solo, person_id: @ada.id,
                                                             placements: [ { unit_id: @payments, allocation: 0.5 } ])

      get split_plan_path(@plan_id, scenario_id: solo)

      assert_select "h3", text: "Split Q3 move"
      assert_select "p", text: /Q3 move makes one change, so there is nothing to split off/
      assert_select "input[name='event_ids[]']", count: 0
    end

    should "follow a need through to what it needs in turn" do
      core = call(Operations::TeamPlanning::SetUnit, @editor, plan_id: @plan_id, scenario_id: @q1, name: "Core",
                                                              parent_id: @platform, level_id: @pods)[:unit_id]
      to_core = place(@ada, core)

      get split_plan_path(@plan_id, scenario_id: @q1)
      assert_select "[data-split-change='#{to_core}'] [data-split-needs]", text: /It needs Core: Unit and Platform: Unit, so choose those changes too/

      post split_plan_path(@plan_id, scenario_id: @q1), params: { event_ids: [ to_core ], name: "Agreed moves" }
      assert_select "[role='alert']", text: /Ada Quill: Placement needs Core: Unit, which you left behind. Ada Quill: Placement needs Platform: Unit/
    end

    should "say when every part would take all the changes or leave a need behind, and offer no form" do
      stuck = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q3 move",
                                                                    parent_id: @q1, ends_on: "2026-09-30")[:scenario_id]
      unit = call(Operations::TeamPlanning::SetUnit, @editor, plan_id: @plan_id, scenario_id: stuck, name: "Edge", top_level: true,
                                                              level_id: @pods)[:unit_id]
      [ @ada, @brook ].each do
        call(Operations::TeamPlanning::SetAssignment, @editor, plan_id: @plan_id, scenario_id: stuck, person_id: it.id,
                                                               placements: [ { unit_id: unit, allocation: 1.0 } ])
      end
      call(Operations::TeamPlanning::ClearChange, @editor, plan_id: @plan_id, scenario_id: stuck, subject_id: unit, facet: "unit")

      get split_plan_path(@plan_id, scenario_id: stuck)

      assert_select "p", text: /Every part of Q3 move you could split off would take all its changes with it/
      assert_select "input[name='event_ids[]']", count: 0
    end

    should "split the chosen changes off and land on the agreed part, in its own step on a phone" do
      post split_plan_path(@plan_id, scenario_id: @q1), params: { event_ids: [ @to_payments ], name: "Agreed moves" }

      agreed = ActsAsTenant.with_tenant(@tenant) { TeamPlanningScenario.where(plan_id: @plan_id).order(:created_at).last.id }
      assert_redirected_to timeline_plan_path(@plan_id, scenario: agreed, step: 1)
      assert_equal "Split 1 change off into Agreed moves.", flash[:notice]
    end

    should "still land on the agreed part when the timeline can't be read after the split" do
      Operations::TeamPlanning::Timeline.stub(:call, ->(**) { raise Operations::Base::ParameterError, "No such plan" }) do
        post split_plan_path(@plan_id, scenario_id: @q1), params: { event_ids: [ @to_payments ], name: "Agreed moves" }
      end

      agreed = ActsAsTenant.with_tenant(@tenant) { TeamPlanningScenario.where(plan_id: @plan_id).order(:created_at).last.id }
      assert_redirected_to timeline_plan_path(@plan_id, scenario: agreed)
      assert_equal "Split 1 change off into Agreed moves.", flash[:notice]
    end

    should "count the changes chosen in its notice, not the earlier ones that go across with them" do
      again = place(@ada, @platform)

      post split_plan_path(@plan_id, scenario_id: @q1), params: { event_ids: [ again, @creates ], name: "Agreed moves" }

      assert_equal "Split 2 changes off into Agreed moves.", flash[:notice]
    end

    should "split the agreed part again, so agreement can come in stages" do
      post split_plan_path(@plan_id, scenario_id: @q1), params: { event_ids: [ @creates, @to_platform ], name: "Agreed moves" }
      agreed = ActsAsTenant.with_tenant(@tenant) { TeamPlanningScenario.where(plan_id: @plan_id).order(:created_at).last.id }

      get split_plan_path(@plan_id, scenario_id: agreed)
      assert_select "h3", text: "Split Agreed moves"
      assert_select "input[name='event_ids[]']", count: 2

      post split_plan_path(@plan_id, scenario_id: agreed), params: { event_ids: [ @creates ], name: "Agreed unit" }
      first = ActsAsTenant.with_tenant(@tenant) { TeamPlanningScenario.where(plan_id: @plan_id).order(:created_at).last.id }
      assert_not_equal agreed, first
      assert_redirected_to timeline_plan_path(@plan_id, scenario: first, step: 1)
      assert_equal "Split 1 change off into Agreed unit.", flash[:notice]
    end

    should "show a refused split again with the operation's reason and the choice kept" do
      post split_plan_path(@plan_id, scenario_id: @q1), params: { event_ids: [ @to_platform ], name: "Agreed moves" }

      assert_response :unprocessable_content
      assert_select "[role='alert']", text: /Brook Tamsin: Placement needs Platform: Unit, which you left behind/
      assert_select "[role='alert']", text: /#{Regexp.escape(@creates)}/, count: 0
      assert_select "input[value='#{@to_platform}'][checked]"
      assert_select "input[value='#{@creates}']:not([checked])"
      assert_select "input[name='name'][value='Agreed moves']"
      assert_select "button[type='submit']", text: "Split off 1 change"
    end

    should "open the page from a link that names the scenario in capitals" do
      get split_plan_path(@plan_id, scenario_id: @q1.upcase)

      assert_response :success
      assert_select "h3", text: "Split Q1 hires"
    end

    should "refuse a change that is no longer in the scenario, keep the choice and split nothing" do
      stale = SecureRandom.uuid_v7
      scenarios = -> { ActsAsTenant.with_tenant(@tenant) { TeamPlanningScenario.where(plan_id: @plan_id).count } }

      assert_no_difference(scenarios) do
        post split_plan_path(@plan_id, scenario_id: @q1), params: { event_ids: [ @to_payments, stale ], name: "Agreed moves" }
      end

      assert_response :unprocessable_content
      assert_select "[role='alert']", text: /This scenario has no change #{stale} in effect to move/
      assert_select "input[value='#{@to_payments}'][checked]"
      assert_select "input[name='name'][value='Agreed moves']"
    end

    should "never draw a change that can't go across as chosen, nor count it on the button" do
      call(Operations::TeamPlanning::ClearChange, @editor, plan_id: @plan_id, scenario_id: @q1, subject_id: @platform, facet: "unit")

      post split_plan_path(@plan_id, scenario_id: @q1), params: { event_ids: [ @to_platform, @to_payments ], name: "Agreed moves" }

      assert_response :unprocessable_content
      assert_select "input[value='#{@to_platform}'][disabled]:not([checked])"
      assert_select "input[value='#{@to_payments}'][checked]"
      assert_select "button[type='submit']", text: "Split off 1 change"
    end

    should "refuse the baseline with the operation's words" do
      refusal = assert_raises(Operations::Base::ParameterError) do
        call(Operations::TeamPlanning::SplitScenario, @editor, plan_id: @plan_id, scenario_id: @plan_id, event_ids: [ @to_payments ], name: "X")
      end

      get split_plan_path(@plan_id, scenario_id: @plan_id)
      assert_redirected_to plan_path(@plan_id)
      assert_equal "Can't split this scenario: #{refusal.message}", flash[:alert]

      post split_plan_path(@plan_id, scenario_id: @plan_id), params: { event_ids: [ @to_payments ], name: "X" }
      assert_redirected_to plan_path(@plan_id)
      assert_equal "Couldn't split the scenario: #{refusal.message}", flash[:alert]
    end
  end

  should "list a pay change to an editor without see-pay by its facet alone, and let them split it off" do
    amount = "92417"
    other_editor = account(name: "Pat Planner")
    pay = ActsAsTenant.with_tenant(@tenant) do
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: other_editor.person_id, role: "editor")
      planned(Operations::TeamPlanning::SetActualPay, person_id: @ada.id, amount:, currency: "AUD", period: "year", basis: "full_time")
    end
    sign_in other_editor.user

    get split_plan_path(@plan_id, scenario_id: @q1)
    assert_select "[data-split-change='#{pay}'] label", text: "Ada Quill: Pay"
    assert_not_includes response.body, amount

    post split_plan_path(@plan_id, scenario_id: @q1), params: { event_ids: [ pay ], name: "Agreed pay" }
    assert_equal "Split 1 change off into Agreed pay.", flash[:notice]
  end

  should "refuse a frozen plan's members with the operation's words" do
    ActsAsTenant.with_tenant(@tenant) { @editor.person.update!(status: "inactive") }
    refusal = assert_raises(Operations::Base::ParameterError) do
      call(Operations::TeamPlanning::SplitScenario, @viewer, plan_id: @plan_id, scenario_id: @q1, event_ids: [ @to_payments ], name: "X")
    end
    sign_in @viewer.user

    post split_plan_path(@plan_id, scenario_id: @q1), params: { event_ids: [ @to_payments ], name: "X" }

    assert_redirected_to plan_path(@plan_id)
    assert_equal "Couldn't split the scenario: #{refusal.message}", flash[:alert]
  end

  should "keep a viewer out of the page and its menu entry" do
    sign_in @viewer.user

    get plan_path(@plan_id)
    assert_select "a[href='#{split_plan_path(@plan_id, scenario_id: @q1)}']", count: 0

    get split_plan_path(@plan_id, scenario_id: @q1)
    assert_redirected_to root_path
  end

  should "give anyone outside the plan a 404" do
    sign_in @outsider.user
    get split_plan_path(@plan_id, scenario_id: @q1)
    assert_response :not_found

    sign_in @outsider.user
    post split_plan_path(@plan_id, scenario_id: @q1), params: { event_ids: [ @to_payments ], name: "X" }
    assert_response :not_found
  end

  private

  def planned(operation, **params)
    call(operation, @editor, plan_id: @plan_id, scenario_id: @q1, **params)
    call(Operations::TeamPlanning::History, @editor, plan_id: @plan_id, scenario_id: @q1)[:entries].last[:event_id]
  end

  def place(person, unit_id) = planned(Operations::TeamPlanning::SetAssignment, person_id: person.id, placements: [ { unit_id:, allocation: 1.0 } ])

  def account(role: :member, name: "Someone", **grants)
    user = create(:user)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, role:, person:, **grants)
  end

  def call(operation, account, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person), params:)
    end
  end
end
