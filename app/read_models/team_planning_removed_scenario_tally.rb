# frozen_string_literal: true

# How many changes a removed scenario still held: one for each subject and
# facet it changed, pinned or kept, leaving out what was undone or cleared.
# A count only, so it says nothing about a subject, a facet or a value.
#
# Projected from the plan streams by {TeamPlanning::Projections::History},
# from the entries it drops, and nothing else writes it. Its id is the
# scenario's.
#
class TeamPlanningRemovedScenarioTally < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tenant
  # Optional, so a projection never fails on a row it doesn't own.
  belongs_to :plan, class_name: "TeamPlanningPlan", optional: true
end
