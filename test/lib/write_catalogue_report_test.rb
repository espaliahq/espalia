# frozen_string_literal: true

require "test_helper"
require_relative "../support/write_catalogue_report"

class WriteCatalogueReportTest < ActiveSupport::TestCase
  def write(table, op, columns: [], projection: nil, site: "app/models/x.rb:1 save")
    { "table" => table, "op" => op, "columns" => columns, "projection" => projection, "site" => site, "count" => 1 }
  end

  def findings(*rows) = WriteCatalogueReport.new(rows).findings.map { it.slice(:table, :site, :reason) }

  should "report a row written outside the projection that owns the table's rows" do
    rows = [ write("evidence_items", "insert", projection: "pd/evidence", site: nil),
             write("evidence_items", "update", columns: %w[status]) ]

    assert_equal [ { table: "evidence_items", site: "app/models/x.rb:1 save",
                     reason: "update on a table pd/evidence writes" } ], findings(*rows)
  end

  should "report an update to an owned column, and not an update to another column" do
    rows = [ write("people", "update", columns: %w[manager_id], projection: "org/people", site: nil),
             write("people", "update", columns: %w[manager_id updated_at], site: "a.rb:1 x"),
             write("people", "update", columns: %w[name updated_at], site: "b.rb:2 y") ]

    assert_equal [ { table: "people", site: "a.rb:1 x", reason: "updates manager_id, which org/people writes" } ],
                 findings(*rows)
  end

  should "report a table two projections write once, and not blame either for its own writes" do
    rows = [ write("t", "upsert", projection: "a", site: "app/a.rb:1 call"),
             write("t", "upsert", projection: "b", site: "app/b.rb:1 call") ]

    assert_equal [ { table: "t", site: nil, reason: "written by a and b" } ], findings(*rows)
  end

  should "merge the same write from several workers into one count" do
    rows = [ write("budget_lines", "delete"), write("budget_lines", "delete") ]

    assert_equal [ 2 ], WriteCatalogueReport.new(rows).plain_tables["budget_lines"].map(&:count)
  end
end
