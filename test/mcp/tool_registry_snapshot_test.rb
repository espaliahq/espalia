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
        "name" => "assessments_add_evidence_link",
        "description" => "Link an existing evidence item to an additional capability × level.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "evidence_id"          => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "rationale"            => { "type" => "string" }
          },
          "required" => %w[assignment_id evidence_id capability_stable_id level_ordinal],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
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
        "description" => "Fetch one capability's detail plus the assessee's per-level ratings (self/manager/aligned). Accepts either capability_id (version-specific) or stable_id (cross-version) in the capability_id argument.",
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
        "name" => "assessments_comments_list",
        "description" => "List active comment threads on an assessment for one capability (optionally one level). " \
                         "Accepts either capability_id (version-specific) or stable_id (cross-version) in the " \
                         "capability_stable_id argument. Top-level comments carry their replies nested.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" }
          },
          "required" => %w[assignment_id capability_stable_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => true,
          "destructiveHint" => false,
          "idempotentHint"  => true
        }
      },
      {
        "name" => "assessments_delegate_manager_rating",
        "description" => "Delegate manager-rating authority for one of your reports to another person.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"      => { "type" => "string" },
            "delegate_person_id" => { "type" => "string" },
            "expires_at"         => { "type" => "string" },
            "reason"             => { "type" => "string" }
          },
          "required" => %w[assignment_id delegate_person_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "assessments_delete_comment",
        "description" => "Delete a comment on an assessment (soft delete — preserves reply chains; author or tenant admin).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id" => { "type" => "string" },
            "comment_id"    => { "type" => "string" },
            "reason"        => { "type" => "string" }
          },
          "required" => %w[assignment_id comment_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "assessments_edit_comment",
        "description" => "Edit the body of one of your own comments on an assessment.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id" => { "type" => "string" },
            "comment_id"    => { "type" => "string" },
            "body"          => { "type" => "string" }
          },
          "required" => %w[assignment_id comment_id body],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "assessments_evidence_list",
        "description" => "List active evidence on an assessment for one capability (optionally one level). " \
                         "Accepts either capability_id (version-specific) or stable_id (cross-version) in " \
                         "the capability_stable_id argument. Each item carries its full set of linked cells.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" }
          },
          "required" => %w[assignment_id capability_stable_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => true,
          "destructiveHint" => false,
          "idempotentHint"  => true
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
        "name" => "assessments_post_comment",
        "description" => "Post a comment on a capability × level of an assessment (optionally as a reply).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "body"                 => { "type" => "string" },
            "parent_id"            => { "type" => "string" }
          },
          "required" => %w[assignment_id capability_stable_id level_ordinal body],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
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
        "name" => "assessments_recent_activity",
        "description" => "Recent assessment activity for the caller — their own as an IC, or their direct " \
          "reports' as a manager: ratings, evidence, comments, and alignment milestones " \
          "(metadata only, no rating values), most-recent first.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "limit" => { "type" => "integer" }
          },
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
        "name" => "assessments_record_evidence",
        "description" => "Record a piece of evidence against a capability × level on an assessment.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "evidence_type"        => { "type" => "string", "enum" => EvidenceItem::EVIDENCE_TYPES },
            "custom_type_label"    => { "type" => "string" },
            "title"                => { "type" => "string" },
            "content"              => { "type" => "string" },
            "external_reference"   => { "type" => "object" },
            "additional_links"     => { "type" => "array" }
          },
          "required" => %w[assignment_id capability_stable_id level_ordinal evidence_type content],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "assessments_remove_evidence_link",
        "description" => "Remove one capability × level link from an evidence item (it keeps its other links).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "evidence_id"          => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "reason"               => { "type" => "string" }
          },
          "required" => %w[assignment_id evidence_id capability_stable_id level_ordinal],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "assessments_revoke_manager_rating_delegation",
        "description" => "Revoke a manager-rating delegation for one of your reports.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"      => { "type" => "string" },
            "delegate_person_id" => { "type" => "string" }
          },
          "required" => %w[assignment_id delegate_person_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "assessments_update_evidence",
        "description" => "Edit an existing evidence item's type, title, content, and external reference.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"     => { "type" => "string" },
            "evidence_id"       => { "type" => "string" },
            "evidence_type"     => { "type" => "string", "enum" => EvidenceItem::EVIDENCE_TYPES },
            "custom_type_label" => { "type" => "string" },
            "title"             => { "type" => "string" },
            "content"           => { "type" => "string" },
            "external_reference" => { "type" => "object" }
          },
          "required" => %w[assignment_id evidence_id evidence_type content],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "assessments_withdraw_evidence",
        "description" => "Withdraw an evidence item (soft delete — hides it everywhere, preserves history).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id" => { "type" => "string" },
            "evidence_id"   => { "type" => "string" },
            "reason"        => { "type" => "string" }
          },
          "required" => %w[assignment_id evidence_id],
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
        "description" => "Fetch one capability's full detail: bindings, expectations per level, illustrations. Accepts either capability_id (version-specific) or stable_id (cross-version) in the capability_id argument.",
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
        "name" => "reporting_cycle_cohort",
        "description" => "Aggregate progress for an assessment cycle across the caller's org subtree " \
          "(admins see the whole cycle): the self/manager/aligned funnel, lifecycle status " \
          "counts, at-risk count, and — in full mode — grouped breakdowns and per-participant " \
          "progress. Returns no rating values.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "cycle_id" => { "type" => "string" },
            "mode" => { "type" => "string", "enum" => [ "summary", "full" ] },
            "scope" => { "type" => "string", "enum" => [ "mine", "all" ] }
          },
          "required" => [ "cycle_id" ],
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
      },
      {
        "name" => "tenants_update_theme",
        "description" => "Update the active tenant's theme (brand colors and font).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "primary_color"        => { "type" => "string" },
            "primary_color_dark"   => { "type" => "string" },
            "secondary_color"      => { "type" => "string" },
            "secondary_color_dark" => { "type" => "string" },
            "nav_bg_color"         => { "type" => "string" },
            "nav_bg_color_dark"    => { "type" => "string" },
            "nav_fg_color"         => { "type" => "string" },
            "nav_fg_color_dark"    => { "type" => "string" },
            "font_family"          => { "type" => "string" }
          },
          "required" => [],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      }
    ]
  end
end
