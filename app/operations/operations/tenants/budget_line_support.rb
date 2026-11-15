# frozen_string_literal: true

# What the budget line tools share: the admin-only check, reading a line's
# fields, and the payload each returns. A refusal never repeats an amount or
# a head count, so a line can't reach a log through an error message.
#
# The approved budget is tenant-wide and sensitive, so only an admin holds
# it. A plan member reads a line only through their own plan.
module Operations::Tenants::BudgetLineSupport
  include Operations::Tenants::PayBandSupport
  include Operations::Tenants::BudgetLineFields

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, :manage_budget_lines?, policy_class: TenantPolicy
  end

  private

  # @param line [BudgetLine]
  # @param names [Hash{String => String}] editors by user id
  # @return [Hash]
  def line_payload(line, names: editor_names([ line ]))
    {
      budget_line_id: line.id,
      starts_on: line.starts_on.iso8601,
      ends_on: line.ends_on.iso8601,
      origin: line.origin,
      approved_on: line.approved_on&.iso8601,
      amount: line.figure(:amount),
      currency: line.currency,
      period: line.period,
      head_count: line.figure(:head_count),
      role_id: line.role_id,
      level_id: line.level_id,
      role: line.role_name,
      level_name: line.level_name,
      location: line.location.presence,
      cost_centre: line.cost_centre.presence,
      updated_at: line.updated_at.iso8601,
      updated_by: names[line.updated_by_id]
    }
  end

  # @param budget_line_id [String]
  # @return [BudgetLine]
  # @raise [Operations::Base::ParameterError] when the tenant has no such line
  def find_line(budget_line_id)
    BudgetLine.find_by(id: budget_line_id.to_s) || raise(Operations::Base::ParameterError, "There is no such budget line")
  end
end
