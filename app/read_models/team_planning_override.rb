# frozen_string_literal: true

# One facet of one subject a scenario overrides: by a change it set, or by a
# pin of what it inherited.
#
# Projected from the plan streams by {TeamPlanning::Projections::Overrides},
# and nothing else writes it. A cleared override leaves it; the stream keeps
# it for history. The id derives from the scenario, the subject and the
# facet, so a rebuild keeps it. The note is the planner's, sealed under its
# subject's key.
#
class TeamPlanningOverride < ApplicationRecord
  include DeterministicId
  include Shreddable::Column
  deterministic_id_from :scenario_id, :subject_id, :facet
  shreddable_column :note, by: :person, person: TeamPlanning::ChangeKinds::NOTED_PERSON

  acts_as_tenant :tenant

  belongs_to :tenant
  # Optional, so a projection never fails on a row it doesn't own.
  belongs_to :plan, class_name: "TeamPlanningPlan", optional: true
  belongs_to :set_by, class_name: "Person", optional: true
end
