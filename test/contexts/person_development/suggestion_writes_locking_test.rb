# frozen_string_literal: true

require "test_helper"

# The person's row must be committed for another session to lock it.
class PersonDevelopment::SuggestionWritesLockingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @tenant = create(:tenant)
    @person = create(:person, tenant: @tenant)
    @framework_id = SecureRandom.uuid_v7
  end

  teardown do
    Person.unscoped.where(id: @person.id).delete_all if @person
    @tenant&.delete
  end

  should "keep an erase off the person's row until the command commits" do
    during = nil
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::SuggestionWrites.with_aggregate(@person.id, @framework_id, evidence_ids: []) do
        during = erase_can_lock?
      end
    end

    assert_equal false, during
    assert erase_can_lock?
  end

  should "refuse a command that waited on an erase which then committed" do
    erase = erase_session
    erase.exec("BEGIN")
    erase.exec_params("SELECT 1 FROM people WHERE id = $1 FOR UPDATE", [ @person.id ])
    erase.exec_params("UPDATE people SET forgotten_at = now(), name = $2, email = NULL WHERE id = $1",
                      [ @person.id, Person::FORMER_MEMBER ])
    command = Thread.new { run_command }
    wait_until_waiting(command, behind: erase)
    erase.exec("COMMIT")

    assert_equal :refused, command.value
  ensure
    erase&.close
    command&.join(5)
  end

  private

  def run_command
    ActiveRecord::Base.connection_pool.with_connection do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::SuggestionWrites.with_aggregate(@person.id, @framework_id, evidence_ids: []) { :stored }
      end
    end
  rescue PersonDevelopment::SuggestionWrites::Forgotten
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
    behind.exec("SELECT pg_stat_clear_snapshot()")
    sessions = behind.exec("SELECT pid, state, wait_event_type, wait_event FROM pg_stat_activity WHERE datname = current_database()")
    flunk "the command never waited on the erase (pid #{erase_pid}): #{sessions.values.inspect}"
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
