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

  # The rows the Org Graph believed at the end of a day in the tenant's time zone, or now.
  #
  # @param date [Date, nil] nil for what the Org Graph believes now
  # @param at [Time, nil] the instant that day ended, when a reader fixed it
  #   earlier, so a later change of zone doesn't move it
  scope :known_on, ->(date, at: nil) { at ? known_at(at) : date ? known_at(Tenant.end_of(date)) : current }

  # Every unit type's name, removed ones included, so history can name a type
  # the live taxonomy no longer holds. A live type takes its current name.
  #
  # @return [Hash{String => String}] level_id => name
  def self.kind_names
    named = current.where(subject_type: OrgGraph::Projections::History::LEVEL, fact: "kind")
                   .where("value ? 'name'").order(:effective_from)
    named.pluck(:subject_id, Arel.sql("value ->> 'name'")).to_h.merge(OrgTaxonomyLevel.pluck(:id, :name).to_h)
  end
end
