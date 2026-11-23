# frozen_string_literal: true

# Turns autovacuum off on every table of a test database. A vacuum that runs
# during a test's transaction does not count its uncommitted rows, so it
# records the tables the test has filled as empty, and the planner then nests
# loops over thousands of rows (#546).
module TestDatabaseAutovacuum
  STILL_ON = <<~SQL
    SELECT c.oid::regclass::text FROM pg_class c
    WHERE c.relkind = 'r' AND c.relnamespace = 'public'::regnamespace
      AND NOT coalesce(c.reloptions @> ARRAY['autovacuum_enabled=false'], false)
    ORDER BY 1
  SQL

  # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
  # @return [Array<String>] the tables autovacuum would still visit
  def self.tables_still_on(connection = ActiveRecord::Base.connection)
    connection.select_values(STILL_ON)
  end

  # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
  # @return [void]
  def self.turn_off(connection = ActiveRecord::Base.connection)
    tables_still_on(connection).each do |table|
      connection.execute("ALTER TABLE #{table} SET (autovacuum_enabled = false)")
    end
  end
end
