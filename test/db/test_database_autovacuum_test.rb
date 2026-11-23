# frozen_string_literal: true

require "test_helper"

class TestDatabaseAutovacuumTest < ActiveSupport::TestCase
  should "leave no table of the test database for autovacuum to visit" do
    assert_empty TestDatabaseAutovacuum.tables_still_on
  end

  should "turn it off on a table that has it on" do
    ActiveRecord::Base.connection.execute("ALTER TABLE tenants RESET (autovacuum_enabled)")
    assert_equal [ "tenants" ], TestDatabaseAutovacuum.tables_still_on

    TestDatabaseAutovacuum.turn_off

    assert_empty TestDatabaseAutovacuum.tables_still_on
  end

  should "cancel a statement that runs too long" do
    assert_equal "2min", ActiveRecord::Base.connection.select_value("SHOW statement_timeout")
  end
end
