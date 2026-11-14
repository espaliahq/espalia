# frozen_string_literal: true

# The tenant's approved headcount budget, as the budget screen lists it: by
# when each line starts, then by role.
class Operations::Tenants::BudgetLines < Operations::Base
  include Operations::Tenants::BudgetLineSupport

  description "List the active tenant's approved budget lines: each line's period (starts_on, ends_on), origin " \
              "(existing, replacement or new) and approved_on, amount with its currency and period (year or month) " \
              "as entered and never converted, head count, and the role, level, location and cost centre it was " \
              "approved for, where it names them. amount is null for a line with no amount, never zero. Give " \
              "budget_line_id to read one line. Refused unless the caller is a tenant admin; a plan member sees " \
              "lines only through their own plan."
  category :read
  approval :none

  parameter :budget_line_id, String

  # @return [Hash] `{ budget_lines: [...] }`
  # @raise [Operations::Base::ParameterError] for a budget_line_id the tenant doesn't hold
  def perform
    lines = params[:budget_line_id].present? ? [ find_line(params[:budget_line_id]) ] : BudgetLine.order(:starts_on, :role_name, :level_name, :created_at).to_a
    names = editor_names(lines)
    { budget_lines: lines.map { line_payload(it, names:) } }
  end
end
