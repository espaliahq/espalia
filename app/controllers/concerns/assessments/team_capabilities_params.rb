# frozen_string_literal: true

# Reads the team card's and team map's choices from the query string into
# `Operations::Assessments::TeamCapabilities`, so both read one payload.
module Assessments::TeamCapabilitiesParams
  private

  # A choice the operation would refuse falls back to its default, leaving the others in place.
  #
  # @param only [Array<Symbol>, nil] the choices read from the query string; nil for all of them
  # @param fixed [Hash] choices the caller makes regardless of the query string
  # @return [Hash] the operation's payload
  def team_capabilities(only: nil, **fixed)
    choices = only ? team_choices.slice(*only) : team_choices
    Operations::Assessments::TeamCapabilities.call(context: pundit_user, params: choices.merge(fixed))
  end

  def team_level
    level = params[:team_level]
    Integer(level, exception: false) if level.is_a?(String)
  end

  def team_choices
    choices = { people: params[:team_people].presence, role_id: params[:team_role].presence,
                level_ordinal: team_level, ratings: params[:team_ratings].presence,
                compare: params[:team_compare].presence }.compact
    choices.select { |name, value| readable?(name, value) }
  end

  def readable?(name, value)
    Operations::Assessments::TeamCapabilities.parameters.fetch(name).validate!(value)
    true
  rescue Operations::Base::ParameterError
    false
  end
end
