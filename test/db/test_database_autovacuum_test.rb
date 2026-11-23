# frozen_string_literal: true

require "test_helper"

class TestDatabaseAutovacuumTest < ActiveSupport::TestCase
  should "leave no table of the test database for autovacuum to visit" do
    assert_empty TestDatabaseAutovacuum.tables_still_on
  end
end
