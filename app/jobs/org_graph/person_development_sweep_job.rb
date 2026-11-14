# frozen_string_literal: true

# Reconciles every HRIS-held person in a fed tenant after its HRIS sync, so
# a title mapping edited since, or a reconcile the domain refused, catches
# up without waiting for that person's next Org Graph change.
#
# Each person is one short transaction under their stream lock and the
# cut-over hold, so the run never holds the sync's lock and a revert waits
# for one person, not the whole sweep. Running it twice changes nothing the
# second time. A person whose reconcile a projection rebuild refuses is
# counted under `skipped_while_rebuilding`, and the next sync's sweep takes
# them up. The log holds counts and person ids only.
#
# @example
#   OrgGraph::PersonDevelopmentSweepJob.perform_later(tenant)
class OrgGraph::PersonDevelopmentSweepJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: ->(tenant, **) { "org_graph_person_development_sweep:#{tenant.id}" }, duration: 1.hour

  # @param tenant [Tenant]
  # @param correlation_id [String, nil] the sync run it follows
  # @return [Hash{Symbol => Integer}] a count for each change kind made,
  #   `skipped_while_rebuilding` and `errors`
  def perform(tenant, correlation_id: nil)
    counts = Hash.new(0)
    ActsAsTenant.with_tenant(tenant) do
      AuditMetadata.with(acting_via: :hris, correlation_id: correlation_id || job_id) do
        AuditMetadata.wrap_event_store do
          sweepable.each { |person_id| sweep(tenant, person_id, counts) }
        end
      end
    end
    Rails.logger.info("[OrgGraph::PersonDevelopmentSweep] tenant=#{tenant.id} " +
                      counts.sort.map { |kind, count| "#{kind}=#{count}" }.join(" "))
    counts.to_h
  end

  private

  # A leaver with no assignment has nothing left to reconcile until they return.
  def sweepable
    Person.hris_managed.where(status: "active")
      .or(Person.hris_managed.where(id: PersonFrameworkAssignment.select(:person_id)))
      .ids
  end

  # A feed per person, so a rebuild that ends mid-run leaves no one planned
  # from the framework, roles and levels read before it.
  def sweep(tenant, person_id, counts)
    OrgGraph::PeopleCutover.hold_off(tenant) do
      next unless tenant.person_development_fed?

      changes = ActiveRecord::Base.transaction do
        OrgGraph::Repository.new.lock_person(person_id)
        OrgGraph::PersonDevelopmentFeed.new(tenant).reconcile(person_id)
      end
      changes.each { counts[it] += 1 }
    end
  rescue ProjectionVersion::Rebuilding
    counts[:skipped_while_rebuilding] += 1
  rescue => e
    Rails.logger.warn("[OrgGraph::PersonDevelopmentSweep] tenant=#{tenant.id} person=#{person_id} refused: #{e.class}: #{e.message}")
    counts[:errors] += 1
  end
end
