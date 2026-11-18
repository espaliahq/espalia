# frozen_string_literal: true

# Reads the team card's and team map's choices from the query string into
# `Operations::Assessments::TeamCapabilities`, so both read one payload.
module Assessments::TeamCapabilitiesParams
  private

  # A choice the operation refuses falls back to the defaults rather than failing the page.
  #
  # @return [Hash] the operation's payload
  def team_capabilities
    Operations::Assessments::TeamCapabilities.call(context: pundit_user, params: team_choices)
  rescue Operations::Base::ParameterError
    Operations::Assessments::TeamCapabilities.call(context: pundit_user)
  end

  def team_choices
    { people: params[:team_people].presence, role_id: params[:team_role].presence,
      level_ordinal: params[:team_level].presence&.to_i, ratings: params[:team_ratings].presence }.compact
  end
end
