# frozen_string_literal: true

# The team capability map, loaded into the team card's dialog.
class Assessments::TeamMapsController < ApplicationController
  include Assessments::TeamCapabilitiesParams

  # GET /assessments/team-map
  def show
    authorize PersonFrameworkAssignment, :index?
    raise Pundit::NotAuthorizedError, "not linked to a person" unless current_person

    render Views::Assessments::TeamMap.new(team: team_capabilities)
  end
end
