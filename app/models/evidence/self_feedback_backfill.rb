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
# the item's run the way "Suggest again" does. A run that finds nothing
# leaves no row, so every enqueued item is also remembered for `REMEMBER`:
# running the backfill again inside that time enqueues nothing new.
class Evidence::SelfFeedbackBackfill
  DEFAULT_PER_MINUTE = 20
  REMEMBER = 90.days
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
      done = Rails.cache.read_multi(*ids.map { |id| remembered_key(id) })
      ids.reject { |id| done.key?(remembered_key(id)) }
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
        next unless Evidence::SuggestPlacementsJob.request_run(id, wait: wait)

        Rails.cache.write(remembered_key(id), true, expires_in: REMEMBER)
        scheduled += 1
      end
    end
    scheduled
  end

  private

  def tenants
    @tenants ||= (@tenant_slug ? Tenant.where(slug: @tenant_slug) : Tenant.all).order(:slug).to_a
  end

  def remembered_key(id) = "evidence-suggestions:self-backfill:#{id}"

  def eligible?(tenant) = Evidence::PlacementSuggestionRows.regenerable?(tenant)

  def scope
    EvidenceItem.active.where(source: "self").where.not(capability_stable_id: nil)
      .where.not(id: EvidencePlacementSuggestion.where(status: SETTLED_STATUSES).select(:evidence_id))
      .order(:recorded_at, :id)
  end
end
