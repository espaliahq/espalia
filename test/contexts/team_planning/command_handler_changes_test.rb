# frozen_string_literal: true

require "test_helper"

class TeamPlanning::CommandHandlerChangesTest < ActiveSupport::TestCase
  class TitleSet < TeamPlanning::Events::Change
    def self.facet = "title"
    def self.apply_to(map, _data) = map
  end

  class SiteSet < TeamPlanning::Events::Change
    def self.facet = "site"
    def self.apply_to(map, _data) = map
  end

  # Runs a block while a write is between loading the plan and storing it.
  class PausingRepository < TeamPlanning::Repository
    def initialize(during_write) = super().tap { @during_write = during_write }

    def with_plan(plan_id)
      super { |plan| yield(plan).tap { @during_write.call } }
    end
  end

  # Sets up without the lock: a transactional test holds a lock it takes until
  # the test ends, which would hide whether the write under test takes it.
  class UnlockedRepository < TeamPlanning::Repository
    private def lock_stream(_stream) = nil
  end

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @editor = context_for(create(:person, tenant: @tenant), role: :admin)
    @viewer = context_for(create(:person, tenant: @tenant))
    @plan_id = SecureRandom.uuid_v7
    unlocked = TeamPlanning::CommandHandler.new(actor: @editor, repository: UnlockedRepository.new)
    unlocked.create_plan(@plan_id, name: "Next year", base_on: "2027-01-01")
    unlocked.add_member(@plan_id, @viewer.person.id, role: "viewer")
    @q1 = SecureRandom.uuid_v7
    unlocked.fork_scenario(@plan_id, @q1, parent_id: @plan_id, relation: "then", name: "Q1", ends_on: "2027-03-31")
    @ada = SecureRandom.uuid_v7
  end

  teardown { ActsAsTenant.current_tenant = nil }

  should "store an editor's change in the plan's stream, naming who made it" do
    handler(@editor).set_change(@plan_id, TitleSet, scenario_id: @q1, subject_id: @ada, end_state: { title: "Senior Engineer" })

    event = event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).last
    assert_kind_of TitleSet, event
    assert_equal [ @editor.person.id, @tenant.id ], [ event.data[:set_by_id], event.metadata[:tenant_id] ]
  end

  should "read as missing to a viewer" do
    error = assert_raises(TeamPlanning::Error) do
      handler(@viewer).set_change(@plan_id, TitleSet, scenario_id: @q1, subject_id: @ada, end_state: { title: "Senior Engineer" })
    end
    assert_equal "No such plan", error.message
  end

  should "hold the plan's lock from load to store, so a second editor's change loads after the first lands" do
    assert try_lock_from_another_session, "nothing may hold the lock before the write"
    held = nil
    pausing = PausingRepository.new(-> { held = try_lock_from_another_session })
    TeamPlanning::CommandHandler.new(actor: @editor, repository: pausing)
      .set_change(@plan_id, TitleSet, scenario_id: @q1, subject_id: @ada, end_state: { title: "Senior Engineer" })
    handler(@editor).set_change(@plan_id, SiteSet, scenario_id: @q1, subject_id: @ada, end_state: { site: "York" })

    assert_equal false, held, "another session must wait while a change is stored"
    plan = TeamPlanning::Repository.new.load_plan(@plan_id)
    assert_equal [ TitleSet, SiteSet ], plan.changes_in(@q1).map(&:class)
  end

  private

  def handler(actor) = TeamPlanning::CommandHandler.new(actor:)

  def event_store = Rails.configuration.event_store

  # Transactional tests share one connection across threads, so a real second
  # session needs its own PG connection.
  def try_lock_from_another_session
    cfg = ActiveRecord::Base.connection_db_config.configuration_hash
    other = PG.connect({ dbname: cfg[:database], user: cfg[:username], password: cfg[:password],
                         host: cfg[:host], port: cfg[:port] }.compact)
    sql = "SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))"
    other.exec_params(sql, [ EventStreamNaming.plan_stream(@plan_id) ]).getvalue(0, 0) == "t"
  ensure
    other&.close
  end

  def context_for(person, role: :member)
    user = create(:user)
    tenant_user = create(:tenant_user, tenant: @tenant, user:, person:, role:)
    AuthorizationContext.new(user:, tenant_user:, person:)
  end
end
