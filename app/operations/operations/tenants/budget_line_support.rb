# frozen_string_literal: true

# What the budget line tools share: the admin-only check, reading a line's
# fields, and the payload each returns. A refusal never repeats an amount or
# a head count, so a line can't reach a log through an error message.
#
# The approved budget is tenant-wide and sensitive, so only an admin holds
# it. A plan member reads a line only through their own plan.
module Operations::Tenants::BudgetLineSupport
  include Operations::Tenants::PayBandSupport
  include Operations::OrgGraph::DateParameter

  HELP = "Give an amount, a head count or both. An amount needs a currency (ISO 4217) and a period, year or " \
         "month, and is kept as entered, never converted; a line with no amount reads as no amount, never zero. " \
         "Figures are decimal strings with at most two decimal places. origin is existing (a person's seat), " \
         "replacement or new; approved_on applies to a new position only. role_id and level_id (from " \
         "frameworks_get) are optional, as are location and cost_centre."

  # Declares the fields a line is written with, for the add and change tools.
  #
  # @param operation [Class<Operations::Base>]
  def self.line_parameters(operation)
    operation.parameter :starts_on, String, required: true, allow_blank: false, schema: DATE_SCHEMA
    operation.parameter :ends_on, String, required: true, allow_blank: false, schema: DATE_SCHEMA
    operation.parameter :origin, String, required: true, allowed: BudgetLine::ORIGINS
    operation.parameter :approved_on, String, schema: DATE_SCHEMA
    operation.parameter :amount, String, schema: FIGURE_SCHEMA
    operation.parameter :currency, String
    operation.parameter :period, String, allowed: BudgetLine::PERIODS
    operation.parameter :head_count, String, schema: FIGURE_SCHEMA
    operation.parameter :role_id, String
    operation.parameter :level_id, String
    operation.parameter :location, String
    operation.parameter :cost_centre, String
  end

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, :manage_budget_lines?, policy_class: TenantPolicy
  end

  private

  # @param line [BudgetLine]
  # @return [BudgetLine] with every field set from the parameters
  def assign_line(line)
    line.assign_attributes(starts_on: parse_date(:starts_on), ends_on: parse_date(:ends_on), origin: params[:origin],
                           approved_on: parse_date(:approved_on), amount: decimal(:amount), currency: params[:currency],
                           period: params[:period], head_count: decimal(:head_count),
                           location: params[:location], cost_centre: params[:cost_centre])
    assign_role(line)
    line
  end

  def assign_role(line)
    level_id = params[:level_id].presence&.downcase
    role_id = params[:role_id].presence&.downcase
    return line.any_role! unless level_id || role_id

    if level_id
      level = FrameworkState::Level.find_by(level_id:) or raise Operations::Base::ParameterError, "There is no such level in the framework"
      raise Operations::Base::ParameterError, "That level belongs to another role" if role_id && role_id != level.role_id

      line.take_level(level)
    else
      role = FrameworkState::Role.find_by(role_id:) or raise Operations::Base::ParameterError, "There is no such role in the framework"
      line.level_id = line.level_name = nil
      line.take_role(role)
    end
  end

  def decimal(name)
    value = params[name].to_s.strip.delete(",")
    return nil if value.empty?
    raise Operations::Base::ParameterError, "#{name} must be a number with at most two decimal places" unless value.match?(FIGURE)

    BigDecimal(value)
  end

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
