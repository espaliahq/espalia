# frozen_string_literal: true

# Adds a line to the tenant's approved headcount budget.
class Operations::Tenants::AddBudgetLine < Operations::Base
  include Operations::Tenants::BudgetLineSupport

  description "Add a line to the tenant's approved headcount budget, which every Team Planning plan starts from. " \
              "#{Operations::Tenants::BudgetLineFields::HELP} Refused unless the caller is a tenant admin."
  category :write
  approval :in_app

  Operations::Tenants::BudgetLineFields.line_parameters(self)

  # @return [Hash] the line, as tenants_budget_lines lists it
  def perform
    line_payload(save_setting!(assign_line(BudgetLine.new)))
  end
end
