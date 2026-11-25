# frozen_string_literal: true

# Since a4 every planning input names its editor by person, and the runbook's
# count confirms no row still names an account before this runs.
class DropUpdatedByIdFromPlanningInputs < ActiveRecord::Migration[8.1]
  TABLES = %i[pay_bands exchange_rates reference_currencies budget_lines planning_rule_defaults].freeze

  def change
    TABLES.each do |table|
      remove_reference table, :updated_by, type: :uuid, index: true,
                       foreign_key: { to_table: :users, on_delete: :nullify }
    end
  end
end
