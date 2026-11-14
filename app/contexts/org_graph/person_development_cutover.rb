# frozen_string_literal: true

# Moves one tenant's Person Development assignments, moves, offboarding and
# reporting managers from the HRIS sync to {OrgGraph::PersonDevelopmentFeed},
# or back.
#
# A run reconciles every HRIS-held person without issuing anything and
# reports what the feed would change. The old sync never cleared a lost
# manager, so manager clears are expected; anything else means the Org Graph
# and Person Development disagree, and the cut-over refuses. Applying needs
# the clear count the dry run printed, so nobody clears managers they have
# not seen counted.
#
# @example
#   cutover = OrgGraph::PersonDevelopmentCutover.new(tenant)
#   report = cutover.run(apply: false)
#   cutover.run(apply: true, confirm_clears: report.changes.fetch(:clear_manager, []).size)
#   cutover.revert!
class OrgGraph::PersonDevelopmentCutover
  # The changes a clean cut-over may carry.
  EXPECTED = %i[clear_manager].freeze

  # What a run found and did. Ids only, never names or emails.
  #
  # @!attribute changes [Hash{Symbol => Array<String>}] change kind to the person ids it would touch
  # @!attribute failed [Hash{String => String}] person id to why they could not be read
  # @!attribute refusal [String, nil] why the cut-over was not applied, when it was asked to be
  # @!attribute applied [Boolean] whether the tenant is now fed
  Report = Data.define(:changes, :failed, :refusal, :applied) do
    # @return [Array<Symbol>] the change kinds a clean cut-over must not carry
    def unexpected = changes.keys - EXPECTED

    # @return [Integer]
    def clears = changes.fetch(:clear_manager, []).size
  end

  # @param tenant [Tenant]
  def initialize(tenant)
    @tenant = tenant
  end

  # @param apply [Boolean] feed the tenant when the dry run is clean
  # @param confirm_clears [Integer, nil] the manager clears the operator saw counted
  # @return [Report]
  # @raise [ArgumentError] if the tenant is already fed or its people are not cut over
  def run(apply:, confirm_clears: nil)
    report = nil
    ActiveRecord::Base.transaction do
      @tenant.lock!
      raise ArgumentError, "Tenant is already fed from the Org Graph" if @tenant.person_development_fed?
      raise ArgumentError, "Cut the tenant's people over to the Org Graph first" unless @tenant.org_graph_people_projected?
      raise "A sync is running for this tenant; try again once it ends" unless exclusive_lock

      ActsAsTenant.with_tenant(@tenant) do
        changes, failed = preview
        report = Report.new(changes:, failed:, refusal: nil, applied: false)
        if apply
          refusal = refusal_for(report, confirm_clears)
          report = refusal ? report.with(refusal:) : feed!(report)
        end
      end
    end
    @tenant.reload
    report
  end

  # Hands assignments, moves, offboarding and managers back to the HRIS
  # sync. The next sync applies the title mapping as it did before.
  def revert!
    ActiveRecord::Base.transaction do
      raise "A sync is running for this tenant; try again once it ends" unless exclusive_lock

      @tenant.update!(person_development_fed_at: nil)
    end
  end

  private

  def preview
    feed = OrgGraph::PersonDevelopmentFeed.new(@tenant, apply: false)
    changes = Hash.new { |all, kind| all[kind] = [] }
    failed = {}
    Person.hris_managed.ids.sort.each do |person_id|
      feed.reconcile(person_id).each { changes[it] << person_id }
    rescue => e
      failed[person_id] = e.message
    end
    [ changes.sort_by { |kind, _| OrgGraph::PersonDevelopmentFeed::KINDS.index(kind) }.to_h, failed ]
  end

  def refusal_for(report, confirm_clears)
    return "#{report.failed.size} people could not be read" if report.failed.any?
    return "the Org Graph disagrees with Person Development: #{report.unexpected.join(', ')}" if report.unexpected.any?
    return "#{report.clears} manager clears were counted, not #{confirm_clears.to_i}" unless confirm_clears.to_i == report.clears

    nil
  end

  def feed!(report)
    @tenant.update!(person_development_fed_at: Time.current)
    feed = OrgGraph::PersonDevelopmentFeed.new(@tenant)
    AuditMetadata.with(acting_via: :system, correlation_id: SecureRandom.uuid_v7) do
      AuditMetadata.wrap_event_store do
        report.changes.fetch(:clear_manager, []).each { feed.reconcile(it) }
      end
    end
    report.with(applied: true)
  end

  def exclusive_lock
    sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_xact_lock(?)", OrgGraph::PeopleCutover.lock_key(@tenant) ])
    ActiveRecord::Base.connection.select_value(sql)
  end
end
