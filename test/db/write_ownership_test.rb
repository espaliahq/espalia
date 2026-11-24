# frozen_string_literal: true

require "test_helper"
require_relative "../support/write_catalogue_report"
require_relative "../support/write_ownership"

class WriteOwnershipTest < ActiveSupport::TestCase
  def projections = Projections::Registry::REPLAYABLE.keys

  def schema
    connection = ActiveRecord::Base.connection
    connection.tables.index_with { |table| connection.columns(table).map(&:name) }
  end

  def write(table, op: "update", columns: [], updates: [], projection: nil, site: nil)
    { table:, op:, columns:, updates:, projection:, site:, count: 1 }.stringify_keys
  end

  def violations(data, *writes) = WriteOwnership.new(data).violations(WriteCatalogueReport.new(writes))

  should "declare every table, each with an owner, a known projection and files that exist" do
    problems = WriteOwnership.load.declaration_problems(tables: schema, projections:)

    assert_empty problems, problems.join("\n")
  end

  should "name a table nobody declared, and an entry with no table" do
    problems = WriteOwnership.new("users" => { "owner" => "plain", "reason" => "Devise." })
                             .declaration_problems(tables: { "users" => [], "people" => [], "schema_migrations" => [] },
                                                   projections:)

    assert_equal [ "people: no entry. Say who writes it in write_ownership.yml." ], problems

    problems = WriteOwnership.new("gone" => { "owner" => "plain", "reason" => "r" }).declaration_problems(tables: {}, projections:)
    assert_equal [ "gone: no such table. Remove its entry." ], problems
  end

  should "name a table declared twice, which YAML would fold into one entry" do
    file = Tempfile.new([ "write_ownership", ".yml" ])
    file.write("users:\n  owner: plain\n  reason: Devise.\nusers:\n  owner: plain\n  reason: Again.\n")
    file.close

    problems = WriteOwnership.load(file.path).declaration_problems(tables: { "users" => [] }, projections:)

    assert_equal [ "users: declared twice. Merge its entries." ], problems
  ensure
    file&.unlink
  end

  should "refuse an entry with no reason, an unknown owner or column, or a writer that is no file of ours" do
    data = {
      "a" => { "owner" => "plain" },
      "b" => { "owner" => "frameworks/nope" },
      "c" => { "owner" => "plain", "reason" => "r", "writers" => [ "app/nowhere.rb", "test/test_helper.rb" ] },
      "d" => { "owner" => "event_store", "columns" => [ "x" ] },
      "e" => { "owner" => "plain", "reason" => "r", "writer" => [] },
      "f" => { "owner" => "org_graph/people_columns", "columns" => %w[manger_id], "reason" => "r" },
      "g" => { "owner" => "plain", "reason" => "r", "column_writers" => [ "app/models/person.rb" ] }
    }
    tables = data.keys.index_with { %w[x manager_id] }

    problems = WriteOwnership.new(data).declaration_problems(tables:, projections:)

    assert_equal [
      "a: say in reason why it is plain, or why the writers write it",
      "b: owner frameworks/nope is no projection",
      "c: writer app/nowhere.rb is no file",
      "c: writer test/test_helper.rb is outside app/ and lib/",
      "d: only a projection owns columns",
      "d: say in reason why it is plain, or why the writers write it",
      "e: unknown key writer",
      "f: no column manger_id",
      "g: column_writers need the columns a projection owns"
    ], problems
  end

  context "checking a run's writes" do
    setup do
      @data = {
        "users" => { "owner" => "plain", "reason" => "Devise.", "writers" => [ "app/models/user.rb" ] },
        "org_units" => { "owner" => "org_graph/structure" },
        "people" => { "owner" => "org_graph/people_columns", "columns" => %w[manager_id], "reason" => "Identifiers.",
                      "writers" => [ "app/models/person.rb", "app/models/tenant_user.rb" ],
                      "column_writers" => [ "app/models/tenant_user.rb" ] }
      }
    end

    should "allow a named writer, a test's own writes, even to its own table, and the owner's" do
      assert_empty violations(@data,
                              write("users", site: "app/models/user.rb:3 save"),
                              write("users", site: nil),
                              write("a_table_the_test_made", op: "insert", site: nil),
                              write("org_units", op: "insert", projection: "org_graph/structure"),
                              write("people", columns: %w[manager_id updated_at], projection: "org_graph/people_columns"),
                              write("people", op: "insert", columns: %w[name manager_id], site: "app/models/person.rb:9 ensure"),
                              write("people", columns: %w[name], site: "app/models/person.rb:12 rename"),
                              write("people", columns: %w[manager_id], site: "app/models/tenant_user.rb:4 link"))
    end

    should "name a writer the declaration doesn't, a projection that writes another's table, and a column it doesn't own" do
      found = violations(@data,
                         write("users", site: "app/controllers/x_controller.rb:4 update"),
                         write("users", op: "delete", site: "app/controllers/x_controller.rb:9 destroy"),
                         write("org_units", op: "delete", projection: "org_graph/members"),
                         write("people", op: "delete", projection: "org_graph/people_columns"),
                         write("people", columns: %w[name], projection: "org_graph/people_columns"),
                         write("people", op: "upsert", columns: %w[manager_id status], updates: %w[manager_id],
                                         projection: "org_graph/people_columns"),
                         write("people", columns: %w[manager_id], site: "app/integrations/hibob.rb:7 save"),
                         write("people", op: "upsert", columns: %w[manager_id name], updates: %w[manager_id],
                                         site: "app/models/person.rb:20 sync"),
                         write("budget_lines", site: "app/models/budget_line.rb:1 save"))

      assert_equal [
        [ "budget_lines", "no entry for the table" ],
        [ "org_units", "written inside org_graph/members, which doesn't own it" ],
        [ "people", "org_graph/people_columns deletes rows, though it owns only some columns" ],
        [ "people", "org_graph/people_columns writes name, which it isn't declared to own" ],
        [ "people", "org_graph/people_columns writes status, which it isn't declared to own" ],
        [ "people", "app/integrations/hibob.rb writes it, and isn't one of its writers" ],
        [ "people", "app/models/person.rb writes manager_id, which org_graph/people_columns owns" ],
        [ "users", "app/controllers/x_controller.rb writes it, and isn't one of its writers" ]
      ], found.map { [ it[:table], it[:reason] ] }
    end
  end
end
