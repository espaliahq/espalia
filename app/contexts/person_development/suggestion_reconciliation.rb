# frozen_string_literal: true

# Records on each development stream what the suggestions table holds and
# the stream doesn't, so the `person_development/evidence_suggestions`
# projection can adopt the table without a rebuild
# ([#539](https://github.com/espaliahq/espalia/issues/539) c3).
#
# The table is the truth, as for every reconciler, but nothing is ever
# removed: a forgotten person's rows are deleted along with their stream.
# Each stream is caught up under the locks a command takes, so the release
# still serving can't write between the read and the record.
#
# @example
#   PersonDevelopment::SuggestionReconciliation.new(tenant).call
#   # => #<data Report added=3, removed=0, changed=0>
class PersonDevelopment::SuggestionReconciliation
  # @param tenant [Tenant]
  def initialize(tenant)
    @tenant = tenant
  end

  # @return [TenantStreams::Reconciliation::Report] added counts the rows recorded
  def call
    ActsAsTenant.with_tenant(@tenant) do
      added = streams.sum do |(person_id, framework_id), evidence_ids|
        PersonDevelopment::SuggestionWrites.with_caught_up(person_id, framework_id, evidence_ids:) { |_, caught_up| caught_up }
      end
      TenantStreams::Reconciliation::Report.new(added:, removed: 0, changed: 0)
    end
  end

  private

  def streams
    EvidencePlacementSuggestion.distinct.pluck(:person_id, :framework_id, :evidence_id)
      .group_by { it.first(2) }.transform_values { it.map(&:last) }
  end
end
