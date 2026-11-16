# frozen_string_literal: true

require "application_system_test_case"

class PlanCostSystemTest < ApplicationSystemTestCase
  ESPALIA = { provider: "espalia" }.freeze

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    since = (Date.current - 30).iso8601
    teams = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(@tenant) do
      @planner = account(team_planner: true, name: "Erin Editor")
      engineer = create(:framework_role, code: "E", name: "Software Engineer")
      e5 = create(:framework_level, role_id: engineer.role_id, ordinal: 5, title: "Senior SWE")
      structure.define_taxonomy([ { level_id: teams, name: "Team" } ], effective_on: since)
      structure.create_unit(@payments, "Payments", level_id: teams, effective_on: since)

      ada, bo, cy = %w[Ada Bo Cy].map { create(:person, tenant: @tenant, name: "#{it} Quill") }
      [ ada, bo ].each do |person|
        people.record_person(person.id, **ESPALIA, effective_on: since, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0)
      end
      people.record_person(cy.id, **ESPALIA, effective_on: since, employment_status: "employed", title: "Juggler", level: "5", fte: 1.0)
      [ ada, cy ].each { people.set_membership(it.id, @payments, **ESPALIA, effective_on: since, allocation: 1.0) }
      @ada_id = ada.id

      PayBand.create!(level: e5, currency: "EUR", period: "year", minimum: 61_000, midpoint: 100_000, maximum: 177_419)
      ReferenceCurrency.create!(currency: "EUR")
      @level_id = e5.level_id
      @role_id = engineer.role_id
    end

    # The baseline reads the Org Graph as known the day before the base date, so a plan based tomorrow sees today's facts.
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: (Date.current + 1).iso8601)[:plan_id]
    @year = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Year one",
                                                         ends_on: (Date.current + 365).iso8601)[:scenario_id]
    call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @year, role_id: @role_id,
                                                level_id: @level_id, unit_id: @payments, fte: 0.5, basis: "new")
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "phone", MOBILE_SIZE ] ].each do |label, size|
    context "on a #{label}" do
      setup { page.driver.browser.manage.window.resize_to(*size) }

      should "show the scenario's cost in the table, and on its map with each unit's share and the seats left out" do
        sign_in_as(@planner.user)
        visit plan_path(@plan_id)
        assert_selector "[data-cost-cell='#{@year}']", text: "EUR 238k"
        assert_selector "[data-cost-cell='#{@plan_id}']", text: /EUR 200k a year\s+\(run rate\)/
        assert_no_sideways_overflow

        visit map_plan_path(@plan_id, scenario: @year)
        within("[data-cost-strip]") do
          assert_selector "[data-cost-total]", text: "EUR 238k"
          assert_selector "[data-cost-change]", text: "+EUR 38k vs Today"
          assert_text "Of this, EUR 100k is in no unit on the map"
          find("summary", text: "1 seat has no price").click
          assert_text "Cy Quill: no level resolves for the seat", wait: 10
        end
        assert_selector "[data-cost-unit='#{@payments}']", text: "EUR 138k"
        [ "[data-cost-strip]", "[data-cost-unit]" ].each { |figures| all(figures).each { assert_not_includes it.text, "177" } }
        %w[177k 177,419 177419].each { assert_no_text it }
        assert_no_sideways_overflow
      end

      should "say in the strip that the plan's actual pay priced a seat, for a holder" do
        call(Operations::TeamPlanning::SetActualPay, plan_id: @plan_id, scenario_id: @year, person_id: @ada_id,
                                                     amount: "90000", currency: "EUR", period: "year", basis: "full_time")
        sign_in_as(@planner.user)
        visit map_plan_path(@plan_id, scenario: @year)

        within("[data-cost-strip]") { assert_text "Priced from the actual pay the plan holds for 1 seat here, and at pay band midpoints for the rest" }
      end

      should "split the cost into actual, planned and forecast, wrapping three long figures rather than widening the page" do
        call(Operations::TeamPlanning::SetDeparture, plan_id: @plan_id, scenario_id: @year, person_id: @ada_id)
        call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @plan_id, rule: "attrition", value: { "yearly_rate" => "0.1" })
        sign_in_as(@planner.user)
        visit map_plan_path(@plan_id, scenario: @year)

        within("[data-cost-strip] [data-figure-parts]") do
          assert_selector "[data-part='actual']", text: "Actual EUR 200k"
          assert_selector "[data-part='planned']", text: /Planned -EUR \d/
          assert_selector "[data-part='forecast']", text: /Forecast -EUR \d/
        end
        assert_selector "[data-cost-unit='#{@payments}'] [data-part='planned']", text: /Planned -EUR \d/
        assert_no_sideways_overflow

        visit plan_path(@plan_id)
        assert_selector "[data-cost-cell='#{@year}'] [data-part='forecast']", text: /Forecast -EUR \d/
        assert_no_selector "[data-cost-cell='#{@plan_id}'] [data-figure-parts]"
        assert_no_sideways_overflow
      end

      should "say each scenario's run rate on its last day in a quiet line that wraps, in the table and the strip" do
        last_day = (Date.current + 365).strftime("%-d %b %Y")
        line = "Run rate on #{last_day}: EUR 250k a year, +EUR 50k on Today's"
        sign_in_as(@planner.user)
        visit plan_path(@plan_id)
        assert_selector "[data-cost-cell='#{@year}'] [data-run-rate-at-end]", text: line
        assert_no_selector "[data-cost-cell='#{@plan_id}'] [data-run-rate-at-end]"
        assert_no_sideways_overflow

        visit map_plan_path(@plan_id, scenario: @year)
        assert_selector "[data-cost-strip] [data-run-rate-at-end]", text: line
        assert_no_sideways_overflow
      end

      should "show Today's map at its yearly run rate, with no change beside it" do
        sign_in_as(@planner.user)
        visit map_plan_path(@plan_id)
        within("[data-cost-strip]") do
          assert_selector "[data-cost-total]", text: "EUR 200k a year"
          assert_selector "[data-cost-run-rate]", text: "yearly run rate"
          assert_no_selector "[data-cost-change]"
        end
        assert_selector "[data-cost-unit='#{@payments}']", text: "EUR 100k a year"
        assert_no_text "vs Today"
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

  def call(operation, **params)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: @planner.user, tenant_user: @planner, person: @planner.person)
      operation.call(context:, params:)
    end
  end
end
