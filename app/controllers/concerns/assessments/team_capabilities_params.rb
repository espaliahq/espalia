# frozen_string_literal: true

# Reads the team card's and team map's choices from the query string into
# `Operations::Assessments::TeamCapabilities`, so both read one payload.
module Assessments::TeamCapabilitiesParams
  private

  # A choice the operation refuses falls back to the defaults rather than failing the page.
  #
  # @param fixed [Hash] choices the caller makes regardless of the query string
  # @return [Hash] the operation's payload
  def team_capabilities(**fixed)
    Operations::Assessments::TeamCapabilities.call(context: pundit_user, params: team_choices.merge(fixed))
  rescue Operations::Base::ParameterError
    Operations::Assessments::TeamCapabilities.call(context: pundit_user, params: fixed)
  end

  def team_choices
    { people: params[:team_people].presence, role_id: params[:team_role].presence,
      level_ordinal: params[:team_level].presence&.to_i, ratings: params[:team_ratings].presence,
      compare: params[:team_compare].presence }.compact
  end
end
