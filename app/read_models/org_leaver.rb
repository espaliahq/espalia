# frozen_string_literal: true

# A person who has left, and the day they left. Someone who returns has no row.
#
# Projected from the person streams by {OrgGraph::Projections::Leavers}, and
# nothing else writes it. The id derives from the person, so a rebuild keeps it.
#
class OrgLeaver < ApplicationRecord
  include DeterministicId
  deterministic_id_from :person_id

  acts_as_tenant :tenant

  belongs_to :tenant
  # Optional, so a projection never fails on a row it doesn't own.
  belongs_to :person, optional: true

  # The leavers whose retention period has ended, longest gone first. None
  # while the tenant keeps leavers for ever.
  #
  # @param tenant [Tenant]
  # @param on [Date]
  # @return [ActiveRecord::Relation<OrgLeaver>]
  def self.due_to_be_forgotten(tenant, on: Date.current)
    cutoff = tenant.org_graph_config.forget_left_on_or_before(on)
    return none unless cutoff

    where(tenant:, left_on: ..cutoff).order(:left_on, :person_id)
  end
end
