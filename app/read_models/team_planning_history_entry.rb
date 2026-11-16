# frozen_string_literal: true

# One entry of a scenario's history: a change, pin or clear it made, an
# undo or redo of one, or, in the baseline, an update to today or the plan
# being archived or restored, with who did it and when. A move is an entry of
# the step the change moved to. A step's new dates are a `dates` entry, and
# closing or reopening it a `close` or `reopen` entry.
#
# Projected from the plan streams by {TeamPlanning::Projections::History},
# and nothing else writes it. Its id is the event's, so a rebuild keeps it.
# An undo and a redo carry the subject and facet of the entry they reverse,
# and an entry that stands undone says who undid it. A change or pin keeps
# the note it was made with, sealed under its subject's key, and a note entry
# keeps each rewrite of it, naming the change in `noted_event_id`.
#
class TeamPlanningHistoryEntry < ApplicationRecord
  include Shreddable::Column

  ACTIONS = %w[set pin clear undo redo note rebase move dates archive restore close reopen].freeze

  shreddable_column :note, by: :person, person: TeamPlanning::ChangeKinds::NOTED_PERSON

  acts_as_tenant :tenant

  belongs_to :tenant
  # Optional, so a projection never fails on a row it doesn't own.
  belongs_to :plan, class_name: "TeamPlanningPlan", optional: true
  belongs_to :actor, class_name: "Person", optional: true
  belongs_to :undone_by, class_name: "Person", optional: true

  validates :action, inclusion: { in: ACTIONS }

  # @return [Boolean]
  def undone? = !undone_at.nil?

  # The subjects and facets each scenario still changes, as the plan's log
  # works them out: a standing change or pin holds its key and a clear lets
  # it go; undone entries, undos, redos, notes, moves, dates, closes and reopens hold nothing.
  # The Removed scenarios tally keeps this count, so a scenario's count
  # before it is removed matches its entry afterwards.
  #
  # @param scenario_ids [Array<String>]
  # @return [Hash{String => Integer}] keyed by scenario id; absent means none
  def self.changes_held(scenario_ids)
    last_word = where(scenario_id: scenario_ids, undone_at: nil, action: %w[set pin clear])
                .select("DISTINCT ON (scenario_id, subject_id, facet) scenario_id, action")
                .order(:scenario_id, :subject_id, :facet, position: :desc)
    unscoped.from(last_word, :last_word).where("last_word.action <> 'clear'").group("last_word.scenario_id").count
  end
end
