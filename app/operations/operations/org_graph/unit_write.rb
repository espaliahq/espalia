# frozen_string_literal: true

# What the Org Graph's write tools share: the unit they act on, the day a
# change takes effect, and the command handlers, which check the policy for
# that unit and name who may make a change they refuse.
module Operations::OrgGraph::UnitWrite
  UUID_RE = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  def self.included(base)
    base.category :write
    base.parameter :effective_on, String, allow_blank: false
  end

  # The commands check {OrgGraphPolicy} against the unit itself, so this
  # only keeps out callers who aren't in the tenant.
  def policy_check
    authorize :org_graph, :show?
  end

  private

  # @return [String] ISO date, today unless the caller named one
  # @raise [Operations::Base::ParameterError]
  def effective_on
    return Date.current.iso8601 unless params[:effective_on]

    Date.iso8601(params[:effective_on]).iso8601
  rescue Date::Error
    raise Operations::Base::ParameterError, "effective_on must be a date like 2026-11-13, got #{params[:effective_on].inspect}"
  end

  # @param name [Symbol] the parameter that names the unit
  # @return [OrgUnit] a live unit
  # @raise [Operations::Base::ParameterError]
  def live_unit!(name)
    unit = OrgUnit.find_by(id: uuid!(name).downcase)
    raise Operations::Base::ParameterError, "#{name} names no unit in the Org Graph" unless unit
    raise Operations::Base::ParameterError, "#{unit.name} is retired" if unit.retired?

    unit
  end

  # @param name [Symbol] the parameter that names the person
  # @return [Person]
  # @raise [Operations::Base::ParameterError]
  def person!(name)
    Person.find_by(id: uuid!(name).downcase) or
      raise Operations::Base::ParameterError, "#{name} names no person in this tenant"
  end

  def uuid!(name)
    value = params[name]
    return value if value.is_a?(String) && value.match?(UUID_RE)

    raise Operations::Base::ParameterError, "#{name} must be a UUID, got #{value.inspect}"
  end

  def structure_handler = ::OrgGraph::StructureCommandHandler.new(actor: context)

  def person_handler = ::OrgGraph::CommandHandler.new(actor: context)
end
