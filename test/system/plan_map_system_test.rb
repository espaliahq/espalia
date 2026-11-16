# frozen_string_literal: true

require "application_system_test_case"

class PlanMapSystemTest < ApplicationSystemTestCase
  ESPALIA = { provider: "espalia" }.freeze

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    since = (Date.current - 30).iso8601
    group = SecureRandom.uuid_v7
    @team = team = SecureRandom.uuid_v7
    @product = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7
    @growth = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(@tenant) do
      @planner = account(team_planner: true, name: "Erin Editor")
      @viewer = account(name: "Vic Viewer")
      @outsider = account(name: "Olly Outsider")
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      @bo = create(:person, tenant: @tenant, name: "Bo Reyes")
      @cy = create(:person, tenant: @tenant, name: "Cy Loose")
      @engineer = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      e2 = create(:framework_level, tenant: @tenant, role_id: @engineer.role_id, ordinal: 2, title: "Engineer II")
      @level_id = e2.level_id

      structure.define_taxonomy([ { level_id: group, name: "Group" }, { level_id: team, name: "Team" } ], effective_on: since)
      structure.create_unit(@product, "Product", level_id: group, effective_on: since)
      structure.create_unit(@payments, "Payments", level_id: team, parent_id: @product, effective_on: since)
      structure.create_unit(@growth, "Growth", level_id: team, parent_id: @product, effective_on: since)
      handler.record_person(@ada.id, **ESPALIA, effective_on: since, employment_status: "employed", fte: 0.8)
      handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: since, allocation: 1.0, role: "ENG")
      handler.record_person(@bo.id, **ESPALIA, effective_on: since, employment_status: "employed")
      handler.set_membership(@bo.id, @payments, **ESPALIA, effective_on: since, allocation: 0.5, role: "PM")
      handler.record_person(@cy.id, **ESPALIA, effective_on: since, employment_status: "employed")
    end

    # The baseline reads the Org Graph as known the day before the base date, so a plan based tomorrow sees today's facts.
    @plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Pay review 2027", base_on: (Date.current + 1).iso8601)[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, @planner, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
    @q1 = call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                 ends_on: (Date.current + 120).iso8601)[:scenario_id]
    call(Operations::TeamPlanning::SetAssignment, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @bo.id,
                                                            placements: [ { unit_id: @growth, allocation: 1, role: "PM" } ])
    call(Operations::TeamPlanning::SetPosition, @planner, plan_id: @plan_id, scenario_id: @q1, role_id: @engineer.role_id,
                                                          level_id: @level_id, unit_id: @growth, fte: 1, basis: "new")
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "show a viewer today's organisation from the plan's Today row" do
        sign_in_as(@viewer.user)
        visit plan_path(@plan_id)
        click_link_with_js_fallback("Today", expect_text: "as known on")

        within(unit("Payments")) do
          assert_text "Product"
          assert_text "2 people"
          assert_text "100%"
          assert_text "Ada Quill"
          assert_text "50%"
          assert_text "Bo Reyes"
        end
        within(unit("Growth")) { assert_text "Nobody yet." }
        within(unit("Unassigned")) { assert_text "Cy Loose" }
        assert_no_sideways_overflow
      end

      should "show a scenario's moves and open positions" do
        sign_in_as(@viewer.user)
        visit map_plan_path(@plan_id)
        switch_to("Q1 hires")

        within(unit("Payments")) { assert_no_text "Bo Reyes" }
        within(unit("Growth")) do
          assert_text "Bo Reyes"
          assert_text "New position: Software Engineer"
          assert_text "1.0 FTE open"
        end
        assert_no_sideways_overflow
      end

      should "fit a full unit with a long role on one line a person, with what was cut reachable" do
        plan_id, scenario_id = plan_with_a_full_unit
        sign_in_as(@planner.user)
        visit map_plan_path(plan_id)

        cards = page.evaluate_script(<<~JS)
          [...document.querySelectorAll("[data-map-unit]")].map((card) => [Math.round(card.getBoundingClientRect().left), Math.round(card.getBoundingClientRect().width)])
        JS
        assert_equal 1, cards.map(&:last).uniq.size, "a full unit's card is as wide as the rest: #{cards.inspect}"
        assert_operator cards.map(&:first).uniq.size, :>=, 3, "three units a row at 1400px: #{cards.inspect}" if label == "desktop"
        within(unit("Platform")) do
          assert_selector "[data-map-person]", count: 12
          heights = all("[data-map-person]").map { it.evaluate_script("this.getBoundingClientRect().height") }
          assert heights.all? { it < 40 }, "each person takes one line: #{heights.inspect}"
          find("summary", text: LONG_NAME).click
          within("details[open]") do
            assert_text LONG_ROLE
            assert_text LONG_NAME
          end
        end
        assert_no_sideways_overflow

        visit map_plan_path(plan_id, scenario: scenario_id)
        within(unit("Platform")) do
          assert_selector "[data-map-person] button", text: "Move…", count: 13
          widths = all("[data-map-person-details]").map { it.evaluate_script("this.getBoundingClientRect().width") }
          assert widths.all? { it >= 96 }, "a name keeps 6rem beside Move…: #{widths.inspect}"
          card = current_scope.evaluate_script("this.getBoundingClientRect().right")
          label = find("[data-map-position] span", text: LONG_POSITION_ROLE).evaluate_script("this.getBoundingClientRect().right")
          assert_operator label, :<=, card, "a one-word position label wraps inside its card"
          occupant = find("[data-map-occupant]", text: LONG_OCCUPANT).evaluate_script("this.getBoundingClientRect().right")
          assert_operator occupant, :<=, card, "a one-word occupant name wraps inside its card"
        end
        assert_no_sideways_overflow
      end

      should "name a forgotten person as a former member" do
        ActsAsTenant.with_tenant(@tenant) do
          @ada.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current)
        end
        sign_in_as(@viewer.user)
        visit map_plan_path(@plan_id)

        within(unit("Payments")) do
          assert_text "Former member"
          assert_no_text "Ada Quill"
        end
      end

      should "show an outsider no map" do
        sign_in_as(@outsider.user)
        visit map_plan_path(@plan_id)
        # The test environment shows Rails' error page, so the 404 reads as the exception that makes one.
        assert_text "ActiveRecord::RecordNotFound"
        [ "Pay review 2027", "Payments", "Ada Quill" ].each { assert_no_text it }
      end
    end
  end

  private

  LONG_ROLE = "Infrastructure reliability"
  LONG_NAME = "Maximiliana Wolkenstein-Abernathy-Okonkwo"
  LONG_POSITION_ROLE = "Observabilityplatformengineeringandreliabilityoperations"
  LONG_OCCUPANT = "Quillonmarabethwintersongvalerandorffquantelbrook"

  # Twelve seats, one person with a long name, all under a role too long for its column, and a one-word position, filled by a one-word name, in the scenario.
  def plan_with_a_full_unit
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    since = (Date.current - 30).iso8601
    platform = SecureRandom.uuid_v7
    occupant = nil
    ActsAsTenant.with_tenant(@tenant) do
      structure.create_unit(platform, "Platform", level_id: @team, parent_id: @product, effective_on: since)
      occupant = create(:person, tenant: @tenant, name: LONG_OCCUPANT)
      handler.record_person(occupant.id, **ESPALIA, effective_on: since, employment_status: "employed")
      12.times do |index|
        person = create(:person, tenant: @tenant, name: index.zero? ? LONG_NAME : "Seat #{index + 1}")
        handler.record_person(person.id, **ESPALIA, effective_on: since, employment_status: "employed")
        handler.set_membership(person.id, platform, **ESPALIA, effective_on: since, allocation: 1.0, role: LONG_ROLE)
      end
    end
    plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Full unit", base_on: (Date.current + 1).iso8601)[:plan_id]
    scenario_id = call(Operations::TeamPlanning::ForkScenario, @planner, plan_id:, relation: "then", name: "Next quarter",
                                                                         ends_on: (Date.current + 120).iso8601)[:scenario_id]
    level = ActsAsTenant.with_tenant(@tenant) do
      role = create(:framework_role, tenant: @tenant, name: LONG_POSITION_ROLE)
      create(:framework_level, tenant: @tenant, role_id: role.role_id, ordinal: 1, title: "One")
    end
    position_id = call(Operations::TeamPlanning::SetPosition, @planner, plan_id:, scenario_id:, role_id: level.role_id, level_id: level.level_id,
                                                                        unit_id: platform, fte: 1, basis: "new")[:position_id]
    call(Operations::TeamPlanning::SetAssignment, @planner, plan_id:, scenario_id:, person_id: occupant.id,
                                                            placements: [ { position_id:, allocation: 1 } ])
    [ plan_id, scenario_id ]
  end

  # Pills from `sm` up, a list on a phone (#271).
  def switch_to(name)
    if page.has_selector?("nav[aria-label='Scenario']", visible: true, wait: 0)
      click_link_with_js_fallback(name, expect_text: "with this scenario's changes")
    else
      wait_for_stimulus "auto-submit"
      page.execute_script(<<~JS, name)
        const select = document.getElementById("map-scenario")
        select.value = [...select.options].find((option) => option.text.endsWith(arguments[0])).value
        select.dispatchEvent(new Event("change", { bubbles: true }))
      JS
      assert_text "with this scenario's changes"
    end
  end

  def unit(name) = find("[data-map-unit]", text: name, match: :first)

  def account(role: :member, name: "Someone", **grants)
    user = create(:user, password: TEST_PASSWORD)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, role:, person:, **grants)
  end

  def call(operation, account, **params)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)
      operation.call(context:, params:)
    end
  end
end
