# frozen_string_literal: true

# Who last changed each planning input, as a person rather than a login. No
# foreign key: a rebuild writes the person the stream names, whose row may be gone.
class AddUpdatedByPersonIdToPlanningInputs < ActiveRecord::Migration[8.1]
  TABLES = %i[pay_bands exchange_rates reference_currencies budget_lines planning_rule_defaults].freeze

  def change
    TABLES.each do |table|
      add_reference table, :updated_by_person, type: :uuid
    end
  end
end
