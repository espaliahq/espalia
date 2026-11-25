# frozen_string_literal: true

require "test_helper"

# Grants moved from the AccountGrants stream to TenantAccountGrants. The
# previous release still links grant events back into the old stream and
# reads it without the lock; this one links nothing back.
class AccountGrants::StreamMoveTest < ActiveSupport::TestCase
  PROJECTION = AccountGrants::Projections::AccountFlags

  # The repository as the previous release has it.
  class PreviousRepository < TenantStreams::Repository
    LEGACY_EVENTS = [
      AccountGrants::Events::OrgGraphEditorAdded, AccountGrants::Events::OrgGraphEditorRemoved,
      AccountGrants::Events::PlannerAdded, AccountGrants::Events::PlannerRemoved
    ].freeze

    def with_aggregate(&block)
      ActiveRecord::Base.transaction do
        super.tap { link_missing(from: stream_name(current_tenant!), to: legacy_stream_name(current_tenant!), only: LEGACY_EVENTS) }
      end
    end

    def load_aggregate = @repository.load(new_aggregate, legacy_stream_name(current_tenant!))

    alias with_grants with_aggregate

    private

    def new_aggregate = AccountGrants::Aggregate.new

    def stream_name(tenant) = EventStreamNaming.tenant_account_grants_stream(tenant:)

    def legacy_stream_name(tenant) = EventStreamNaming.account_grants_stream(tenant:)

    def lock_key(tenant) = legacy_stream_name(tenant)

    def lock_stream(tenant)
      super
      link_missing(from: legacy_stream_name(tenant), to: stream_name(tenant))
    end

    def link_missing(from:, to:, only: nil)
      linked = @event_store.read.stream(to).map(&:event_id).to_set
      source = @event_store.read.stream(from)
      source = source.of_type(only) if only
      missing = source.map(&:event_id).reject { linked.include?(it) }
      @event_store.link(missing, stream_name: to) if missing.any?
    end
  end

  # The repository before the move, which knows only the old stream.
  class OldStreamRepository < TenantStreams::Repository
    alias with_grants with_aggregate

    private

    def new_aggregate = AccountGrants::Aggregate.new

    def stream_name(tenant) = EventStreamNaming.account_grants_stream(tenant:)
  end

  setup do
    @tenant = create(:tenant)
    @previous = AccountGrants::CommandHandler.new(repository: PreviousRepository.new)
    @old_stream = AccountGrants::CommandHandler.new(repository: OldStreamRepository.new)
    @current = AccountGrants::CommandHandler.new
    as_tenant do
      @ada, @bo, @cy = Array.new(3) { create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant)) }
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def ids(stream) = Rails.configuration.event_store.read.stream(stream).map(&:event_id)

  def old_ids = ids(EventStreamNaming.account_grants_stream(tenant: @tenant))

  def new_ids = ids(EventStreamNaming.tenant_account_grants_stream(tenant: @tenant))

  def flags(account) = TenantUser.unscoped.find(account.id).slice(*AccountGrants::Aggregate::GRANTS.map(&:to_s)).values

  def remove(handler, grant, account) = handler.remove(grant, tenant_user_id: account.id, person_id: account.person_id)

  should "link every grant written to the old stream into the new stream when reconcile runs, in the same order" do
    as_tenant do
      @old_stream.add(:org_graph_editor, @ada)
      @old_stream.add(:team_planner, @bo)
      remove(@old_stream, :org_graph_editor, @ada)
    end
    written = old_ids

    report = AccountGrants::Reconciliation.new(@tenant).call

    assert_equal [ 0, 0 ], [ report.added, report.removed ]
    assert_equal 3, written.size
    assert_equal written, old_ids
    assert_equal written, new_ids
  end

  should "see every grant under the lock as the two releases take turns, the old stream growing only as the previous release writes" do
    steps = [
      -> { @previous.add(:org_graph_editor, @ada) },
      -> { @current.add(:team_planner, @bo) },
      -> { remove(@previous, :team_planner, @bo) },
      -> { @current.add(:org_graph_editor, @cy) },
      -> { remove(@current, :org_graph_editor, @ada) },
      -> { @previous.add(:team_planner, @ada) }
    ]
    by_previous = [ 0, 2, 5 ]

    steps.each_with_index do |step, index|
      as_tenant { step.call }

      as_tenant do
        held = AccountGrants::Repository.new.reading_locked { |grants| AccountGrants::Aggregate::GRANTS.to_h { [ it, grants.holders(it).keys.sort ] } }
        previous = PreviousRepository.new.reading_locked { |grants| AccountGrants::Aggregate::GRANTS.to_h { [ it, grants.holders(it).keys.sort ] } }
        assert_equal previous, held, "the releases differ after step #{index + 1}"
      end
      assert_equal index + 1, new_ids.size
      assert_equal new_ids.first(by_previous.select { it <= index }.max.to_i + 1), old_ids, "after step #{index + 1}"
    end
    assert_equal [ [ false, true ], [ false, false ], [ true, false ] ], [ @ada, @bo, @cy ].map { flags(it) }
  end

  should "read the new stream without the lock, which the previous release's read misses" do
    as_tenant do
      @current.add(:team_planner, @bo)

      assert AccountGrants::Repository.new.load_grants.holds?(:team_planner, @bo.id)
      assert_not PreviousRepository.new.load_aggregate.holds?(:team_planner, @bo.id)
    end
    assert_empty old_ids
  end

  should "rebuild every flag from the linked stream" do
    as_tenant do
      @previous.add(:org_graph_editor, @ada)
      @current.add(:team_planner, @bo)
      @previous.add(:org_graph_editor, @cy)
      remove(@current, :org_graph_editor, @cy)
      @previous.add(:team_planner, @ada)
    end
    AccountGrants::Reconciliation.new(@tenant).call
    before = [ @ada, @bo, @cy ].map { flags(it) }
    TenantUser.where(id: [ @ada, @bo, @cy ].map(&:id)).update_all(org_graph_editor: false, team_planner: false)

    PROJECTION.reset!(tenant: @tenant)

    assert_equal [ [ true, true ], [ false, true ], [ false, false ] ], before
    assert_equal before, [ @ada, @bo, @cy ].map { flags(it) }
  end

  should "lock the old stream's name, so both releases take one lock" do
    statements = []
    record = ->(*, payload) { statements << payload[:sql] }

    ActiveSupport::Notifications.subscribed(record, "sql.active_record") { as_tenant { @current.add(:team_planner, @bo) } }

    locks = statements.select { it.include?("pg_advisory_xact_lock") }
    assert_equal 1, locks.size
    assert_includes locks.first, EventStreamNaming.account_grants_stream(tenant: @tenant)
  end
end
