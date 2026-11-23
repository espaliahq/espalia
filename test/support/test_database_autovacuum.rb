# frozen_string_literal: true

# Turns autovacuum, and with it autoanalyze, off on every table of a test
# database. Either one, run during a test's transaction, does not count its
# uncommitted rows, so it records the tables the test has filled as empty and
# the planner then nests loops over thousands of rows
# (https://github.com/espaliahq/espalia/issues/546).
module TestDatabaseAutovacuum
  STILL_ON = <<~SQL
    SELECT c.oid::regclass::text FROM pg_class c
    WHERE c.relkind = 'r' AND c.relnamespace = 'public'::regnamespace
      AND NOT coalesce(c.reloptions @> ARRAY['autovacuum_enabled=false'], false)
    ORDER BY 1
  SQL

  # @return [Array<String>] the tables autovacuum would still visit
  def self.tables_still_on
    ActiveRecord::Base.connection.select_values(STILL_ON)
  end

  # @return [void]
  def self.turn_off
    return unless Rails.env.test?

    tables_still_on.each do |table|
      ActiveRecord::Base.connection.execute("ALTER TABLE #{table} SET (autovacuum_enabled = false)")
    end
  end
end
