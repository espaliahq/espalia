# frozen_string_literal: true

require "test_helper"
require "rake"

class AccountGrantsReconcileTaskTest < ActiveSupport::TestCase
  PROJECTION = AccountGrants::Projections::AccountFlags
  TASKS = %w[account_grants:reconcile events:projections:stamp_if_no_events events:projections:verify
             events:projections:rebuild_if_stale events:projections:rebuild].freeze

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    TASKS.each { Rake::Task[it].reenable }
    @tenant = create(:tenant)
    as_tenant do
      @editor = account(org_graph_editor: true)
      @planner = account(team_planner: true)
      @member = account
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  # The flags are set behind the projection's back, as the previous release
  # wrote them.
  def account(**flags)
    create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant)).tap { it.update_columns(flags) if flags.any? }
  end

  def run_task(task, *args)
    out, = capture_io { Rake::Task[task].invoke(*args) }
    Rake::Task[task].reenable
    out
  end

  def reconcile = run_task("account_grants:reconcile")

  def events(tenant = @tenant)
    Rails.configuration.event_store.read.stream(EventStreamNaming.account_grants_stream(tenant:)).to_a
  end

  def flags(account) = TenantUser.unscoped.find(account.id).slice(*PROJECTION::COLUMNS).values

  def holds?(grant, account) = as_tenant { AccountGrants::Repository.new.load_grants.holds?(grant, account.id) }

  should "record each grant the flags hold as already held, with no grantor, as the system" do
    out = reconcile

    assert_match "[#{@tenant.id}] recorded 2 already held, 0 removed", out
    editor, planner = events
    assert_equal [ AccountGrants::Events::OrgGraphEditorAdded, AccountGrants::Events::PlannerAdded ], events.map(&:class)
    assert_equal({ tenant_user_id: @editor.id, person_id: @editor.person_id, effective_on: @tenant.today.iso8601,
                   added_by_id: nil, already_held: true }, editor.data)
    assert_equal @planner.id, planner.data[:tenant_user_id]
    assert(events.all? { it.metadata[:acting_via] == "system" && it.metadata[:actor_id].nil? })
    assert_equal [ [ true, false ], [ false, true ], [ false, false ] ], [ @editor, @planner, @member ].map { flags(it) }
  end

  should "give one run's events in a tenant one correlation, so the feed shows them as one change" do
    reconcile

    correlations = events.map { it.metadata[:correlation_id] }
    assert_predicate correlations.first, :present?
    assert_equal [ correlations.first ], correlations.uniq
  end

  should "write nothing when run again" do
    reconcile

    assert_match "[#{@tenant.id}] nothing to record", reconcile
    assert_equal 2, events.size
  end

  should "record a grant whose flag was cleared outside the events as removed, with no actor" do
    reconcile
    @editor.update_columns(org_graph_editor: false)

    assert_match "recorded 0 already held, 1 removed", reconcile
    assert_equal({ tenant_user_id: @editor.id, person_id: @editor.person_id, effective_on: @tenant.today.iso8601,
                   removed_by_id: nil }, events.last.data)
    assert_instance_of AccountGrants::Events::OrgGraphEditorRemoved, events.last
    assert_not holds?(:org_graph_editor, @editor)
  end

  should "record a grant whose account was destroyed as removed" do
    reconcile
    id, person_id = @planner.id, @planner.person_id
    as_tenant { @planner.destroy! }

    assert_match "recorded 0 already held, 1 removed", reconcile
    assert_equal({ tenant_user_id: id, person_id:, effective_on: @tenant.today.iso8601, removed_by_id: nil }, events.last.data)
  end

  should "leave a forgotten account's grant as it stands" do
    reconcile
    TenantUser.where(id: @editor.id).update_all(person_id: nil, user_id: nil, forgotten_at: Time.current)

    assert_match "nothing to record", reconcile
    assert holds?(:org_graph_editor, @editor)
  end

  should "keep the grant of someone who has left, as the flag does" do
    reconcile
    as_tenant { @editor.person.update!(status: "inactive") }

    assert_match "nothing to record", reconcile
    assert_equal [ true, false ], flags(@editor)
  end

  should "record a flagged account with no person, so a rebuild keeps its grant" do
    unlinked = as_tenant { create(:tenant_user, tenant: @tenant).tap { it.update_columns(org_graph_editor: true) } }

    assert_match "[#{@tenant.id}] recorded 3 already held, 0 removed", reconcile
    assert_equal({ tenant_user_id: unlinked.id, person_id: nil, effective_on: @tenant.today.iso8601,
                   added_by_id: nil, already_held: true }, events.find { it.data[:tenant_user_id] == unlinked.id }.data)

    run_task("events:projections:rebuild", PROJECTION::PROJECTION_NAME)

    assert_equal [ true, false ], flags(unlinked)
    assert_match "nothing to record", reconcile
  end

  should "record the other tenants, then fail so the deploy stops before a rebuild clears the failed tenant's flags" do
    other = create(:tenant)
    outsider = ActsAsTenant.with_tenant(other) do
      create(:tenant_user, tenant: other, person: create(:person, tenant: other)).tap { it.update_columns(team_planner: true) }
    end
    real = AccountGrants::Reconciliation.instance_method(:call)
    failing_id = @tenant.id
    AccountGrants::Reconciliation.define_method(:call) do
      @tenant.id == failing_id ? raise("stream unavailable") : real.bind_call(self)
    end

    error = assert_raises(SystemExit) { capture_io { Rake::Task["account_grants:reconcile"].invoke } }
    Rake::Task["account_grants:reconcile"].reenable

    assert_not error.success?
    assert_match @tenant.id, error.message
    assert_empty events
    assert_equal [ outsider.id ], events(other).map { it.data[:tenant_user_id] }
  ensure
    AccountGrants::Reconciliation.define_method(:call, real)
  end

  context "a deploy of the never-stamped projection" do
    setup do
      (Projections::Registry.classes - [ PROJECTION ]).each { ProjectionVersion.stamp!(it) }
      ProjectionVersion.where(name: PROJECTION::PROJECTION_NAME).delete_all
      reconcile
    end

    should "keep the flags and fail verify when the rebuild variable is missing" do
      run_task("events:projections:stamp_if_no_events")

      assert_nil ProjectionVersion.find_by(name: PROJECTION::PROJECTION_NAME)
      assert_equal [ [ true, false ], [ false, true ] ], [ @editor, @planner ].map { flags(it) }
      assert_raises(SystemExit) { capture_io { Rake::Task["events:projections:verify"].invoke } }
    end

    should "give the flags back from the events when rebuilt, then pass verify" do
      run_task("events:projections:rebuild_if_stale", PROJECTION::PROJECTION_NAME)
      run_task("events:projections:stamp_if_no_events")

      assert_equal PROJECTION::CODE_VERSION, ProjectionVersion.find_by(name: PROJECTION::PROJECTION_NAME).version
      assert_equal [ [ true, false ], [ false, true ], [ false, false ] ], [ @editor, @planner, @member ].map { flags(it) }
      assert_match "OK", run_task("events:projections:verify")
    end
  end
end
