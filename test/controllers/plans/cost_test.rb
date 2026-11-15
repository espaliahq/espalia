# frozen_string_literal: true

require "test_helper"

class Plans::CostTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  ESPALIA = { provider: "espalia", effective_on: "2025-12-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    teams = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7

    travel_to Time.utc(2025, 12, 15, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @engineer = create(:framework_role, code: "E", name: "Software Engineer")
      @e5 = create(:framework_level, role_id: @engineer.role_id, ordinal: 5, title: "Senior SWE")
      structure.define_taxonomy([ { level_id: teams, name: "Team" } ], effective_on: "2025-01-01")
      structure.create_unit(@payments, "Payments", level_id: teams, effective_on: "2025-01-01")

      # Bo is in no unit, so that seat counts only in the strip's total.
      @ada, @bo, @cy = %w[Ada Bo Cy].map { create(:person, tenant: @tenant, name: "#{it} Quill") }
      [ @ada, @bo ].each do |person|
        people.record_person(person.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0)
      end
      people.record_person(@cy.id, **ESPALIA, employment_status: "employed", title: "Juggler", level: "5", fte: 1.0)
      people.set_membership(@ada.id, @payments, **ESPALIA, allocation: 1.0)
      people.set_membership(@cy.id, @payments, **ESPALIA, allocation: 1.0)

      PayBand.create!(level: @e5, currency: "EUR", period: "year", minimum: 61_000, midpoint: 100_000, maximum: 177_000)
      ReferenceCurrency.create!(currency: "EUR")

      @editor = account(team_planner: true, name: "Erin Editor")
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-01-01")[:plan_id]
    @year = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "2026", ends_on: "2026-12-31")[:scenario_id]
    call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @year, role_id: @engineer.role_id,
                                                level_id: @e5.level_id, unit_id: @payments, fte: 0.5, basis: "new")
    sign_in @editor.user
  end

  should "add the units and what is in no unit up to the strip's total, and show that total in the table" do
    get map_plan_path(@plan_id, scenario: @year)
    assert_response :success
    page = Nokogiri::HTML(response.body)

    assert_equal "EUR 250k", page.at_css("[data-cost-total]").text
    assert_equal "+EUR 50k vs Today", page.at_css("[data-cost-change]").text
    assert_equal [ "EUR 150k" ], page.css("[data-cost-unit] .font-medium").map(&:text)
    assert_includes page.at_css("[data-cost-strip]").text, "For 1 Jan 2026 to 31 Dec 2026, measured against Today"
    assert_includes page.at_css("[data-cost-unpriced]").text, "Cy Quill"
    assert_includes page.at_css("[data-cost-outside]").text, "Of this, EUR 100k is in no unit"

    get plan_path(@plan_id)
    table = Nokogiri::HTML(response.body)
    assert_includes table.at_css("[data-cost-cell='#{@year}']").text, "EUR 250k"
    assert_includes table.at_css("[data-cost-cell='#{@year}']").text, "1 left out"
    assert_includes response.body, "No period of its own"
  end

  should "add the units and what is in no unit up to the total exactly, in the map's read and the table's" do
    cost = call(Operations::TeamPlanning::Cost, plan_id: @plan_id, scenario_id: @year)
    table = call(Operations::TeamPlanning::ScenarioCosts, plan_id: @plan_id)[:scenarios].find { it[:scenario_id] == @year }

    units = cost[:units].sum { BigDecimal(it[:scenario][:converted]) }
    assert_equal BigDecimal(cost[:total][:scenario][:converted]), units
    assert_equal cost[:total], table[:total]
  end

  should "show no band minimum or maximum on either page, with or without pay access" do
    viewer = ActsAsTenant.with_tenant(@tenant) { account(name: "Vic Viewer") }
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: viewer.person.id, role: "viewer")

    [ @editor, viewer ].each do |member|
      sign_in member.user
      [ map_plan_path(@plan_id, scenario: @year), plan_path(@plan_id) ].each do |path|
        get path
        assert_response :success
        assert_includes response.body, "EUR 250k"
        %w[61k 61,000 177k 177,000].each { assert_not_includes response.body, it, "#{path} shows #{it}" }
      end
    end
  end

  should "leave Today's map without cost, and a page without any band without the Cost column" do
    get map_plan_path(@plan_id)
    assert_nil Nokogiri::HTML(response.body).at_css("[data-cost-strip]")

    ActsAsTenant.with_tenant(@tenant) { PayBand.delete_all }
    get plan_path(@plan_id)
    assert_response :success
    assert_not_includes response.body, "No period of its own"
    get map_plan_path(@plan_id, scenario: @year)
    assert_nil Nokogiri::HTML(response.body).at_css("[data-cost-strip]")
  end

  should "show cost before capacity in the strips, beside each unit and in the table, when both are measured" do
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @plan_id, rule: "capacity_model",
                                            value: { roles: { @engineer.role_id => { model: "per_fte" } } })

    get map_plan_path(@plan_id, scenario: @year)
    page = Nokogiri::HTML(response.body)
    strips = page.css("[data-cost-strip], [data-capacity-strip]").map { it.key?("data-cost-strip") ? :cost : :capacity }
    payments = page.css("[data-map-unit]").find { it.at_css("h3").text == "Payments" }
    marks = payments.css("[data-cost-unit], [data-capacity-unit]").map { it.key?("data-cost-unit") ? :cost : :capacity }
    assert_equal [ %i[cost capacity] ] * 2, [ strips, marks ]

    get plan_path(@plan_id)
    headings = Nokogiri::HTML(response.body).css("th").map { it.text.strip }
    assert_operator headings.index("Cost"), :<, headings.index("Capacity")
  end

  private

  def account(role: :member, name: "Someone", **grants)
    user = create(:user)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, role:, person:, **grants)
  end

  def call(operation, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: @editor.user, tenant_user: @editor, person: @editor.person), params:)
    end
  end
end
