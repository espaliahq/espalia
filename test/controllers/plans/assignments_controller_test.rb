# frozen_string_literal: true

require "test_helper"

class Plans::AssignmentsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  ESPALIA = { provider: "espalia" }.freeze

  setup do
    @tenant = create(:tenant)
    @payments = SecureRandom.uuid_v7
    @growth = SecureRandom.uuid_v7
    @level = level = SecureRandom.uuid_v7
    travel_to Time.utc(2026, 11, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @outsider = account(role: :admin, name: "Ada Admin")
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.define_taxonomy([ { level_id: level, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: level, effective_on: "2026-01-01")
      structure.create_unit(@growth, "Growth", level_id: level, effective_on: "2026-01-01")
      graph = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      graph.record_person(@ada.id, **ESPALIA, effective_on: "2026-01-02", employment_status: "employed")
      graph.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-01-02", allocation: 1.0)
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Pay review 2027", base_on: "2026-11-14")[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      @q1 = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                  ends_on: "2027-03-31")[:scenario_id]
    end
  end

  def move(scenario_id: @q1, return_to: nil, **fields)
    patch plan_assignment_path(@plan_id, @ada.id),
          params: { move: { scenario_id:, from_unit_id: @payments, to: @growth, allocation: "60", role: "Lead", **fields }, return_to: }.compact
  end

  context "an editor" do
    setup { sign_in @editor.user }

    should "move a person in the scenario shown and land back on its map" do
      move

      assert_redirected_to map_plan_path(@plan_id, scenario: @q1)
      assert_equal "Move saved.", flash[:notice]
      assert_equal [ { unit_id: @growth, allocation: 0.6, role: "Lead" } ], places(@q1)
    end

    should "drop a place on Unassigned, ignoring the allocation the hidden field still holds" do
      move(to: "unassigned")

      assert_empty places(@q1)
    end

    should "place a person in a position the form names as a choice" do
      position = ActsAsTenant.with_tenant(@tenant) do
        role = create(:framework_role, tenant: @tenant, name: "Software Engineer")
        level = create(:framework_level, tenant: @tenant, role_id: role.role_id, ordinal: 2, title: "Engineer II")
        call(Operations::TeamPlanning::SetPosition, @editor, plan_id: @plan_id, scenario_id: @q1, role_id: role.role_id,
                                                            level_id: level.level_id, unit_id: @growth, fte: 1, basis: "new")[:position_id]
      end

      move(to: Views::Plans::MoveDialog.position_choice(position))

      assert_equal "Move saved.", flash[:notice]
      assert_equal [ { unit_id: @growth, allocation: 0.6, role: "Lead" } ], places(@q1)
      get map_plan_path(@plan_id, scenario: @q1)
      assert_select "[data-map-position='#{position}'] [data-map-occupant='#{@ada.id}']"
    end

    should "name each position choice by its level, and number ones that still read alike as the map does" do
      ActsAsTenant.with_tenant(@tenant) do
        role = create(:framework_role, tenant: @tenant, name: "Software Engineer")
        level = create(:framework_level, tenant: @tenant, role_id: role.role_id, ordinal: 2, title: "Engineer II")
        2.times do
          call(Operations::TeamPlanning::SetPosition, @editor, plan_id: @plan_id, scenario_id: @q1, role_id: role.role_id,
                                                              level_id: level.level_id, unit_id: @growth, fte: 1, basis: "new")
        end
      end

      get map_plan_path(@plan_id, scenario: @q1)

      choices = css_select("#move-to option[value^='#{Views::Plans::MoveDialog::POSITION}']")
      assert_equal [ "Growth › New position: Software Engineer (1) · Engineer II", "Growth › New position: Software Engineer (2) · Engineer II" ],
                   choices.map(&:text)
      choices.each_with_index do |choice, index|
        position = choice["value"].delete_prefix(Views::Plans::MoveDialog::POSITION)
        assert_select "[data-map-position='#{position}'] span.font-medium", text: "New position: Software Engineer (#{index + 1})"
        assert_select "[data-map-position='#{position}'] button[aria-label='Move New position: Software Engineer (#{index + 1}) in Growth']"
      end
    end

    should "land back on the timeline step it came from" do
      back = timeline_plan_path(@plan_id, scenario: @q1, step: 1)
      move(return_to: back)

      assert_redirected_to back
      assert_equal "Move saved.", flash[:notice]
    end

    should "say on the timeline why a move was refused" do
      back = timeline_plan_path(@plan_id, step: 1)
      move(scenario_id: @plan_id, return_to: back)

      assert_redirected_to back
      assert_match "Today can't be edited", flash[:alert]
    end

    should "ignore a return_to that leaves this plan's timeline" do
      [ "https://example.com/planning", plan_path(@plan_id), "//example.com#{timeline_plan_path(@plan_id)}", "http://[bad" ].each do |back|
        move(return_to: back)

        assert response.location.start_with?(map_plan_url(@plan_id)), "#{back} sent the move to #{response.location}"
      end
    end

    should "start someone in a position on its unit in the timeline's dialog, which lists units only" do
      position = ActsAsTenant.with_tenant(@tenant) do
        role = create(:framework_role, tenant: @tenant, name: "Software Engineer")
        level = create(:framework_level, tenant: @tenant, role_id: role.role_id, ordinal: 2, title: "Engineer II")
        call(Operations::TeamPlanning::SetPosition, @editor, plan_id: @plan_id, scenario_id: @q1, role_id: role.role_id,
                                                            level_id: level.level_id, unit_id: @growth, fte: 1, basis: "new")[:position_id]
      end
      move(to: Views::Plans::MoveDialog.position_choice(position))

      get timeline_plan_path(@plan_id)

      assert_select "button[data-modal-target-id='move-person-modal-1'][data-move-from-position='#{position}'][data-move-at='#{@growth}']"
    end

    should "keep the share a place with no allocation takes beside another in the timeline's dialog" do
      ActsAsTenant.with_tenant(@tenant) do
        graph = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        graph.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-01-03", allocation: nil)
        graph.set_membership(@ada.id, @growth, **ESPALIA, effective_on: "2026-01-03", allocation: nil)
      end
      @plan_id = ActsAsTenant.with_tenant(@tenant) { call(Operations::TeamPlanning::CreatePlan, @editor, name: "Split", base_on: "2026-11-14")[:plan_id] }
      ActsAsTenant.with_tenant(@tenant) do
        call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2027-03-31")
      end

      get timeline_plan_path(@plan_id)

      [ @payments, @growth ].each do |unit|
        assert_select "button[data-modal-target-id='move-person-modal-1'][data-move-from='#{unit}'][data-move-allocation='50']"
      end
    end

    should "count a place in a retired unit in the share the timeline's dialog keeps, as the map does" do
      retired = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        structure.create_unit(retired, "Legacy", level_id: @level, effective_on: "2026-01-01")
        graph = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        graph.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-01-03", allocation: nil)
        graph.set_membership(@ada.id, retired, **ESPALIA, effective_on: "2026-01-03", allocation: 0.5)
        @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Retiring", base_on: "2026-11-14")[:plan_id]
        q1 = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2027-03-31")[:scenario_id]
        call(Operations::TeamPlanning::RetireUnit, @editor, plan_id: @plan_id, scenario_id: q1, unit_id: retired)
      end

      get timeline_plan_path(@plan_id)

      assert_select "button[data-modal-target-id='move-person-modal-1'][data-move-from='#{@payments}'][data-move-allocation='50']"
    end

    should "give each step on the timeline its own move dialog and field ids" do
      get timeline_plan_path(@plan_id)

      assert_select "#move-person-modal-1 select#move-to-1"
      assert_select "#move-person-modal-1 input[name='return_to'][value='#{timeline_plan_path(@plan_id, scenario: @q1, step: 0)}']"
      assert_select "#move-person-modal-0", count: 0
      assert_select "#move-person-modal", count: 0
    end

    should "refuse Today and say why" do
      move(scenario_id: @plan_id)

      assert_redirected_to map_plan_path(@plan_id)
      assert_equal "Couldn't move them: Today can't be edited. Fork a scenario and edit that.", flash[:alert]
      assert_equal [ @payments ], places(@plan_id).pluck(:unit_id)
    end

    should "be offered Move on a scenario's map and not on Today's" do
      get map_plan_path(@plan_id, scenario: @q1)
      assert_select "li[data-map-person='#{@ada.id}'][draggable='true'] button[data-move-from='#{@payments}']", text: "Move…"
      assert_select "form[data-controller='move-form'] strong", text: "Q1 hires"

      get map_plan_path(@plan_id)
      assert_select "button", text: "Move…", count: 0
      assert_select "[draggable]", count: 0
    end
  end

  context "a viewer" do
    setup { sign_in @viewer.user }

    should "be refused a move and offered no handles" do
      move
      assert_redirected_to root_path
      assert_equal [ @payments ], places(@q1).pluck(:unit_id)

      get map_plan_path(@plan_id, scenario: @q1)
      assert_select "button", text: "Move…", count: 0
      assert_select "[draggable]", count: 0
    end
  end

  should "give someone outside the plan a 404, even a tenant admin" do
    sign_in @outsider.user
    get plans_path
    move
    assert_response :not_found
  end

  private

  def places(scenario_id)
    ActsAsTenant.with_tenant(@tenant) do
      call(Operations::TeamPlanning::ScenarioMap, @editor, plan_id: @plan_id, scenario_id:)[:people]
        .find { it[:id] == @ada.id }[:memberships].map { it.slice(:unit_id, :allocation, :role).compact }
    end
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
