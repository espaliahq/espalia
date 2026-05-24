# frozen_string_literal: true

require "test_helper"

# Snapshot of the MCP tool surface. Fails on any unintentional change —
# add/remove an Operation, rename one, change its category/approval/
# parameters — so the diff lands in code review next to whatever caused
# it. Intentional changes update `expected_snapshot` in the same PR.
#
# This is the load-bearing parity check: if a controller gets ported to
# an Operation, a new tool appears here; if an Operation is added but
# nobody asks for it from the web, this is the place it's noticed.
class Mcp::ToolRegistrySnapshotTest < ActiveSupport::TestCase
  should "match the committed snapshot of every Operation exposed as an MCP tool" do
    actual = Operations::Registry.all
      .sort_by(&:name)
      .map { |op| Mcp::OperationToTool.call(op) }
      .map { |tool| tool.deep_stringify_keys }

    assert_equal expected_snapshot, actual, <<~MSG
      The MCP tool surface diverged from the committed snapshot.

      If this was intentional (you added/removed/renamed an Operation,
      or changed its category/approval/parameters), update the
      `expected_snapshot` method in this file to match. If it wasn't —
      reverse whatever introduced the unintended Operation.

      Diff:
        actual (#{actual.size} tools):
      #{JSON.pretty_generate(actual).indent(2)}
    MSG
  end

  private

  # Hand-maintained source of truth. Every addition/removal here is one
  # line of intent in the PR.
  def expected_snapshot
    [
      {
        "name" => "assessments_align",
        "description" => "Record the aligned (agreed) frequency for one capability × level.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "frequency"            => { "type" => "string", "enum" => %w[none some occasional consistent] },
            "comment"              => { "type" => "string" }
          },
          "required" => %w[assignment_id capability_stable_id level_ordinal frequency],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "assessments_capability_get",
        "description" => "Fetch one capability's detail plus the assessee's per-level ratings (self/manager/aligned).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id" => { "type" => "string" },
            "capability_id" => { "type" => "string" }
          },
          "required" => %w[assignment_id capability_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true
        }
      },
      {
        "name" => "assessments_get",
        "description" => "Fetch one assessment's framework structure and the assessee's current role/level/cycle status.",
        "inputSchema" => {
          "type" => "object",
          "properties" => { "assignment_id" => { "type" => "string" } },
          "required" => [ "assignment_id" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true
        }
      },
      {
        "name" => "assessments_mine",
        "description" => "List the caller's own assessment assignments and those of their direct reports.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {},
          "required" => [],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true
        }
      },
      {
        "name" => "assessments_rate_as_manager",
        "description" => "Record or update a manager rating for one of your direct reports' capability × level.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "frequency"            => { "type" => "string", "enum" => %w[none some occasional consistent] },
            "comment"              => { "type" => "string" },
            "rationale"            => { "type" => "string" }
          },
          "required" => %w[assignment_id capability_stable_id level_ordinal frequency],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "assessments_rate_self",
        "description" => "Record or update your own rating for one capability × level.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "frequency"            => { "type" => "string", "enum" => %w[none some occasional consistent] },
            "comment"              => { "type" => "string" },
            "rationale"            => { "type" => "string" }
          },
          "required" => %w[assignment_id capability_stable_id level_ordinal frequency],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "frameworks_capability_get",
        "description" => "Fetch one capability's full detail: bindings, expectations per level, illustrations.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "capability_id" => { "type" => "string" }
          },
          "required" => %w[framework_id capability_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true
        }
      },
      {
        "name" => "frameworks_get",
        "description" => "Fetch one framework's top-level structure (role families, categories, child IDs and names).",
        "inputSchema" => {
          "type" => "object",
          "properties" => { "framework_id" => { "type" => "string" } },
          "required" => [ "framework_id" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true
        }
      },
      {
        "name" => "frameworks_list",
        "description" => "List frameworks visible to the caller in the active tenant.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {},
          "required" => [],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true
        }
      },
      {
        "name" => "system_whoami",
        "description" => "Identify the user, tenant, and person the MCP token resolves to.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {},
          "required" => [],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true
        }
      }
    ]
  end
end
