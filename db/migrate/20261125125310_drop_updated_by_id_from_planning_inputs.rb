# frozen_string_literal: true

# Since a4 every planning input names its editor by person. This refuses to
# drop the column while any row still names an account there, so a failed
# predeploy leaves a4 serving with nothing lost.
class DropUpdatedByIdFromPlanningInputs < ActiveRecord::Migration[8.1]
  TABLES = %i[pay_bands exchange_rates reference_currencies budget_lines planning_rule_defaults].freeze

  def change
    reversible { |direction| direction.up { refuse_while_accounts_remain } }

    TABLES.each do |table|
      remove_reference table, :updated_by, type: :uuid, index: true,
                       foreign_key: { to_table: :users, on_delete: :nullify }
    end
  end

  private

  def refuse_while_accounts_remain
    held = TABLES.to_h { [ it, select_value("SELECT count(*) FROM #{it} WHERE updated_by_id IS NOT NULL").to_i ] }.select { _2.positive? }
    return if held.empty?

    raise ActiveRecord::MigrationError, <<~MESSAGE.squish
      Rows still name an account in updated_by_id (#{held.map { "#{_1}: #{_2}" }.join(', ')}).
      Run bin/rails events:reconcile on the a4 release, then deploy again.
    MESSAGE
  end
end
