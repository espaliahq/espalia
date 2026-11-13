# frozen_string_literal: true

# When a fact Espalia holds about a person was last changed or confirmed, and
# by whom when known. A fact another provider holds has no row.
#
# Projected from the person streams by {OrgGraph::Projections::FactAges}, and
# nothing else writes it. The id derives from the person and the fact, so a
# rebuild keeps it.
#
class OrgFactAge < ApplicationRecord
  include DeterministicId
  deterministic_id_from :person_id, :fact_key

  acts_as_tenant :tenant

  belongs_to :tenant
  # Optional, so a projection never fails on a row it doesn't own.
  belongs_to :person, optional: true
  belongs_to :unit, class_name: "OrgUnit", optional: true
  belongs_to :checked_by, class_name: "Person", optional: true

  # The facts nobody has changed or confirmed within the tenant's threshold,
  # oldest first. A leaver's facts are never stale, nor a membership of a
  # retired unit.
  #
  # @param tenant [Tenant]
  # @param now [Time]
  # @return [ActiveRecord::Relation<OrgFactAge>]
  def self.stale(tenant, now: Time.current)
    leavers = where(tenant:, fact: OrgGraph::Projections::FactAges::LEFT).select(:person_id)
    retired = OrgUnit.where(tenant:).where.not(retired_on: nil).select(:id)

    where(tenant:, unit_id: nil).or(where(tenant:).where.not(unit_id: retired))
      .where.not(fact: OrgGraph::Projections::FactAges::LEFT)
      .where.not(person_id: leavers)
      .where(checked_at: ...tenant.org_graph_config.stale_before(now))
      .order(:checked_at, :id)
  end

  # @return [Boolean]
  def membership? = fact == OrgGraph::FactConfirmation::MEMBERSHIP

  # The fact, with its unit for a membership: never blank, so the id can derive
  # from it. Frozen once rows exist, as the id depends on it.
  #
  # @return [String] such as "title" or "membership:<unit id>"
  def fact_key = [ fact, unit_id ].compact.join(":")
end
