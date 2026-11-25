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

  # The ids of the leavers whose retention period has ended, longest gone
  # first. Ids only, so nothing that lists them can show who they are. Empty
  # while the tenant keeps leavers for ever.
  #
  # @param tenant [Tenant]
  # @param on [Date]
  # @param retention_years [Integer, nil] the period already read, when the caller reports it
  # @return [Array<String>] person ids
  def self.due_to_be_forgotten(tenant, on: Date.current, retention_years: TenantRetentionSetting.period(tenant))
    return [] unless retention_years

    where(tenant:, left_on: ..(on - retention_years.years)).order(:left_on, :person_id).pluck(:person_id)
  end
end
