# frozen_string_literal: true

require "test_helper"

# The person's row must be committed for another session to lock it.
class PersonDevelopment::ForgottenSubjectLockingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  # Stands in for the stream, so the test can see what is locked when it opens.
  class StreamProbe
    attr_reader :opened

    def initialize(&on_open)
      @on_open = on_open
      @opened = []
    end

    def with_person_development(person_id, framework_id)
      @opened << @on_open.call
    end
  end

  LINK_COMMANDS = {
    add_evidence_link: { capability_stable_id: "cap", level_ordinal: 2, linked_by_id: "someone", valence: "demonstrated" },
    set_evidence_link_valence: { capability_stable_id: "cap", level_ordinal: 2, valence: "growth_area", changed_by_id: "someone" },
    remove_evidence_link: { capability_stable_id: "cap", level_ordinal: 2, removed_by_id: "someone" }
  }.freeze

  setup do
    @tenant = create(:tenant)
    @person = create(:person, tenant: @tenant)
    @framework_id = SecureRandom.uuid_v7
  end

  teardown do
    Person.unscoped.where(id: @person.id).delete_all if @person
    @tenant&.delete
  end

  should "hold the person's row before each link command opens the stream" do
    probe = StreamProbe.new { erase_can_lock? }
    handler = PersonDevelopment::CommandHandler.new(repository: probe)

    ActsAsTenant.with_tenant(@tenant) do
      LINK_COMMANDS.each { |command, args| handler.public_send(command, @person.id, @framework_id, "evidence", **args) }
    end

    assert_equal [ false, false, false ], probe.opened
    assert erase_can_lock?
  end

  should "refuse a link command that waited on an erase which then committed" do
    probe = StreamProbe.new { :opened }
    erase = erase_session
    erase.exec("BEGIN")
    erase.exec_params("SELECT 1 FROM people WHERE id = $1 FOR UPDATE", [ @person.id ])
    erase.exec_params("UPDATE people SET forgotten_at = now(), name = $2, email = NULL WHERE id = $1",
                      [ @person.id, Person::FORMER_MEMBER ])
    command = Thread.new { add_link(probe) }
    wait_until_waiting(command, behind: erase)
    erase.exec("COMMIT")

    assert_equal :refused, command.value
    assert_empty probe.opened
  ensure
    erase&.close
    command&.join(5)
  end

  private

  def add_link(probe)
    ActiveRecord::Base.connection_pool.with_connection do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new(repository: probe)
          .add_evidence_link(@person.id, @framework_id, "evidence", **LINK_COMMANDS[:add_evidence_link])
      end
    end
  rescue PersonDevelopment::ForgottenSubject::Forgotten
    :refused
  end

  def wait_until_waiting(command, behind:)
    erase_pid = behind.exec("SELECT pg_backend_pid()").getvalue(0, 0).to_i
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      flunk "the command finished without waiting: #{command.value.inspect}" unless command.alive?
      # Inside the erase's transaction pg_stat_activity is a snapshot taken at
      # the first read, so a command that connects later never shows without this.
      behind.exec("SELECT pg_stat_clear_snapshot()")
      return if behind.exec_params("SELECT 1 FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))", [ erase_pid ]).ntuples.positive?

      sleep 0.1
    end
    flunk "the command never waited on the erase (pid #{erase_pid})"
  end

  def erase_session
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(**config.slice(:host, :port, :password).compact, user: config[:username], dbname: config[:database])
  end

  # The lock an erase takes on the row, asked for from a session of its own.
  def erase_can_lock?
    connection = erase_session
    connection.exec("BEGIN")
    connection.exec_params("SELECT 1 FROM people WHERE id = $1 FOR UPDATE NOWAIT", [ @person.id ])
    true
  rescue PG::LockNotAvailable
    false
  ensure
    connection&.exec("ROLLBACK") rescue nil
    connection&.close
  end
end
