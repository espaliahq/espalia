# frozen_string_literal: true

# Changes a line of the tenant's approved budget. Every plan reads the lines
# live, so each sees the change at once.
class Operations::Tenants::ChangeBudgetLine < Operations::Base
  include Operations::Tenants::BudgetLineSupport

  description "Change a line of the tenant's approved budget, by budget_line_id from tenants_budget_lines. Give " \
              "every field as the line reads afterwards: a field left out is cleared. Every plan reads the budget " \
              "live. A role or level that has left the framework stays on the line while the change gives the same ids. " \
              "#{Operations::Tenants::BudgetLineFields::HELP} Refused unless the caller is a tenant admin."
  category :write
  approval :in_app

  parameter :budget_line_id, String, required: true, allow_blank: false
  Operations::Tenants::BudgetLineFields.line_parameters(self)

  # @return [Hash] the line, as tenants_budget_lines lists it
  def perform
    line = find_line(params[:budget_line_id])
    line.with_lock { line_payload(save_setting!(assign_line(line))) }
  rescue ActiveRecord::RecordNotFound
    raise Operations::Base::ParameterError, "There is no such budget line"
  end
end
