# frozen_string_literal: true

require "test_helper"
require_relative "../support/write_catalogue_report"
require_relative "../support/write_ownership"

class WriteOwnershipTest < ActiveSupport::TestCase
  def projections = Projections::Registry::REPLAYABLE.keys

  def write(table, op: "update", columns: [], updates: [], projection: nil, site: nil)
    { table:, op:, columns:, updates:, projection:, site:, count: 1 }.stringify_keys
  end

  def violations(data, *writes) = WriteOwnership.new(data).violations(WriteCatalogueReport.new(writes))

  should "declare every table, each with an owner, a known projection and files that exist" do
    problems = WriteOwnership.load.declaration_problems(tables: ActiveRecord::Base.connection.tables, projections:)

    assert_empty problems, problems.join("\n")
  end

  should "name a table nobody declared, and an entry with no table" do
    problems = WriteOwnership.new("users" => { "owner" => "plain", "reason" => "Devise." })
                             .declaration_problems(tables: %w[users people schema_migrations], projections:)

    assert_equal [ "people: no entry. Say who writes it in write_ownership.yml." ], problems

    problems = WriteOwnership.new("gone" => { "owner" => "plain", "reason" => "r" }).declaration_problems(tables: [], projections:)
    assert_equal [ "gone: no such table. Remove its entry." ], problems
  end

  should "refuse an entry with no reason, an unknown owner, or a writer that is no file" do
    data = {
      "a" => { "owner" => "plain" },
      "b" => { "owner" => "frameworks/nope" },
      "c" => { "owner" => "plain", "reason" => "r", "writers" => [ "app/nowhere.rb" ] },
      "d" => { "owner" => "event_store", "columns" => [ "x" ] },
      "e" => { "owner" => "plain", "reason" => "r", "writer" => [] }
    }

    problems = WriteOwnership.new(data).declaration_problems(tables: data.keys, projections:)

    assert_equal [
      "a: say in reason why it is plain, or why the writers write it",
      "b: owner frameworks/nope is no projection",
      "c: writer app/nowhere.rb is no file",
      "d: only a projection owns columns",
      "d: say in reason why it is plain, or why the writers write it",
      "e: unknown key writer"
    ], problems
  end

  context "checking a run's writes" do
    setup do
      @data = {
        "users" => { "owner" => "plain", "reason" => "Devise.", "writers" => [ "app/models/user.rb" ] },
        "org_units" => { "owner" => "org_graph/structure" },
        "people" => { "owner" => "org_graph/people_columns", "columns" => %w[manager_id], "reason" => "Identifiers.",
                      "writers" => [ "app/models/person.rb" ] }
      }
    end

    should "allow a named writer, a test's own writes, even to its own table, and the owner's" do
      assert_empty violations(@data,
                              write("users", site: "app/models/user.rb:3 save"),
                              write("users", site: nil),
                              write("a_table_the_test_made", op: "insert", site: nil),
                              write("org_units", op: "insert", projection: "org_graph/structure"),
                              write("people", columns: %w[manager_id updated_at], projection: "org_graph/people_columns"),
                              write("people", op: "insert", columns: %w[name], site: "app/models/person.rb:9 ensure"))
    end

    should "name a writer the declaration doesn't, a projection that writes another's table, and a column it doesn't own" do
      found = violations(@data,
                         write("users", site: "app/controllers/x_controller.rb:4 update"),
                         write("org_units", op: "delete", projection: "org_graph/members"),
                         write("people", columns: %w[name], projection: "org_graph/people_columns"),
                         write("people", columns: %w[manager_id], site: "app/integrations/hibob.rb:7 save"),
                         write("budget_lines", site: "app/models/budget_line.rb:1 save"))

      assert_equal [
        [ "budget_lines", "no entry for the table" ],
        [ "org_units", "written inside org_graph/members, which doesn't own it" ],
        [ "people", "org_graph/people_columns writes name, which it isn't declared to own" ],
        [ "people", "app/integrations/hibob.rb writes it, and isn't one of its writers" ],
        [ "users", "app/controllers/x_controller.rb writes it, and isn't one of its writers" ]
      ], found.map { [ it[:table], it[:reason] ] }
    end
  end
end
