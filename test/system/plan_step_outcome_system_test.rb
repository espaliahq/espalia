# frozen_string_literal: true

require "application_system_test_case"

# A closed step's plan beside what happened, from its row and from the
# timeline ([#466](https://github.com/espaliahq/espalia/issues/466)): a table
# on a wide screen, a card per unit on a phone. The step after it stands on
# the Org Graph as it reads today ([#502](https://github.com/espaliahq/espalia/issues/502)).
class PlanStepOutcomeSystemTest < ApplicationSystemTestCase
  ESPALIA = { provider: "espalia" }.freeze

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = create(:tenant_user, tenant: @tenant, role: :admin, team_planner: true, person: create(:person, tenant: @tenant, name: "Erin Editor"))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant, name: "Vic Viewer"))
      org = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      base_on = Date.current - 90
      # A plan's base reads the Org Graph as known the day before it, so the
      # unit and its people land then.
      travel_to((base_on - 1).to_time + 9.hours) do
        @payments = unit("Payments")
        @brook = %w[Ada Brook].map do |name|
          create(:person, tenant: @tenant, name: "#{name} Example").tap do
            org.record_person(it.id, **ESPALIA, effective_on: base_on - 30, employment_status: "employed", title: "Engineer", level: "5", fte: 1.0)
            org.set_membership(it.id, @payments, **ESPALIA, effective_on: base_on - 30, allocation: 1.0)
          end
        end.last
      end
      travel_to(base_on.to_time + 9.hours) do
        @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: base_on.iso8601, unit_ids: [ @payments ])[:plan_id]
        call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
        @q1 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1",
                                                           ends_on: (Date.current + 89).iso8601)[:scenario_id]
        @q2 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2",
                                                           ends_on: (Date.current + 180).iso8601)[:scenario_id]
      end
      org.leave(@brook.id, **ESPALIA, effective_on: (Date.current - 10).iso8601)
      call(Operations::TeamPlanning::CloseStep, plan_id: @plan_id, scenario_id: @q1)
    end
  end

  [ [ "desktop", DESKTOP_SIZE, "tr" ], [ "phone", MOBILE_SIZE, "li" ] ].each do |label, size, shape|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "show a viewer what the step planned beside what happened, by unit" do
        sign_in_as(@viewer.user)
        visit plan_path(@plan_id)
        assert_selector "h1", text: "Next year"
        row = "tr[data-scenario-id='#{@q1}']"
        scroll_to(find(row), align: :center)
        click_button_with_js_fallback("Planned against actual…", expect_text: "Q1: planned against actual")

        dialog = "#step-outcome-#{@q1}"
        assert_selector "#{dialog} turbo-frame[complete]", visible: :all
        within(dialog) do
          assert_text "As the organisation stood on #{(Date.current - 1).strftime('%-d %b %Y')}, as the Org Graph reads today."
          unit = shape == "tr" ? "tr[data-step-outcome-unit='#{@payments}']" : "li[data-step-outcome-card='#{@payments}']"
          within(unit) do
            assert_text "Payments"
            assert_selector "[data-step-outcome=as_planned] dd", text: "Ada Example"
            assert_selector "[data-step-outcome=planned_not_here] dd", text: "Brook Example"
          end
        end
        assert_no_sideways_overflow
      end

      should "show the map of the step after it, standing on the Org Graph as it reads today" do
        sign_in_as(@viewer.user)
        visit map_plan_path(@plan_id, scenario: @q2)

        assert_text "as it reads today, with this scenario's changes"
        within("[data-map-unit='#{@payments}']") { assert_text "Ada Example" }
        assert_no_sideways_overflow
      end

      should "open it from the timeline" do
        sign_in_as(@viewer.user)
        visit timeline_plan_path(@plan_id, scenario: @q1, step: 1)
        assert_selector "h1", text: "Next year"
        click_button_with_js_fallback("Planned against actual…", expect_text: "Q1: planned against actual")

        assert_selector "#step-outcome-#{@q1} turbo-frame[complete]", visible: :all
        within("#step-outcome-#{@q1}") { assert_text "Ada Example" }
        assert_no_sideways_overflow
      end
    end
  end

  private

  def unit(name)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    level_id = SecureRandom.uuid_v7
    structure.define_taxonomy([ { level_id:, name: "Department" } ], effective_on: "2024-01-01")
    SecureRandom.uuid_v7.tap { structure.create_unit(it, name, level_id:, effective_on: "2024-01-01") }
  end

  def call(operation, **params)
    operation.call(context: AuthorizationContext.new(user: @editor.user, tenant_user: @editor, person: @editor.person), params:)
  end
end
