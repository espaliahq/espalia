# frozen_string_literal: true

require "test_helper"

# Grants move from the AccountGrants stream to TenantAccountGrants while the
# previous release, which knows only the old stream, may still be serving.
class AccountGrants::StreamMoveTest < ActiveSupport::TestCase
  PROJECTION = AccountGrants::Projections::AccountFlags

  # The repository as the previous release had it.
  class PreviousRepository < TenantStreams::Repository
    alias with_grants with_aggregate

    private

    def new_aggregate = AccountGrants::Aggregate.new

    def stream_name(tenant) = EventStreamNaming.account_grants_stream(tenant:)
  end

  setup do
    @tenant = create(:tenant)
    @previous = AccountGrants::CommandHandler.new(repository: PreviousRepository.new)
    @current = AccountGrants::CommandHandler.new
    as_tenant do
      @ada, @bo, @cy = Array.new(3) { create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant)) }
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def ids(stream) = Rails.configuration.event_store.read.stream(stream).map(&:event_id)

  def old_ids = ids(EventStreamNaming.account_grants_stream(tenant: @tenant))

  def new_ids = ids(EventStreamNaming.tenant_account_grants_stream(tenant: @tenant))

  def flags(account) = TenantUser.unscoped.find(account.id).slice(*PROJECTION::COLUMNS).values

  def remove(handler, grant, account) = handler.remove(grant, tenant_user_id: account.id, person_id: account.person_id)

  should "link every grant the previous release wrote into the new stream when reconcile runs, in the same order" do
    as_tenant do
      @previous.add(:org_graph_editor, @ada)
      @previous.add(:team_planner, @bo)
      remove(@previous, :org_graph_editor, @ada)
    end
    written = old_ids

    report = AccountGrants::Reconciliation.new(@tenant).call

    assert_equal [ 0, 0 ], [ report.added, report.removed ]
    assert_equal 3, written.size
    assert_equal written, old_ids
    assert_equal written, new_ids
  end

  should "keep both streams equal as the two releases take turns, each seeing every grant" do
    steps = [
      -> { @previous.add(:org_graph_editor, @ada) },
      -> { @current.add(:team_planner, @bo) },
      -> { remove(@previous, :team_planner, @bo) },
      -> { @current.add(:org_graph_editor, @cy) },
      -> { remove(@current, :org_graph_editor, @ada) },
      -> { @previous.add(:team_planner, @ada) }
    ]

    steps.each_with_index do |step, index|
      as_tenant { step.call }

      as_tenant do
        AccountGrants::Repository.new.reading_locked do |grants|
          assert_equal old_ids, new_ids, "the streams differ after step #{index + 1}"
          assert_equal index + 1, new_ids.size
          held = AccountGrants::Aggregate::GRANTS.to_h { [ it, grants.holders(it).keys.sort ] }
          assert_equal held, AccountGrants::Aggregate::GRANTS.to_h { [ it, PreviousRepository.new.load_aggregate.holders(it).keys.sort ] }
        end
      end
    end
    assert_equal [ [ false, true ], [ false, false ], [ true, false ] ], [ @ada, @bo, @cy ].map { flags(it) }
  end

  should "see a grant the previous release just wrote, before anything links it" do
    as_tenant do
      @current.add(:team_planner, @bo)
      @previous.add(:org_graph_editor, @ada)

      assert AccountGrants::Repository.new.load_grants.holds?(:org_graph_editor, @ada.id)
    end
    assert_equal 1, new_ids.size
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
