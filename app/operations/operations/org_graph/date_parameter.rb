# frozen_string_literal: true

# The `YYYY-MM-DD` dates the Org Graph reads take, checked one way so every
# tool rejects a bad date with the same message.
module Operations::OrgGraph::DateParameter
  DATE_KEY = Operations::Reporting::CycleCohort::DATE_KEY
  DATE_SCHEMA = { pattern: Operations::Reporting::CycleCohort::DATE_PATTERN }.freeze

  private

  # @param name [Symbol] the parameter to read
  # @return [Date, nil] nil when the parameter is blank
  # @raise [Operations::Base::ParameterError] when it is not a real date
  def parse_date(name)
    value = params[name]
    return nil if value.blank?
    raise Operations::Base::ParameterError, "#{name} must be a date, YYYY-MM-DD" unless DATE_KEY.match?(value)

    Date.iso8601(value)
  rescue Date::Error
    raise Operations::Base::ParameterError, "#{name} must be a date, YYYY-MM-DD"
  end
end
