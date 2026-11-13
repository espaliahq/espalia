# frozen_string_literal: true

# One period of one fact, as the Org Graph knew it for a while: the fact held
# `value` from `effective_from` until the day before `effective_to` (open when
# nil), and the Org Graph believed so from `learned_at` until `superseded_at`
# (open when nil). A correction supersedes rows and adds new ones, so what was
# known at any earlier instant can still be read.
#
# The subject is a person, a unit or a succession, by id only. A person's
# memberships are keyed by unit; every other fact has an empty key. A
# membership's value is nil while the person is not a member.
#
# Projected from the person and structure streams by
# {OrgGraph::Projections::History}, and nothing else writes it.
#
class OrgFactPeriod < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tenant

  # The rows the Org Graph believed at an instant.
  #
  # @param time [Time]
  scope :known_at, ->(time) { where(learned_at: ..time).where("superseded_at IS NULL OR superseded_at > ?", time) }

  # The rows describing a given day.
  #
  # @param date [Date]
  scope :in_effect_on, ->(date) { where(effective_from: ..date).where("effective_to IS NULL OR effective_to > ?", date) }

  # The rows the Org Graph believes now.
  scope :current, -> { where(superseded_at: nil) }
end
