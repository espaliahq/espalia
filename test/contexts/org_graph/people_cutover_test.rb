# frozen_string_literal: true

require "test_helper"

class OrgGraph::PeopleCutoverTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    as_tenant do
      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        .claim_facts(OrgGraph::StructureAggregate::HRIS_FACTS, "hibob", effective_on: "2026-11-01")
      @lead = create(:person, tenant: @tenant, job_title: "Lead", external_id: "bob-1", hris_source: "hibob")
      @synced = create(:person, tenant: @tenant, job_title: "Engineer", manager: @lead, external_id: "bob-2", hris_source: "hibob")
      @by_hand = create(:person, tenant: @tenant, job_title: "Contractor", status: "inactive")
      [ @lead, @synced ].each do |person|
        @handler.record_person(person.id, provider: "hibob", effective_on: "2026-11-01", employment_status: "employed",
                                          title: person.job_title, manager_id: person.manager_id)
      end
    end
    @cutover = OrgGraph::PeopleCutover.new(@tenant)
  end

  context "a dry run" do
    should "report who it would record and keep nothing" do
      report = @cutover.run(apply: false)

      assert_equal [ @by_hand.id ], report.recorded
      assert_empty report.differences
      assert_not report.applied
      assert_not @tenant.reload.org_graph_people_projected?
      assert_empty stream(@by_hand)
    end
  end

  context "a clean cut-over" do
    setup { @report = @cutover.run(apply: true) }

    should "hand the columns to the streams, leaving every row as it was" do
      assert @report.applied
      assert @tenant.reload.org_graph_people_projected?
      as_tenant do
        assert_equal [ "Engineer", @lead.id, "active" ], @synced.reload.slice(:job_title, :manager_id, :status).values
        assert_equal [ "Contractor", nil, "inactive" ], @by_hand.reload.slice(:job_title, :manager_id, :status).values
      end
    end

    should "record someone with no HRIS id as Espalia's, from their row" do
      recorded = stream(@by_hand).sole

      assert_kind_of OrgGraph::Events::PersonRecorded, recorded
      assert_equal [ "espalia", "left", "Contractor" ], recorded.data.values_at(:provider, :employment_status, :title)
      assert_equal "system", recorded.metadata[:acting_via]
    end

    should "refuse a second cut-over" do
      assert_raises(ArgumentError) { @cutover.run(apply: true) }
    end

    should "revert with no data step" do
      @cutover.revert!

      assert_not @tenant.reload.org_graph_people_projected?
      as_tenant { assert_equal "Engineer", @synced.reload.job_title }
    end
  end

  should "record a person who carries an HRIS id as that provider's" do
    as_tenant { @by_hand.update!(external_id: "bob-3", hris_source: "hibob") }

    @cutover.run(apply: true)

    assert_equal "hibob", stream(@by_hand).sole.data[:provider]
  end

  should "record a person whose HRIS does not hold their facts as Espalia's" do
    as_tenant do
      @by_hand.update!(external_id: "bob-3", hris_source: "hibob")
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      OrgGraph::PeopleCutover::RECORDED_FACTS.each { structure.set_fact_provider(it, "espalia", effective_on: "2026-11-01") }
    end

    assert @cutover.run(apply: true).applied

    assert_equal "espalia", stream(@by_hand).sole.data[:provider]
  end

  context "a row the stream disagrees with" do
    setup { as_tenant { @synced.update_columns(job_title: "Staff engineer") } }

    should "name the person and column and keep nothing" do
      report = @cutover.run(apply: true)

      assert_equal({ "job_title" => [ @synced.id ] }, report.differences)
      assert_not report.applied
      assert_not @tenant.reload.org_graph_people_projected?
      as_tenant { assert_equal "Staff engineer", @synced.reload.job_title }
    end

    should "take the stream's value when the operator accepts it" do
      assert @cutover.run(apply: true, accept_stream: true).applied

      as_tenant { assert_equal "Engineer", @synced.reload.job_title }
    end
  end

  should "record a person who manages themself with no manager, and report the difference" do
    as_tenant { @by_hand.update_columns(manager_id: @by_hand.id) }

    report = @cutover.run(apply: true)

    assert_equal({ "manager_id" => [ @by_hand.id ] }, report.differences)
    assert_empty report.failed
  end

  should "keep nothing when someone cannot be recorded" do
    failing = Object.new
    def failing.record_person(*, **) = raise("recording failed")

    report = OrgGraph::CommandHandler.stub(:new, failing) { @cutover.run(apply: true) }

    assert_equal({ @by_hand.id => "recording failed" }, report.failed)
    assert_not report.applied
    assert_not @tenant.reload.org_graph_people_projected?
  end

  should "report a database error on one person and still finish the run" do
    as_tenant { @second_by_hand = create(:person, tenant: @tenant) }
    failing_id = [ @by_hand.id, @second_by_hand.id ].min
    real = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    flaky = Object.new
    flaky.define_singleton_method(:record_person) do |id, **facts|
      ActiveRecord::Base.connection.execute("SELECT 1/0") if id == failing_id
      real.record_person(id, **facts)
    end

    report = OrgGraph::CommandHandler.stub(:new, flaky) { @cutover.run(apply: false) }

    assert_equal [ failing_id ], report.failed.keys
    assert_match(/division by zero/, report.failed[failing_id])
    assert_equal [ ([ @by_hand.id, @second_by_hand.id ] - [ failing_id ]).sole ], report.recorded
  end

  should "wait for a running sync, then cut over once it ends" do
    syncing = held_off_on_another_connection

    error = assert_raises(RuntimeError) { @cutover.run(apply: true) }
    assert_match(/sync is running/, error.message)
    assert_raises(RuntimeError) { @cutover.revert! }

    release(syncing)
    assert @cutover.run(apply: true).applied
  end

  private

  # The lock a sync holds, from a session outside the test's transaction.
  def held_off_on_another_connection
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    connection = PG.connect(**config.slice(:host, :port, :password).compact, user: config[:username], dbname: config[:database])
    connection.exec_params("SELECT pg_advisory_lock_shared($1)", [ OrgGraph::PeopleCutover.lock_key(@tenant) ])
    connection
  end

  # Closing alone returns before the server ends the session and frees its lock.
  def release(connection)
    connection.exec_params("SELECT pg_advisory_unlock_shared($1)", [ OrgGraph::PeopleCutover.lock_key(@tenant) ])
    connection.close
  end

  def as_tenant(&block)
    ActsAsTenant.with_tenant(@tenant, &block)
  end

  def stream(person)
    Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(person.id, tenant: @tenant)).to_a
  end
end
