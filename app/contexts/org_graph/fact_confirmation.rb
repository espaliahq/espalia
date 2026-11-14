# frozen_string_literal: true

# Confirming that a fact Espalia holds about a person is still true. Mixed
# into {OrgGraph::PersonAggregate}, whose facts, providers and memberships it
# reads.
module OrgGraph::FactConfirmation
  extend ActiveSupport::Concern

  MEMBERSHIP = "membership"

  included do
    # Confirming changes no fact, so there is no state to move.
    on(OrgGraph::Events::FactConfirmed) { |_event| }
  end

  class_methods do
    # @return [Array<String>] the facts a confirmation can name
    def confirmable_facts
      @confirmable_facts ||= (const_get(:FACT_KEYS).map(&:to_s) + [ MEMBERSHIP ]).freeze
    end
  end

  # @param fact [String, Symbol] a person fact key, or "membership"
  # @param confirmed_by_id [String] person_id of whoever confirms it
  # @param effective_on [Date, String] the day it was confirmed
  # @param unit_id [String, nil] the unit, for a membership
  # @raise [RuntimeError] unless Espalia holds the fact for a person still here
  def confirm_fact(fact, confirmed_by_id:, effective_on:, unit_id: nil)
    ensure_recorded!
    raise "A person who has left has no facts to confirm" if @employment_status == "left"
    raise "Confirmed by can't be blank" if confirmed_by_id.blank?

    fact = fact.to_s
    raise "Unknown fact: #{fact}" unless self.class.confirmable_facts.include?(fact)

    unit_id = confirmed_unit(fact, unit_id)
    raise "Only a fact Espalia holds can be confirmed" unless held_by_espalia?(fact, unit_id, effective_on)

    apply(OrgGraph::Events::FactConfirmed.new(data: provenance("espalia", effective_on).merge(
      fact: fact, unit_id: unit_id, confirmed_by_id: confirmed_by_id
    )))
  end

  private

  def confirmed_unit(fact, unit_id)
    return validated_unit(unit_id) if fact == MEMBERSHIP
    raise "Only a membership names a unit" if unit_id.present?

    nil
  end

  def held_by_espalia?(fact, unit_id, effective_on)
    if fact == MEMBERSHIP
      raise "Not a member of this unit" unless @memberships.key?(unit_id)

      @memberships.dig(unit_id, :provider) == "espalia"
    else
      held = fact_point(fact.to_sym, normalize_date(effective_on, :effective_on))
      !held&.value.nil? && held.provider == "espalia"
    end
  end
end
