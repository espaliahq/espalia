# frozen_string_literal: true

require "test_helper"

# Snapshot of the MCP tool surface, one reviewed file per tool in
# test/mcp/tool_snapshots/. Fails on any unintentional change (an Operation
# added, removed or renamed, or its category, approval or parameters changed),
# so the diff lands in code review next to whatever caused it.
#
# This is the load-bearing parity check: if a controller gets ported to an
# Operation, a new file appears here; if an Operation is added but nobody asks
# for it from the web, this is the place it's noticed. One file per tool keeps
# parallel PRs that each add a tool from conflicting.
class Mcp::ToolRegistrySnapshotTest < ActiveSupport::TestCase
  DIR = Rails.root.join("test/mcp/tool_snapshots")

  UPDATE = <<~MSG
    If the change is intended, run
      UPDATE_SNAPSHOTS=1 bin/rails test test/mcp/tool_registry_snapshot_test.rb
    and commit the files it writes under test/mcp/tool_snapshots/ after reading their diff.
    (Before #218 each tool sat in this test's `expected_snapshot`; it now has its own file.)
  MSG

  setup { write_snapshots if ENV["UPDATE_SNAPSHOTS"] }

  should "keep a snapshot file for every Operation exposed as an MCP tool, and none for a tool that's gone" do
    assert_empty tools.keys - snapshots.keys, "These tools have no snapshot file.\n#{UPDATE}"
    assert_empty snapshots.keys - tools.keys, "These snapshot files name no tool.\n#{UPDATE}"
  end

  should "match each tool to its committed snapshot" do
    changed = tools.keys.intersection(snapshots.keys).reject { |name| tools[name] == snapshots[name] }

    assert_empty changed, <<~MSG
      These tools diverged from their snapshot:
      #{changed.map { |name| "  #{name}\n#{JSON.pretty_generate(tools[name]).indent(4)}" }.join("\n")}
      #{UPDATE}
    MSG
  end

  private

  def tools
    @tools ||= Operations::Registry.all
      .map { |op| JSON.parse(Mcp::OperationToTool.call(op).to_json) }
      .index_by { |tool| tool.fetch("name") }
  end

  def snapshots
    @snapshots ||= DIR.glob("*.json").to_h { |path| [ path.basename(".json").to_s, JSON.parse(path.read) ] }
  end

  def write_snapshots
    DIR.glob("*.json").each { |path| path.delete unless tools.key?(path.basename(".json").to_s) }
    tools.each { |name, tool| DIR.join("#{name}.json").write("#{JSON.pretty_generate(tool)}\n") }
    @snapshots = nil
  end
end
