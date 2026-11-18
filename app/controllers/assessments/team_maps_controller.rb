# frozen_string_literal: true

# The team capability map, loaded into the team card's dialog.
class Assessments::TeamMapsController < ApplicationController
  include Assessments::TeamCapabilitiesParams

  # GET /assessments/team-map
  def show
    authorize PersonFrameworkAssignment, :index?
    render Views::Assessments::TeamMap.new(team: team_capabilities)
  end
end
