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
        "description" => "Link an existing feedback / evidence item to an additional capability × level.",
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
        "name" => "assessments_cancel_evidence_request",
        "description" => "Cancel a pending feedback / evidence request you created.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "request_id" => { "type" => "string" }
          },
          "required" => %w[request_id],
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
        "name" => "assessments_decline_evidence_request",
        "description" => "Decline a pending feedback / evidence request.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "request_id" => { "type" => "string" },
            "reason"     => { "type" => "string" }
          },
          "required" => %w[request_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
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
        "description" => "List active feedback / evidence on an assessment for one capability (optionally one level). " \
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
        "name" => "assessments_evidence_requests_list",
        "description" => "List feedback / evidence requests addressed to you (incoming) and ones you've made (outgoing).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "status" => { "type" => "string", "enum" => %w[pending responded declined cancelled] }
          },
          "required" => [],
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
        "description" => "List the caller's own assessment assignments plus their direct reports' and skip-level reports' (view-only).",
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
        "description" => "Record a piece of feedback / evidence against a capability × level on an assessment.",
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
            "external_reference"   => external_reference_schema,
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
        "description" => "Remove one capability × level link from a feedback / evidence item (it keeps its other links).",
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
        "name" => "assessments_reopen_alignment",
        "description" =>
          "Re-open a completed alignment so the manager can correct it; agreed values are preserved.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id" => { "type" => "string" }
          },
          "required" => %w[assignment_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "assessments_request_evidence",
        "description" => "Ask a colleague to provide feedback / evidence for a capability × level on an assessment.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "requestee_person_id"  => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "message"              => { "type" => "string" },
            "due_at"               => { "type" => "string" }
          },
          "required" => %w[assignment_id requestee_person_id capability_stable_id level_ordinal],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "assessments_respond_to_evidence_request",
        "description" => "Respond to a feedback / evidence request by providing the requested feedback.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "request_id"         => { "type" => "string" },
            "evidence_type"      => { "type" => "string", "enum" => %w[peer_feedback project_outcome code_review design_review customer_feedback incident_response presentation mentoring observation other] },
            "content"            => { "type" => "string" },
            "custom_type_label"  => { "type" => "string" },
            "title"              => { "type" => "string" },
            "external_reference" => external_reference_schema
          },
          "required" => %w[request_id evidence_type content],
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
        "name" => "assessments_unassign",
        "description" => "Remove a person's framework assignment (when their real role no longer maps to a framework role).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id" => { "type" => "string" },
            "reason"        => { "type" => "string" }
          },
          "required" => %w[assignment_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => true,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "assessments_update_evidence",
        "description" => "Edit an existing feedback / evidence item's type, title, content, and external reference.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"     => { "type" => "string" },
            "evidence_id"       => { "type" => "string" },
            "evidence_type"     => { "type" => "string", "enum" => EvidenceItem::EVIDENCE_TYPES },
            "custom_type_label" => { "type" => "string" },
            "title"             => { "type" => "string" },
            "content"           => { "type" => "string" },
            "external_reference" => external_reference_schema
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
        "description" => "Withdraw a feedback / evidence item (soft delete — hides it everywhere, preserves history).",
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
        "name" => "frameworks_add_capability",
        "description" => "Add a capability to a category, binding it to one or more roles (owner/editor/lead only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "category_id" => { "type" => "string" },
            "name" => { "type" => "string" },
            "description" => { "type" => "string" },
            "role_ids" => { "type" => "array" }
          },
          "required" => %w[framework_id category_id name],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_add_capability_role_binding",
        "description" => "Bind a capability to a role, optionally with a weight / individual tolerance (owner/editor/lead only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id"         => { "type" => "string" },
            "capability_id"        => { "type" => "string" },
            "role_id"              => { "type" => "string" },
            "weight"               => { "type" => "number" },
            "individual_tolerance" => { "type" => "number" }
          },
          "required" => %w[framework_id capability_id role_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "frameworks_add_category",
        "description" => "Add a capability category to a framework (owner/editor/lead only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "name" => { "type" => "string" },
            "description" => { "type" => "string" },
            "ordinal" => { "type" => "integer" }
          },
          "required" => %w[framework_id name],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_add_level",
        "description" => "Add a level to a role (owner/editor/lead only; opens/joins a draft, published on the next version).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "role_id"      => { "type" => "string" },
            "ordinal"      => { "type" => "integer" },
            "title"        => { "type" => "string" },
            "code"         => { "type" => "string" },
            "is_entry"     => { "type" => "boolean" }
          },
          "required" => %w[framework_id role_id ordinal title code],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_add_role",
        "description" => "Add a role to a role family (owner/editor/lead only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "role_family_id" => { "type" => "string" },
            "name" => { "type" => "string" },
            "code" => { "type" => "string" },
            "track" => { "type" => "string", "enum" => %w[ic management] }
          },
          "required" => %w[framework_id role_family_id name code track],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_add_role_family",
        "description" => "Add a role family to a framework (owner/editor/lead only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "name" => { "type" => "string" },
            "description" => { "type" => "string" },
            "department" => { "type" => "string" }
          },
          "required" => %w[framework_id name],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_amend_suggestion",
        "description" => "Revise your own pending framework suggested edit (author only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id"    => { "type" => "string" },
            "suggestion_id"   => { "type" => "string" },
            "suggested_value" => { "type" => "string" },
            "rationale"       => { "type" => "string" }
          },
          "required" => %w[framework_id suggestion_id suggested_value],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_approve_suggestion",
        "description" => "Approve a pending framework suggested edit (tier authority required).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id"  => { "type" => "string" },
            "suggestion_id" => { "type" => "string" },
            "comment"       => { "type" => "string" }
          },
          "required" => %w[framework_id suggestion_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_archive_capability",
        "description" => "Archive a capability — applied directly with approval rights in editing mode, else proposed as a suggestion.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "capability_id" => { "type" => "string" },
            "reason" => { "type" => "string" },
            "mapping_type" => { "type" => "string", "enum" => %w[same evolved split archived new] },
            "to_stable_id" => { "type" => "string" },
            "mode" => { "type" => "string", "enum" => %w[editing suggesting] }
          },
          "required" => %w[framework_id capability_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_archive_category",
        "description" => "Archive an (empty) capability category (owner/editor/lead only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "category_id" => { "type" => "string" },
            "reason" => { "type" => "string" }
          },
          "required" => %w[framework_id category_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_archive_illustration",
        "description" => "Archive a role illustration — removed directly with approval rights in editing mode, else proposed as a suggestion.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "illustration_id" => { "type" => "string" },
            "reason" => { "type" => "string" },
            "mode" => { "type" => "string", "enum" => %w[editing suggesting] }
          },
          "required" => %w[framework_id illustration_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
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
        "name" => "frameworks_define_migration_mapping",
        "description" => "Define or edit a capability migration mapping for the current draft (owner/editor only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "from_stable_id" => { "type" => "string" },
            "mapping_type" => { "type" => "string", "enum" => %w[same evolved split archived new] },
            "to_stable_id" => { "type" => "string" },
            "mapping_id" => { "type" => "string" },
            "reason" => { "type" => "string" }
          },
          "required" => %w[framework_id from_stable_id mapping_type],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
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
        "name" => "frameworks_publish_version",
        "description" => "Publish the current draft as a new framework version (owner/editor only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" }
          },
          "required" => [ "framework_id" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_recent_activity",
        "description" => "Recent framework activity (suggestions, draft/version lifecycle, structural and " \
          "editorial edits, collaborator changes) — metadata only, most-recent first.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "limit" => { "type" => "integer" }
          },
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
        "name" => "frameworks_reject_suggestion",
        "description" => "Reject a pending framework suggested edit, optionally with a reason (tier authority required).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id"  => { "type" => "string" },
            "suggestion_id" => { "type" => "string" },
            "comment"       => { "type" => "string" }
          },
          "required" => %w[framework_id suggestion_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_remove_capability_role_binding",
        "description" => "Remove a capability-role binding, un-scoping the capability from that role (owner/editor/lead only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "binding_id"   => { "type" => "string" }
          },
          "required" => %w[framework_id binding_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "frameworks_rename_department",
        "description" => "Rename a department grouping across all its role families (owner/editor/lead only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "from"         => { "type" => "string" },
            "to"           => { "type" => "string" }
          },
          "required" => %w[framework_id from],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "frameworks_set_behavioural_expectation",
        "description" => "Author a behavioural expectation for an empty cell — applied directly with approval rights in editing mode, else proposed as a suggestion.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id"  => { "type" => "string" },
            "capability_id" => { "type" => "string" },
            "level_ordinal" => { "type" => "integer" },
            "description"   => { "type" => "string" },
            "mode"          => { "type" => "string", "enum" => %w[editing suggesting] }
          },
          "required" => %w[framework_id capability_id level_ordinal description],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "frameworks_update_capability_role_binding",
        "description" => "Update a capability-role binding's weight and/or individual tolerance (owner/editor/lead only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id"         => { "type" => "string" },
            "binding_id"           => { "type" => "string" },
            "weight"               => { "type" => "number" },
            "individual_tolerance" => { "type" => "number" }
          },
          "required" => %w[framework_id binding_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "frameworks_update_level",
        "description" => "Update a level's title, code, or entry-level flag (owner/editor/lead only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "level_id"     => { "type" => "string" },
            "title"        => { "type" => "string" },
            "code"         => { "type" => "string" },
            "is_entry"     => { "type" => "boolean" }
          },
          "required" => %w[framework_id level_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "frameworks_update_role",
        "description" => "Update a role's name, code, or track (owner/editor/lead only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "role_id"      => { "type" => "string" },
            "name"         => { "type" => "string" },
            "code"         => { "type" => "string" },
            "track"        => { "type" => "string", "enum" => %w[ic management] }
          },
          "required" => %w[framework_id role_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "frameworks_update_role_family",
        "description" => "Update a role family's name, description, or department (owner/editor/lead only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id"   => { "type" => "string" },
            "role_family_id" => { "type" => "string" },
            "name"           => { "type" => "string" },
            "description"    => { "type" => "string" },
            "department"     => { "type" => "string" }
          },
          "required" => %w[framework_id role_family_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "frameworks_withdraw_suggestion",
        "description" => "Withdraw your own pending framework suggested edit (author only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id"  => { "type" => "string" },
            "suggestion_id" => { "type" => "string" }
          },
          "required" => %w[framework_id suggestion_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "reporting_capability_attainment",
        "description" => "Aggregate capability attainment for an assessment cycle across the caller's " \
          "org subtree (admins see the whole cycle): per role and role family, the share " \
          "of people at or above their assessed level on each capability with assessed " \
          "coverage, plus the share passing each category gate. Small groups are " \
          "suppressed for non-admin viewers. Returns aggregates only — never individual " \
          "ratings.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "cycle_id" => { "type" => "string" },
            "perspective" => { "type" => "string", "enum" => [ "effective", "self", "manager", "aligned" ] },
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

  # The published JSON Schema for an evidence item's external_reference,
  # shared by every evidence-write tool's snapshot. Mirrors
  # ExternalReference.json_schema (deep-stringified) so clients see the
  # accepted keys + the `system` enum instead of a bare free-form object.
  def external_reference_schema
    {
      "type" => "object",
      "description" => "Optional pointer to a supporting source in an external system.",
      "properties" => {
        "system"      => { "type" => "string", "enum" => ExternalReference::SYSTEMS,
                           "description" => "Originating system." },
        "url"         => { "type" => "string", "description" => "An http(s) link to the source." },
        "external_id" => { "type" => "string", "description" => "The item's ID within that system." },
        "metadata"    => { "type" => "object", "description" => "Free-form additional fields." }
      },
      "additionalProperties" => false
    }
  end
end
