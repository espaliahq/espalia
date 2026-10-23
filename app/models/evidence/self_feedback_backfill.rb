# frozen_string_literal: true

# Asks for placement suggestions on self feedback recorded before it got them
# (https://github.com/mr-yum/growth-os/issues/622). Nothing runs this on its
# own: new and edited self feedback gets suggestions as it is written, and
# `bin/rails evidence:suggestions:backfill_self` covers the rest when an
# admin chooses to.
#
# Candidates are active, placed self feedback with no pending or decided
# suggestion, in workspaces with suggestions on and a model configured; an
# item whose earlier set was only superseded still counts. Every run is a
# paid model call, so runs are spread `per_minute` at a time and each claims
# the item's run the way "Suggest again" does. An answer that suggests
# nothing leaves no row, so the job remembers every item the model answered
# about ({Evidence::SuggestPlacementsJob::ANSWER_REMEMBERED}) and the
# backfill skips it; a run that gave up leaves the item for the next one.
class Evidence::SelfFeedbackBackfill
  DEFAULT_PER_MINUTE = 20
  SETTLED_STATUSES = [ "pending", *EvidencePlacementSuggestion::DECIDED_STATUSES ].freeze

  attr_reader :per_minute

  # @param tenant_slug [String, nil] one workspace, or every eligible one
  # @param per_minute [Integer, String] runs to schedule per minute
  # @raise [ArgumentError] for a slug no workspace has, or a rate below 1
  def initialize(tenant_slug: nil, per_minute: DEFAULT_PER_MINUTE)
    @tenant_slug = tenant_slug.presence
    @per_minute = Integer(per_minute, exception: false)
    raise ArgumentError, "PER_MINUTE must be a whole number of at least 1, not #{per_minute.inspect}" unless @per_minute&.positive?
    raise ArgumentError, "No workspace has the slug #{@tenant_slug.inspect}" if @tenant_slug && tenants.empty?
  end

  # @return [Hash{Tenant => Array<String>}] candidate item ids per eligible
  #   workspace, oldest first
  def candidates
    @candidates ||= tenants.select { |tenant| eligible?(tenant) }.index_with do |tenant|
      ids = ActsAsTenant.with_tenant(tenant) { scope.pluck(:id) }
      answered = Rails.cache.read_multi(*ids.map { |id| Evidence::SuggestPlacementsJob.answered_key(id) })
      ids.reject { |id| answered.key?(Evidence::SuggestPlacementsJob.answered_key(id)) }
    end
  end

  # @return [Array<Tenant>] workspaces in scope with suggestions off or no
  #   model, which the backfill leaves alone
  def skipped_tenants
    tenants.reject { |tenant| eligible?(tenant) }
  end

  # @return [Integer] how many runs the backfill would ask for
  def count
    candidates.values.sum(&:size)
  end

  # @param runs [Integer]
  # @return [Integer] minutes until the last of `runs` is due
  def minutes(runs = count)
    runs.zero? ? 0 : (runs - 1) / per_minute
  end

  # Schedules one run per candidate, `per_minute` to a minute.
  #
  # @return [Integer] runs enqueued (an item already claimed is skipped)
  def enqueue!
    scheduled = 0
    candidates.each_value do |ids|
      ids.each do |id|
        wait = (scheduled / per_minute).minutes
        scheduled += 1 if Evidence::SuggestPlacementsJob.request_run(id, wait: wait)
      end
    end
    scheduled
  end

  private

  def tenants
    @tenants ||= (@tenant_slug ? Tenant.where(slug: @tenant_slug) : Tenant.all).order(:slug).to_a
  end

  def eligible?(tenant) = Evidence::PlacementSuggestionRows.regenerable?(tenant)

  # Like the handler, never items an HRIS sync or a system job wrote.
  def scope
    via = EvidenceItem.arel_table[:recorded_via]
    EvidenceItem.active.where(source: "self").where.not(capability_stable_id: nil)
      .where(via.eq(nil).or(via.not_in(PersonDevelopment::AsyncHandlers::PlacementSuggester::NON_HUMAN_SURFACES)))
      .where.not(id: EvidencePlacementSuggestion.where(status: SETTLED_STATUSES).select(:evidence_id))
      .order(:recorded_at, :id)
  end
end
