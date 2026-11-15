# frozen_string_literal: true

require "test_helper"

# The plan page and map show capacity per model, each scenario against Today
# ([#296](https://github.com/espaliahq/espalia/issues/296)).
class Plans::CapacityTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  ESPALIA = { provider: "espalia" }.freeze

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    since = (Date.current - 30).iso8601
    departments = SecureRandom.uuid_v7
    @payments, @growth = Array.new(2) { SecureRandom.uuid_v7 }

    ActsAsTenant.with_tenant(@tenant) do
      @engineer = create(:framework_role, code: "E", name: "Software Engineer")
      @e5 = create(:framework_level, role_id: @engineer.role_id, ordinal: 5, title: "Senior SWE")
      structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: since)
      structure.create_unit(@payments, "Payments", level_id: departments, effective_on: since)
      structure.create_unit(@growth, "Growth", level_id: departments, effective_on: since)

      @ada, @bo, @cy, @dee = %w[Ada Bo Cy Dee].map { create(:person, tenant: @tenant, name: "#{it} Quill") }
      { @ada => [ "Software Engineer", 1.0 ], @bo => [ "Software Engineer", 0.8 ], @cy => [ "Software Engineer", 1.0 ],
        @dee => [ "Juggler", 1.0 ] }.each do |person, (title, fte)|
        people.record_person(person.id, **ESPALIA, effective_on: since, employment_status: "employed", title:, level: "5", fte:)
      end
      people.set_membership(@ada.id, @payments, **ESPALIA, effective_on: since, allocation: 1.0)
      people.set_membership(@bo.id, @payments, **ESPALIA, effective_on: since, allocation: 0.5)
      people.set_membership(@bo.id, @growth, **ESPALIA, effective_on: since, allocation: 0.5)
      people.set_membership(@dee.id, @growth, **ESPALIA, effective_on: since, allocation: 1.0)

      @planner = account(team_planner: true, name: "Erin Editor")
    end

    @plan_id = call(Operations::TeamPlanning::CreatePlan, @planner, name: "Next year", base_on: (Date.current + 1).iso8601)[:plan_id]
    @q1 = call(Operations::TeamPlanning::ForkScenario, @planner, plan_id: @plan_id, relation: "then", name: "Q1 hires",
                                                                 ends_on: (Date.current + 120).iso8601)[:scenario_id]
    sign_in @planner.user
  end

  def choose_per_fte
    call(Operations::TeamPlanning::SetRule, @planner, plan_id: @plan_id, scenario_id: @plan_id, rule: "capacity_model",
                                                      value: { roles: { @engineer.role_id => { model: "per_fte" } } })
  end

  def hire_into_growth
    call(Operations::TeamPlanning::SetPosition, @planner, plan_id: @plan_id, scenario_id: @q1, role_id: @engineer.role_id,
                                                          level_id: @e5.level_id, unit_id: @growth, fte: 1, basis: "new")
  end

  def page_for(path)
    get path
    assert_response :success
    Nokogiri::HTML5(response.body)
  end

  def unit_total(html, name)
    card = html.css("[data-map-unit]").find { it.at_css("h3").text == name }
    card.at_css("[data-capacity-unit] [data-capacity-total='per_fte'] span").text
  end

  should "show no capacity until a model is chosen" do
    html = page_for(map_plan_path(@plan_id))

    assert_nil html.at_css("[data-capacity-strip]")
    assert_nil html.at_css("[data-capacity-figure]")
    assert_not_includes page_for(plan_path(@plan_id)).text, "Capacity"
  end

  should "add the strip to the sum of the unit totals and what counts in no unit, as the table does" do
    choose_per_fte
    hire_into_growth
    html = page_for(map_plan_path(@plan_id, scenario: @q1))
    strip = html.at_css("[data-capacity-strip]")

    assert_equal "3.8 FTE", strip.at_css("[data-capacity-total='per_fte'] span").text
    assert_equal "1.4 FTE", unit_total(html, "Payments")
    assert_equal "1.4 FTE", unit_total(html, "Growth")
    assert_includes strip.at_css("[data-capacity-outside]").text, "1.0 FTE counts in no unit"
    assert_equal "+1.0 FTE vs Today", strip.at_css("[data-capacity-change='per_fte']").text
    assert_includes strip.text, "measured against Today"

    table = page_for(plan_path(@plan_id))
    row = table.at_css("tr[data-scenario-id='#{@q1}'] td.sm\\:table-cell [data-capacity-total='per_fte']")
    assert_equal "3.8 FTE", row.at_css("span").text
  end

  should "say a scenario counts nothing in the table, beside one that counts" do
    call(Operations::TeamPlanning::SetRule, @planner, plan_id: @plan_id, scenario_id: @q1, rule: "capacity_model",
                                                      value: { roles: { @engineer.role_id => { model: "per_fte" } } })
    table = page_for(plan_path(@plan_id))

    today = table.at_css("tr[data-scenario-id='#{@plan_id}']")
    assert_equal [ "Capacity:None counted" ], today.css("div.sm\\:hidden").map { it.text.squish }.grep(/Capacity/)
    assert_equal "None counted", today.at_css("td.sm\\:table-cell span.text-muted").text
    assert table.at_css("tr[data-scenario-id='#{@q1}'] [data-capacity-total='per_fte']")
  end

  should "keep the table when one scenario's capacity can't be read" do
    choose_per_fte
    q1 = @q1
    real = Operations::TeamPlanning::Capacity.method(:call)
    refuse = lambda do |context:, params:|
      raise Operations::Base::ParameterError, "Doesn't resolve" if params[:scenario_id] == q1

      real.call(context:, params:)
    end
    table = Operations::TeamPlanning::Capacity.stub(:call, refuse) { page_for(plan_path(@plan_id)) }

    assert_equal "Can't be counted", table.at_css("tr[data-scenario-id='#{@q1}'] td.sm\\:table-cell span.text-muted").text
    assert table.at_css("tr[data-scenario-id='#{@plan_id}'] [data-capacity-total='per_fte']")
  end

  should "keep the column, saying so, when no scenario's capacity can be read" do
    choose_per_fte
    refuse = ->(**) { raise Operations::Base::ParameterError, "Doesn't resolve" }
    table = Operations::TeamPlanning::Capacity.stub(:call, refuse) { page_for(plan_path(@plan_id)) }

    assert_equal "Can't be counted", table.at_css("tr[data-scenario-id='#{@q1}'] td.sm\\:table-cell span.text-muted").text
  end

  should "show an open position's figure as a filled place's is shown, each with its working" do
    choose_per_fte
    hire_into_growth
    html = page_for(map_plan_path(@plan_id, scenario: @q1))
    ada = html.at_css("[data-map-person='#{@ada.id}'] [data-capacity-figure]")
    open = html.at_css("[data-map-position] [data-capacity-figure]")

    assert_equal ada.at_css("summary")["class"], open.at_css("summary")["class"]
    assert_equal "1.0 FTE", open.at_css("summary span:not(.sr-only)").text
    assert_includes ada.text, "Units, at 1 per FTE"
    assert_includes open.text, "The open position's capacity"
  end

  should "list the places that count for no capacity, with why" do
    choose_per_fte
    html = page_for(map_plan_path(@plan_id))
    listed = html.at_css("[data-capacity-unclassified]")

    assert_includes listed.text, "1 place counts for no capacity"
    assert_includes listed.text, "Dee Quill: the person's title maps to no role"
    assert_includes html.at_css("[data-map-person='#{@dee.id}'] [data-capacity-figure]").text, "No capacity"
    assert_includes html.at_css("[data-capacity-strip]").text, "This is Today"
  end

  def account(role: :member, name: "Someone", **grants)
    user = create(:user)
    person = create(:person, tenant: @tenant, name:, email: user.email)
    create(:tenant_user, tenant: @tenant, user:, role:, person:, **grants)
  end

  def call(operation, account, **params)
    context = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)
    ActsAsTenant.with_tenant(@tenant) { operation.call(context:, params:) }
  end
end
