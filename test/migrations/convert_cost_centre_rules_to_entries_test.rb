# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261116042649_convert_cost_centre_rules_to_entries")

class ConvertCostCentreRulesToEntriesTest < ActiveSupport::TestCase
  RULES = [ { "role_id" => "em", "cost_centre" => "Managers" }, { "unit_id" => "tribe", "cost_centre" => "Tribe" },
            { "role_family_id" => "eng", "cost_centre" => "Engineering" } ].freeze

  setup { @tenant = create(:tenant) }

  def stored(rule, value) = PlanningRuleDefault.create!(tenant: @tenant, rule:, value:)

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { ConvertCostCentreRulesToEntries.new.migrate(direction) }
  end

  should "turn a tenant's first-match rules into entries in reverse, so each seat keeps its cost centre" do
    row = stored("cost_centre", { "rules" => RULES })
    seat = { unit_ids: %w[squad tribe], role_id: "em", role_family_id: "eng" }
    before = TeamPlanning::RuleKinds::CostCentre.match(row.value, **seat).first

    migrate(:up)

    assert_equal({ "entries" => RULES.reverse }, row.reload.value)
    assert_equal before, TeamPlanning::RuleKinds::CostCentre.match(row.value, **seat).first
    assert_equal "Managers", before["cost_centre"]
  end

  should "convert an empty list, leave other rules alone, and do nothing the second time" do
    empty = stored("cost_centre", { "rules" => [] })
    other = create(:tenant).then { PlanningRuleDefault.create!(tenant: it, rule: "attrition", value: { "rules" => [ 1 ] }) }

    migrate(:up)

    assert_equal({ "entries" => [] }, empty.reload.value)
    assert_no_changes(-> { [ empty.reload.value, other.reload.value ] }) { migrate(:up) }
    assert_equal({ "rules" => [ 1 ] }, other.value)
  end

  should "restore the rules on the way down" do
    row = stored("cost_centre", { "rules" => RULES })

    migrate(:up)
    migrate(:down)

    assert_equal({ "rules" => RULES }, row.reload.value)
  end

  should "refuse to go down once an entry matches on a level or location, leaving the entries as they are" do
    row = stored("cost_centre", { "entries" => [ { "level_ordinal" => 3, "cost_centre" => "Seniors" } ] })

    assert_raises(ActiveRecord::IrreversibleMigration) { migrate(:down) }
    assert_equal({ "entries" => [ { "level_ordinal" => 3, "cost_centre" => "Seniors" } ] }, row.reload.value)
  end
end
