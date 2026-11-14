# frozen_string_literal: true

# The person drawer's read (#132): one person's teams, employment facts and
# history, as the Org Graph holds them.
class Operations::OrgGraph::PersonGet < Operations::Base
  description "Read one person as the Org Graph holds them: their memberships of live units (unit, role, " \
              "allocation, since, and the provider that holds each, \"espalia\" or an HRIS), their employment " \
              "facts in effect today (title, level, manager, cost centre, site, employment, start date), each " \
              "with its provider and since when, and their history newest first: each change with the day it " \
              "took effect, when the Org Graph learned it, its provider and who made it. A membership or fact " \
              "Espalia holds that nobody has changed or confirmed within the tenant's threshold carries " \
              "stale: when it was last checked and by whom. A forgotten person " \
              "reads as \"Former member\". Admins only while the Org Graph is unfinished."
  category :read
  approval :none

  parameter :person_id, String, required: true

  def policy_check
    authorize :org_graph, :show_units?
  end

  # The profile the read was built from, for the web drawer, which renders
  # units and people rather than their JSON.
  #
  # @return [OrgGraph::PersonProfile, nil] nil until {#call} has run
  attr_reader :profile, :stale

  # @return [Hash] `{ person, memberships, employment, history }`
  def perform
    person = ::Person.find_by(id: params[:person_id].to_s.downcase) or
      raise Operations::Base::ParameterError, "person_id names no person in this tenant"
    @profile = ::OrgGraph::PersonProfile.new(person)
    @stale = ::OrgGraph::StaleFacts.new(person_ids: [ person.id ])

    {
      person: { id: person.id, name: person.name, status: person.status, forgotten: person.forgotten? },
      memberships: profile.memberships.map { |membership| membership_payload(membership) },
      employment: profile.employment.map { |fact| employment_payload(person, fact) },
      history: profile.history.map { |change| change_payload(change) }
    }
  end

  private

  def membership_payload(membership)
    { unit_id: membership.unit_id, unit_name: membership.unit.name, role: membership.role,
      allocation: membership.allocation, since: membership.member_since, provider: membership.provider,
      stale: stale_payload(stale.membership(membership.person_id, membership.unit_id)) }
  end

  def employment_payload(person, fact)
    fact.to_h.slice(:fact, :label, :value, :provider, :since)
        .merge(stale: stale_payload(stale.employment(person.id, fact.fact).first))
  end

  def stale_payload(age)
    age && { last_checked_on: age.checked_at.to_date, checked_by: age.checked_by && { id: age.checked_by.id, name: age.checked_by.name } }
  end

  def change_payload(change)
    { effective_on: change.effective_on, learned_at: change.learned_at.iso8601, fact: change.fact,
      summary: change.summary, provider: change.provider,
      actor: change.actor && { id: change.actor.id, name: change.actor.name } }
  end
end
