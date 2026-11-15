# frozen_string_literal: true

require "test_helper"

class TeamPlanning::Events::BudgetLineTest < ActiveSupport::TestCase
  B = TeamPlanning::Baseline
  SET = TeamPlanning::Events::BudgetLineSet
  CUT = TeamPlanning::Events::BudgetLineCut
  TENANT, PLAN = Array.new(2) { SecureRandom.uuid_v7 }

  def approved = B::BudgetLine.new(id: TENANT, starts_on: Date.new(2026, 7, 1), ends_on: Date.new(2027, 6, 30), origin: "existing",
                                   approved_on: nil, amount: BigDecimal("1000"), currency: "AUD", period: "year", head_count: nil,
                                   role_id: nil, level_id: nil, role_name: nil, level_name: nil, location: nil, cost_centre: nil,
                                   source: "tenant")

  def map(lines = [ approved ]) = B::Map.new(base_on: Date.new(2026, 3, 2), known_on: Date.new(2026, 3, 1), units: [], people: [],
                                             unassigned_ids: [], positions: [], names: {}, rules: nil, budget_lines: lines)

  def figures(**overrides) = { starts_on: "2026-07-01", ends_on: "2027-06-30", origin: "new", head_count: "2" }.merge(overrides)

  should "share one facet, so the later of a set and a cut wins" do
    assert_equal [ CUT, SET ], TeamPlanning::ChangeKinds.holding(SET.facet)
  end

  should "keep a plan's amount in its own currency and period, and a head count with no amount" do
    assert_equal({ starts_on: "2026-07-01", ends_on: "2027-06-30", origin: "new", amount: "9000.00", currency: "NZD", period: "month",
                   tenant_line: false }, SET.end_state(figures(head_count: nil, amount: "9000", currency: "nzd", period: "month")))
    assert_nil SET.end_state(figures)[:amount]
    assert_equal "A budget line needs an amount, a head count or both", assert_raises(TeamPlanning::Error) { SET.end_state(figures(head_count: nil)) }.message
  end

  should "read a line back as an override row stores it, with the sealed amount left out" do
    planned = SET.end_state(figures(amount: "9000", currency: "NZD", period: "month", location: "NZ", tenant_line: true))
    held = SET.apply_to(map, { subject_id: TENANT, **planned })

    assert_equal planned.except(:amount), SET.read_from(held, subject_id: TENANT)
    assert_equal({ starts_on: "2026-07-01", ends_on: "2027-06-30", origin: "existing", currency: "AUD", period: "year", tenant_line: true },
                 SET.read_from(map, subject_id: TENANT))
  end

  should "change a tenant line in place, add a plan line, and cut either" do
    changed = SET.apply_to(map, { subject_id: TENANT, **SET.end_state(figures(tenant_line: true)) })
    added = SET.apply_to(changed, { subject_id: PLAN, **SET.end_state(figures) })

    assert_equal [ [ TENANT, "changed", BigDecimal(2) ], [ PLAN, "plan", BigDecimal(2) ] ],
                 added.budget_lines.map { [ it.id, it.source, BigDecimal(it.head_count) ] }
    assert_equal [ PLAN ], CUT.apply_to(added, { subject_id: TENANT, tenant_line: true }).budget_lines.map(&:id)
  end

  should "read a change to a tenant line that has gone as orphaned, never dropped or added" do
    gone = map([])
    assert_equal({ TENANT => "set" }, SET.apply_to(gone, { subject_id: TENANT, **SET.end_state(figures(tenant_line: true)) }).orphaned_lines)
    assert_equal({ TENANT => "cut" }, CUT.apply_to(gone, { subject_id: TENANT, tenant_line: true }).orphaned_lines)
    assert_empty CUT.apply_to(gone, { subject_id: PLAN, tenant_line: false }).orphaned_lines
    assert_empty SET.apply_to(gone, { subject_id: TENANT, **SET.end_state(figures(tenant_line: true)) }).budget_lines
  end
end
