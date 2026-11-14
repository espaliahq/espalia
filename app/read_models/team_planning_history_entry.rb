# frozen_string_literal: true

# One entry of a scenario's history: a change, pin or clear it made, or an
# undo or redo of one, with who did it and when.
#
# Projected from the plan streams by {TeamPlanning::Projections::History},
# and nothing else writes it. Its id is the event's, so a rebuild keeps it.
# An undo and a redo carry the subject and facet of the entry they reverse,
# and an entry that stands undone says who undid it. A change or pin keeps
# the note it was made with, sealed under the plan's key.
#
class TeamPlanningHistoryEntry < ApplicationRecord
  include Shreddable::Column

  ACTIONS = %w[set pin clear undo redo].freeze

  shreddable_column :note, by: :plan

  acts_as_tenant :tenant

  belongs_to :tenant
  # Optional, so a projection never fails on a row it doesn't own.
  belongs_to :plan, class_name: "TeamPlanningPlan", optional: true
  belongs_to :actor, class_name: "Person", optional: true
  belongs_to :undone_by, class_name: "Person", optional: true

  validates :action, inclusion: { in: ACTIONS }

  # @return [Boolean]
  def undone? = !undone_at.nil?
end
