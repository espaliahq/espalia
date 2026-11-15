# frozen_string_literal: true

# The fields a budget line is written with, read from a tool's parameters:
# the tenant's tools write them to a line, and a plan's tools to a change of
# one. A refusal never repeats an amount or a head count.
module Operations::Tenants::BudgetLineFields
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
    operation.parameter :amount, String, schema: Operations::Tenants::PayBandSupport::FIGURE_SCHEMA
    operation.parameter :currency, String
    operation.parameter :period, String, allowed: BudgetLine::PERIODS
    operation.parameter :head_count, String, schema: Operations::Tenants::PayBandSupport::FIGURE_SCHEMA
    operation.parameter :role_id, String
    operation.parameter :level_id, String
    operation.parameter :location, String
    operation.parameter :cost_centre, String
    operation.requires_any_of :amount, :head_count, message: "A budget line needs an amount, a head count or both"
    operation.dependent_required :amount, requires: :currency, message: "An amount needs a currency"
    operation.dependent_required :amount, requires: :period, message: "An amount needs a period, year or month"
    operation.forbids_when :approved_on, if: :origin, in: %w[existing replacement],
                                         message: "approved_on applies to a new position only"
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
      level = FrameworkState::Level.find_by(level_id:)
      return if level.nil? && kept_position?(line, level_id, role_id)
      raise Operations::Base::ParameterError, "There is no such level in the framework" unless level
      raise Operations::Base::ParameterError, "That level belongs to another role" if role_id && role_id != level.role_id

      line.take_level(level)
    else
      role = FrameworkState::Role.find_by(role_id:)
      return if role.nil? && kept_position?(line, level_id, role_id)
      raise Operations::Base::ParameterError, "There is no such role in the framework" unless role

      line.level_id = line.level_name = nil
      line.take_role(role)
    end
  end

  # A line keeps the role and level it names after they leave the framework, so a change may give them again.
  def kept_position?(line, level_id, role_id)
    return level_id == line.level_id && [ nil, line.role_id ].include?(role_id) if level_id

    line.level_id.nil? && role_id == line.role_id
  end

  def decimal(name)
    value = params[name].to_s.strip
    return nil if value.empty?
    raise Operations::Base::ParameterError, "#{name} must be a number with at most two decimal places" unless value.match?(Operations::Tenants::PayBandSupport::FIGURE)

    BigDecimal(value)
  end
end
