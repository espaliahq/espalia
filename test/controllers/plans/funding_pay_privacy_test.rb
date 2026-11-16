# frozen_string_literal: true

require "test_helper"

# Setting a position's funding from the Budget tab shows no figure from held
# pay to an editor without the see-pay right: not in the dialog, the flash or
# the page it lands on ([#411](https://github.com/espaliahq/espalia/issues/411)).
# The held pay differs from the band's midpoint and appears nowhere else.
class Plans::FundingPayPrivacyTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  HELD = "73917"

  setup do
    travel_to Time.utc(2026, 2, 1, 9)
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @holder = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      payments = SecureRandom.uuid_v7
      departments = SecureRandom.uuid_v7
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: "2025-01-01")
      structure.create_unit(payments, "Payments", level_id: departments, effective_on: "2025-01-01")
      engineer = create(:framework_role, code: "E", name: "Software Engineer")
      e5 = create(:framework_level, role_id: engineer.role_id, ordinal: 5, title: "Senior SWE")
      PayBand.create!(level: e5, currency: "AUD", period: "year", minimum: 0, midpoint: 100_000, maximum: 200_000)
      ReferenceCurrency.create!(currency: "AUD")
      ada = create(:person, tenant: @tenant, name: "Ada Quill")
      people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      people.record_person(ada.id, provider: "espalia", effective_on: "2026-01-01", employment_status: "employed",
                                   title: "Software Engineer", level: "5", fte: 1.0)
      people.set_membership(ada.id, payments, provider: "espalia", effective_on: "2026-01-01", allocation: 1.0)

      @plan_id = call(Operations::TeamPlanning::CreatePlan, @holder, name: "Payments next year", base_on: "2026-03-02", unit_ids: [ payments ])[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @holder, plan_id: @plan_id, person_id: @editor.person_id, role: "editor")
      @q1 = call(Operations::TeamPlanning::ForkScenario, @holder, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]
      call(Operations::TeamPlanning::SetActualPay, @holder, plan_id: @plan_id, scenario_id: @q1, person_id: ada.id,
                                                            amount: HELD, currency: "AUD", period: "year", basis: "full_time")
      @platform, @growth = %w[Platform Growth].map do
        BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 500_000, currency: "AUD", period: "year", cost_centre: it).id
      end
      @position = call(Operations::TeamPlanning::SetPosition, @holder, plan_id: @plan_id, scenario_id: @q1, role_id: e5.role_id,
                                                                       level_id: e5.level_id, unit_id: payments, fte: 1, basis: "new",
                                                                       cost_centre: "Platform")[:position_id]
      call(Operations::TeamPlanning::SetAssignment, @holder, plan_id: @plan_id, scenario_id: @q1, person_id: ada.id,
                                                             placements: [ { position_id: @position, allocation: 1 } ])
      funded = call(Operations::TeamPlanning::Budget, @holder, plan_id: @plan_id, scenario_id: @q1)[:total][:funded][:native]["AUD"]
      @figures = [ HELD, Views::Plans::CostMarks::Format.amount(funded, "AUD"), funded[0, 5], Views::Plans::CostMarks::Format.amount(HELD, "AUD") ]
    end
  end

  should "show the holder the figures, so the checks below can see them" do
    sign_in @holder.user
    get budget_plan_path(@plan_id, scenario: @q1)
    assert_includes response.body, @figures[1]
  end

  should "keep held pay out of the dialog, the flash and the page an editor without the right lands on" do
    sign_in @editor.user
    get budget_plan_path(@plan_id, scenario: @q1)
    assert_select "#funding-modal"
    assert_select "[data-funding-action=?]", plan_funding_path(@plan_id, @position)
    assert_no_figures response.body, "the tab and its dialog"

    patch plan_funding_path(@plan_id, @position), params: { scenario_id: @q1, funding: { parts: { @platform => "50", @growth => "50" } } }
    assert_equal "Funding set.", flash[:notice]
    follow_redirect!
    assert_no_figures response.body, "the page after setting the funding"

    patch plan_funding_path(@plan_id, @position), params: { scenario_id: @q1, funding: { parts: { @platform => "70", @growth => "50" } } }
    assert_no_figures flash[:alert], "the refusal"
    follow_redirect!
    assert_no_figures response.body, "the page after a refusal"

    delete plan_funding_path(@plan_id, @position), params: { scenario_id: @q1 }
    assert_no_figures flash[:notice], "the clear"
    follow_redirect!
    assert_no_figures response.body, "the page after clearing the funding"
  end

  private

  def assert_no_figures(text, where)
    assert text.present?, where
    @figures.each { assert_not_includes text, it, where }
  end

  def call(operation, account, **params)
    context = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)
    operation.call(context:, params:)
  end
end
