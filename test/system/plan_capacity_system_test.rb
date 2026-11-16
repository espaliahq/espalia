# frozen_string_literal: true

require "application_system_test_case"

# Capacity on the plan's map and scenario table
# ([#296](https://github.com/espaliahq/espalia/issues/296)).
class PlanCapacitySystemTest < ApplicationSystemTestCase
  ESPALIA = { provider: "espalia" }.freeze

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    since = (Date.current - 30).iso8601
    departments = SecureRandom.uuid_v7
    payments, @growth = Array.new(2) { SecureRandom.uuid_v7 }

    ActsAsTenant.with_tenant(@tenant) do
      @engineer = create(:framework_role, code: "E", name: "Software Engineer")
      @e5 = create(:framework_level, role_id: @engineer.role_id, ordinal: 5, title: "Senior SWE")
      structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: since)
      structure.create_unit(payments, "Payments", level_id: departments, effective_on: since)
      structure.create_unit(@growth, "Growth", level_id: departments, effective_on: since)
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      people.record_person(@ada.id, **ESPALIA, effective_on: since, employment_status: "employed", title: "Software Engineer",
                                               level: "5", fte: 0.8)
      people.set_membership(@ada.id, payments, **ESPALIA, effective_on: since, allocation: 1.0)
      @designer = create(:framework_role, code: "D", name: "Product Designer")
      @tenant.hris_config.role_mappings << HrisRoleMapping.new(hris_titles: [ "Product Designer" ], framework_role_code: "D")
      @tenant.save!
      create(:framework_level, role_id: @designer.role_id, ordinal: 3, title: "Designer")
      @cy = create(:person, tenant: @tenant, name: "Cy Quill")
      people.record_person(@cy.id, **ESPALIA, effective_on: since, employment_status: "employed", title: "Product Designer",
                                              level: "3", fte: 1.0)
      people.set_membership(@cy.id, payments, **ESPALIA, effective_on: since, allocation: 1.0)
      @payments = payments
      @dee = create(:person, tenant: @tenant, name: "Dee Quill")
      people.record_person(@dee.id, **ESPALIA, effective_on: since, employment_status: "employed", title: "Juggler", fte: 1.0)
      people.set_membership(@dee.id, @growth, **ESPALIA, effective_on: since, allocation: 1.0)
      @planner = account(team_planner: true, name: "Erin Editor")
    end

    @plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Next year", base_on: (Date.current + 1).iso8601)[:plan_id]
    @q1 = call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                 ends_on: (Date.current + 120).iso8601)[:scenario_id]
    call(Operations::TeamPlanning::SetRule, @planner, plan_id: @plan_id, scenario_id: @plan_id, rule: "capacity_model",
                                                      value: { roles: { @engineer.role_id => { model: "per_fte" },
                                                                        @designer.role_id => { model: "units" } } })
    @position = call(Operations::TeamPlanning::SetPosition, @planner, plan_id: @plan_id, scenario_id: @q1, role_id: @engineer.role_id,
                                                                      level_id: @e5.level_id, unit_id: @growth, fte: 1, basis: "new")[:position_id]
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "show a scenario's capacity against Today, and open a place's working" do
        sign_in_as(@planner.user)
        visit map_plan_path(@plan_id, scenario: @q1)

        within("[data-capacity-strip]") do
          assert_text "1.8 FTE"
          assert_text "+1.0 FTE vs Today"
          assert_text "measured against Today"
        end
        within(find("[data-map-unit]", text: "Growth", match: :first)) { assert_text "1.0 FTE" }

        click_selector_with_js_fallback("[data-map-person='#{@ada.id}'] [data-capacity-figure] summary",
                                        expect_text: "Units, at 1 per FTE")
        within("[data-map-person='#{@ada.id}']") do
          assert_text "Share of the seat in this place"
          assert_text "0.8"
        end
        assert_selector "[data-map-position] [data-capacity-figure] summary", text: "1.0 FTE"
        assert_no_sideways_overflow
      end

      should "total each model apart, and badge a planner's override in its working" do
        call(Operations::TeamPlanning::SetCapacityOverride, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id,
                                                                      unit_id: @payments, amount: "0.5")
        sign_in_as(@planner.user)
        visit map_plan_path(@plan_id, scenario: @q1)

        within("[data-capacity-strip]") do
          assert_selector "[data-capacity-total='per_fte']", text: "1.5 FTE"
          assert_selector "[data-capacity-total='units']", text: "1.0u"
        end
        click_selector_with_js_fallback("[data-map-person='#{@ada.id}'] [data-capacity-figure] summary",
                                        expect_text: "The model gives 0.8 FTE.")
        within("[data-map-person='#{@ada.id}'] [data-capacity-figure] summary") do
          assert_text "0.5 FTE"
          assert_text "override"
        end
        assert_no_sideways_overflow
      end

      should "keep the model's overload in the working of a figure a planner overrode" do
        call(Operations::TeamPlanning::SetRule, @planner, plan_id: @plan_id, scenario_id: @plan_id, rule: "capacity_model",
                                                          value: { roles: { @engineer.role_id => { model: "per_fte" },
                                                                            @designer.role_id => { model: "units", params: { per_report: { direct: "1" } } } } })
        call(Operations::TeamPlanning::SetReportingLine, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, manager_id: @cy.id)
        call(Operations::TeamPlanning::SetCapacityOverride, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @cy.id,
                                                                      unit_id: @payments, amount: "0.5")
        sign_in_as(@planner.user)
        visit map_plan_path(@plan_id, scenario: @q1)

        click_selector_with_js_fallback("[data-map-person='#{@cy.id}'] [data-capacity-figure] summary",
                                        expect_text: "The model gives 0.0u.")
        within("[data-map-person='#{@cy.id}'] [data-capacity-figure]") do
          assert_selector "summary", text: "override"
          assert_selector "[data-capacity-overloaded]", text: "managing others costs 0.1u more than this seat's base"
        end
        assert_no_sideways_overflow
      end

      should "badge an override on someone who leaves, whose place counts nowhere" do
        call(Operations::TeamPlanning::SetCapacityOverride, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id,
                                                                      unit_id: @payments, amount: "0.5")
        call(Operations::TeamPlanning::SetDeparture, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id)
        sign_in_as(@planner.user)
        visit map_plan_path(@plan_id, scenario: @q1)

        click_selector_with_js_fallback("[data-map-person='#{@ada.id}'] [data-capacity-figure] summary",
                                        expect_text: "The person leaves in this step")
        within("[data-map-person='#{@ada.id}'] [data-capacity-figure] summary") do
          assert_text "No capacity"
          assert_text "override"
        end
        assert_no_sideways_overflow
      end

      should "list a place no model covers, with why, and mark its figure" do
        sign_in_as(@planner.user)
        visit map_plan_path(@plan_id)

        within("[data-capacity-strip]") { assert_text "1 place counts for no capacity" }
        click_selector_with_js_fallback("[data-capacity-unclassified] summary", expect_text: "Dee Quill: the person's title maps to no role")
        within("[data-map-person='#{@dee.id}']") { assert_text "No capacity" }
        assert_no_sideways_overflow
      end

      should "give someone left unassigned by a retired unit's position the capacity they still count for" do
        call(Operations::TeamPlanning::SetAssignment, @planner, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id,
                                                                placements: [ { position_id: @position, allocation: 1 } ])
        call(Operations::TeamPlanning::RetireUnit, @planner, plan_id: @plan_id, scenario_id: @q1, unit_id: @growth)
        sign_in_as(@planner.user)
        visit map_plan_path(@plan_id, scenario: @q1)

        within("section[aria-labelledby='map-unassigned'] [data-map-person='#{@ada.id}']") do
          assert_selector "[data-capacity-figure] summary", text: "0.8 FTE"
        end
        assert_no_sideways_overflow
      end

      should "show each scenario's capacity in the plan's table and its strip, split into actual and planned" do
        sign_in_as(@planner.user)
        visit plan_path(@plan_id)

        within("tr[data-scenario-id='#{@q1}']") do
          assert_text "1.8 FTE"
          assert_text "(+1.0 FTE vs Today)"
          assert_selector "span", text: "Capacity:", visible: true if label == "phone"
          assert_selector "[data-figure-parts] [data-part='planned']", text: "Planned +1.0 FTE", minimum: 1
        end
        assert_no_selector "tr[data-scenario-id='#{@plan_id}'] [data-figure-parts]"
        assert_no_sideways_overflow

        visit map_plan_path(@plan_id, scenario: @q1)
        assert_selector "[data-capacity-strip] [data-part='planned']", text: "Planned +1.0 FTE"
        assert_no_sideways_overflow
      end
    end
  end

  private

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
