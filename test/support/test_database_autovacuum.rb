# frozen_string_literal: true

# Turns autovacuum off on every table of a test database. A vacuum that runs
# during a test's transaction does not count its uncommitted rows, so it
# records the tables the test has filled as empty, and the planner then nests
# loops over thousands of rows
# (https://github.com/espaliahq/espalia/issues/546).
module TestDatabaseAutovacuum
  STILL_ON = <<~SQL
    SELECT c.oid::regclass::text FROM pg_class c
    WHERE c.relkind = 'r' AND c.relnamespace = 'public'::regnamespace
      AND NOT coalesce(c.reloptions @> ARRAY['autovacuum_enabled=false'], false)
    ORDER BY 1
  SQL

  # A DATABASE_URL names a database this run was lent: a second worktree runs
  # its dev server on the one its tests use.
  #
  # @return [Boolean]
  def self.borrowed_database?
    ENV.key?("DATABASE_URL")
  end

  # @return [Array<String>] the tables autovacuum would still visit
  def self.tables_still_on
    ActiveRecord::Base.connection.select_values(STILL_ON)
  end

  # @return [void]
  def self.turn_off
    return if borrowed_database? || !Rails.env.test?

    tables_still_on.each do |table|
      ActiveRecord::Base.connection.execute("ALTER TABLE #{table} SET (autovacuum_enabled = false)")
    end
  end
end
