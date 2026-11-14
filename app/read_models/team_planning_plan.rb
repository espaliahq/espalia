# frozen_string_literal: true

# A plan that has not been deleted, with its name, base date and creator.
#
# Projected from the plan streams by {TeamPlanning::Projections::Plans}, and
# nothing else writes it. Its id is the plan's, so a rebuild keeps it.
#
class TeamPlanningPlan < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tenant
end
