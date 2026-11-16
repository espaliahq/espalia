# frozen_string_literal: true

# Cost-centre rules now read last match wins
# ([#387](https://github.com/espaliahq/espalia/issues/387)), so a tenant's
# stored first-match `rules` list becomes its `entries` in reverse, which
# picks the same cost centre for every seat. Plans' RuleSet events keep the
# old shape and the rule kind reads them the same way.
class ConvertCostCentreRulesToEntries < ActiveRecord::Migration[8.1]
  def up = flip("rules", "entries")

  def down
    newer = select_value(<<~SQL.squish)
      SELECT 1 FROM planning_rule_defaults, jsonb_array_elements(value->'entries') AS list(item)
      WHERE rule = 'cost_centre' AND (item ? 'level_ordinal' OR item ? 'location') LIMIT 1
    SQL
    raise ActiveRecord::IrreversibleMigration, "A cost-centre entry matches on a level or location, which a rules list can't hold" if newer

    flip("entries", "rules")
  end

  private

  def flip(from, to)
    execute <<~SQL.squish
      UPDATE planning_rule_defaults
      SET value = jsonb_build_object('#{to}', COALESCE(
        (SELECT jsonb_agg(item ORDER BY position DESC) FROM jsonb_array_elements(value->'#{from}') WITH ORDINALITY AS list(item, position)),
        '[]'::jsonb))
      WHERE rule = 'cost_centre' AND value ? '#{from}'
    SQL
  end
end
