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

      PayBand.create!(level: @e5, currency: "EUR", period: "year", minimum: 61_337, midpoint: 100_000, maximum: 177_419)
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
    assert_equal "EUR 200k a year(run rate)1 left out", table.at_css("[data-cost-cell='#{@plan_id}']").text
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
        body = Nokogiri::HTML(response.body).at_css("body")
        text = [ body.text, *body.css("input:not([type='hidden'])").map { it["value"] } ].join(" ")
        %w[61k 61.3k 61,337 61337 177k 177,419 177419].each { assert_not_includes text, it, "#{path} shows #{it}" }
      end
    end
  end

  should "show Today's map at its yearly run rate, set against nothing" do
    get map_plan_path(@plan_id)
    page = Nokogiri::HTML(response.body)

    assert_equal "EUR 200k a year", page.at_css("[data-cost-total]").text
    assert_equal [ "yearly run rate", nil ], [ page.at_css("[data-cost-run-rate]").text, page.at_css("[data-cost-change]") ]
    assert_includes page.at_css("[data-cost-strip]").text, "priced for 1 Jan 2026 to 31 Dec 2026"
    assert_equal [ "EUR 100k a year" ], page.css("[data-cost-unit] .font-medium").map(&:text)
    assert_includes page.at_css("[data-cost-outside]").text, "Of this, EUR 100k a year is in no unit"
    assert_not_includes page.at_css("main").text, "vs Today"
  end

  should "read the Org Graph once for Today's map and once for the plan page, though both price Today's run rate" do
    reads = 0
    as_of = OrgGraph::AsOf.method(:new)
    OrgGraph::AsOf.stub(:new, ->(**args) { reads += 1; as_of.call(**args) }) do
      [ map_plan_path(@plan_id), plan_path(@plan_id) ].map do |path|
        reads = 0
        get path
        assert_includes response.body, "EUR 200k a year"
        reads
      end => counts
      assert_equal [ 1, 1 ], counts
    end
  end

  should "set a shorter scenario against Today over its own days, never against Today's run rate" do
    half = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, parent_id: @year, relation: "then", name: "H1 2027",
                                                        ends_on: "2027-06-30")[:scenario_id]

    get plan_path(@plan_id)
    assert_includes Nokogiri::HTML(response.body).at_css("[data-cost-cell='#{half}']").text, "EUR 124k(+EUR 24.8k vs Today)"
    get map_plan_path(@plan_id, scenario: half)
    assert_equal "+EUR 24.8k vs Today", Nokogiri::HTML(response.body).at_css("[data-cost-change]").text
  end

  should "leave a page without any band without the Cost column or strip" do
    ActsAsTenant.with_tenant(@tenant) { PayBand.delete_all }
    get plan_path(@plan_id)
    assert_response :success
    assert_nil Nokogiri::HTML(response.body).at_css("[data-cost-cell]")
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

  should "keep an archived plan's Cost column after every band is removed, as its figures still use them" do
    call(Operations::TeamPlanning::ArchivePlan, plan_id: @plan_id)
    ActsAsTenant.with_tenant(@tenant) { PayBand.destroy_all }

    get plan_path(@plan_id)
    assert_includes Nokogiri::HTML(response.body).at_css("[data-cost-cell='#{@year}']").text, "EUR 250k"
  end

  context "the actual, planned and forecast split" do
    should "draw each surface's split from its read, adding up to the total the strip, the unit card and the table show" do
      cost = call(Operations::TeamPlanning::Cost, plan_id: @plan_id, scenario_id: @year)
      table = call(Operations::TeamPlanning::ScenarioCosts, plan_id: @plan_id)[:scenarios].find { it[:scenario_id] == @year }
      payments = cost[:units].find { it[:unit_id] == @payments }
      [ cost[:total], payments ].each do |figures|
        assert_equal BigDecimal(figures[:scenario][:converted]), figures[:parts].values.sum { BigDecimal(it[:converted]) }
      end

      get map_plan_path(@plan_id, scenario: @year)
      page = Nokogiri::HTML(response.body)
      get plan_path(@plan_id)
      cell = Nokogiri::HTML(response.body).at_css("[data-cost-cell='#{@year}']")

      assert_equal [ "Actual EUR 200k", "Planned +EUR 50k" ], parts(page.at_css("[data-cost-strip]"))
      assert_equal [ "Actual EUR 100k", "Planned +EUR 50k" ], parts(page.at_css("[data-cost-unit='#{@payments}']"))
      assert_equal parts(page.at_css("[data-cost-strip]")), parts(cell)
      assert_equal [ "EUR 250k", "EUR 250k", "EUR 150k" ],
                   [ page.at_css("[data-cost-total]").text, cell.at_css(".font-medium").text, page.at_css("[data-cost-unit='#{@payments}'] .font-medium").text ]
      assert_equal cost[:total], table[:total]
    end

    should "show Today's run rate without a split, as all of it is actual" do
      get map_plan_path(@plan_id)
      assert_nil Nokogiri::HTML(response.body).at_css("[data-figure-parts]")
      get plan_path(@plan_id)
      assert_nil Nokogiri::HTML(response.body).at_css("[data-cost-cell='#{@plan_id}'] [data-figure-parts]")
    end

    # Ada's actual pay sits EUR 23,457 above her band's midpoint, so every
    # figure it reaches (123k, 173k, 223k, 273k, 23.5k) is one no midpoint gives.
    should "split from actual pay for a see-pay holder, and from midpoints only for a member without the right" do
      viewer = ActsAsTenant.with_tenant(@tenant) { account(name: "Vic Viewer") }
      call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: viewer.person.id, role: "viewer")
      call(Operations::TeamPlanning::SetActualPay, plan_id: @plan_id, scenario_id: @plan_id, person_id: @ada.id,
                                                   amount: "123457", currency: "EUR", period: "year", basis: "full_time")
      held = %w[123k 173k 223k 273k 23.5k]

      { @editor => [ "EUR 223k", "EUR 123k" ], viewer => [ "EUR 200k", "EUR 100k" ] }.each do |member, (actual, unit_actual)|
        sign_in member.user
        get map_plan_path(@plan_id, scenario: @year)
        page = Nokogiri::HTML(response.body)
        get plan_path(@plan_id)
        cell = Nokogiri::HTML(response.body).at_css("[data-cost-cell='#{@year}']")
        surfaces = { strip: page.at_css("[data-cost-strip]"), unit: page.at_css("[data-cost-unit='#{@payments}']"), cell: }

        assert_equal [ "Actual #{actual}", "Actual #{unit_actual}", "Actual #{actual}" ], surfaces.values.map { parts(it).first }, member.person.name
        surfaces.each do |surface, html|
          shown = held.select { html.text.include?(it) }
          member == @editor ? assert_not_empty(shown, "#{surface} for the holder") : assert_empty(shown, "#{surface} for the viewer")
        end
        next if member == @editor

        assert_includes page.at_css("[data-cost-strip]").text, "Priced at pay band midpoints"
        assert_empty held.select { "#{page.at_css('main').text} #{cell.ancestors('main').first.text}".include?(it) }
      end
    end
  end

  private

  def parts(html) = html.css("[data-figure-parts] [data-part]").map(&:text)

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
