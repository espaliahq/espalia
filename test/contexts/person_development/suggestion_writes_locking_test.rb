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

  private

  # The lock an erase takes on the row, asked for from a session of its own.
  def erase_can_lock?
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    connection = PG.connect(**config.slice(:host, :port, :password).compact, user: config[:username], dbname: config[:database])
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
