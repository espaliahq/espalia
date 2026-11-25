# frozen_string_literal: true

# Removes a line from the tenant's approved budget. A plan that changed or cut
# it keeps its change, which then reads as orphaned and Attention flags.
class Operations::Tenants::RemoveBudgetLine < Operations::Base
  include Operations::Tenants::BudgetLineSupport

  description "Remove a line from the tenant's approved budget, by budget_line_id from tenants_budget_lines. A plan " \
              "that changed or cut the line keeps its change, which then reads as orphaned. Refused unless the " \
              "caller is a tenant admin."
  category :destructive
  approval :in_app

  parameter :budget_line_id, String, required: true, allow_blank: false

  # @return [Hash] `{ budget_line_id, role, starts_on, ends_on }` of the line removed
  def perform
    line = find_line(params[:budget_line_id])
    refusing_as_parameters { planning_inputs.remove(:budget_lines, line.id, changed_by_id: context.person&.id) }
    { budget_line_id: line.id, role: line.role_label, starts_on: line.starts_on.iso8601, ends_on: line.ends_on.iso8601 }
  end
end
