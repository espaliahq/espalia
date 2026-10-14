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
            "valence"              => { "type" => "string", "enum" => EvidenceLink::VALENCES },
            "rationale"            => { "type" => "string" }
          },
          "required" => %w[assignment_id evidence_id capability_stable_id level_ordinal valence],
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
        "description" => "Record the aligned (agreed) frequency for one capability × level. Pass as_role_id when " \
          "aligning against another role (a started role lens); the cell must be one that role reads.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "frequency"            => { "type" => "string", "enum" => %w[none some occasional consistent] },
            "comment"              => { "type" => "string" },
            "as_role_id"           => { "type" => "string" }
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
        "description" => "Fetch one capability's detail, the assessee's per-level ratings (self/manager/aligned), and the capability's own score on the same level-independent scale. Accepts either capability_id (version-specific) or stable_id (cross-version) in the capability_id argument. Pass as_role_id and/or as_level_ordinal to score it against another role or level (a lens); lens.home is then false, and in_role says whether the record's role and the lens role read the capability.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"    => { "type" => "string" },
            "capability_id"    => { "type" => "string" },
            "as_role_id"       => { "type" => "string" },
            "as_level_ordinal" => { "type" => "integer" }
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
        "name" => "assessments_close_exploration",
        "description" => "Close an open exploration of another role with its outcome: pursue (work towards it), " \
                         "not_now (set it aside) or moved (they have moved into the role), plus an optional note.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"  => { "type" => "string" },
            "exploration_id" => { "type" => "string" },
            "outcome"        => { "type" => "string", "enum" => %w[pursue not_now moved] },
            "note"           => { "type" => "string" }
          },
          "required" => %w[assignment_id exploration_id outcome],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "assessments_comments_list",
        "description" => "List active comment threads on an assessment for one capability (optionally one level). " \
                         "Accepts either capability_id (version-specific) or stable_id (cross-version) in the " \
                         "capability_stable_id argument. Top-level comments carry their replies nested. " \
                         "Pass evidence_id to list the discussion thread on that evidence item's linkage " \
                         "at the cell instead of the cell's own comments.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "evidence_id"          => { "type" => "string" }
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
        "name" => "assessments_complete_alignment",
        "description" =>
          "Mark the alignment conversation complete for one of your direct reports — against their own " \
          "role, or against another role with as_role_id. Every current-level cell of that role must " \
          "carry an agreed rating.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"    => { "type" => "string" },
            "as_role_id"       => { "type" => "string" },
            "as_level_ordinal" => { "type" => "integer" }
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
        "name" => "assessments_confirm_carried_ratings",
        "description" => "Confirm ratings carried forward from the last cycle, unchanged, as this cycle's rating — the same as re-picking each value. perspective self confirms your own ratings, manager the manager ratings you give. Only cells whose value on that side is still carried are confirmed; the rest are listed under skipped with the reason. To change a value use assessments_rate_self or assessments_rate_as_manager instead.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id" => {
              "type" => "string"
            },
            "perspective" => {
              "type" => "string",
              "enum" => [ "self", "manager" ]
            },
            "cells" => {
              "type" => "array",
              "minItems" => 1,
              "items" => {
                "type" => "object",
                "properties" => {
                  "capability_stable_id" => {
                    "type" => "string"
                  },
                  "level_ordinal" => {
                    "type" => "integer"
                  }
                },
                "required" => [ "capability_stable_id", "level_ordinal" ],
                "additionalProperties" => false
              }
            }
          },
          "required" => [ "assignment_id", "perspective", "cells" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
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
        "name" => "assessments_explorations_list",
        "description" => "List the explorations of other roles or levels declared on one assessment, newest first, " \
                         "with who declared them and, once closed, the outcome. Each carries the lens params that " \
                         "read the assessment against its target.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id" => { "type" => "string" },
            "status"        => { "type" => "string", "enum" => %w[open closed all] }
          },
          "required" => [ "assignment_id" ],
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
        "description" => "Fetch one assessment's framework structure, the assessee's current role/level/cycle status, and their score on the level-independent scale (100 = meeting their current level in full) with a per-category breakdown. Each score carries the scale's own meaning, its parts and the framework's thresholds; a score the screen withholds for lack of coverage reports scored: false rather than a number. Pass as_role_id and/or as_level_ordinal to read the same ratings against another role or level (a lens): scoring.lens.home is then false and it is not the assessment of record, and each capability's in_role says whether the record's role and the lens role read it. When that role has an open declared exploration, current_exploration describes it.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"    => { "type" => "string" },
            "as_role_id"       => { "type" => "string" },
            "as_level_ordinal" => { "type" => "integer" }
          },
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
        "description" => "List the caller's own assessment assignments plus the ones they review: their team's (direct reports and active rating delegations) and, view-only, their skip-level reports' assignments. explorations lists the open explorations of other roles on the caller's own assessments and their team's.",
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
        "name" => "assessments_nudge_evidence_request",
        "description" => "Nudge the requestee about an open feedback / evidence request you made (available once 2 days have passed since the last reminder).",
        "inputSchema" => {
          "type" => "object",
          "properties" => { "request_id" => { "type" => "string" } },
          "required" => [ "request_id" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "assessments_post_comment",
        "description" => "Post a comment on a capability × level of an assessment (optionally as a reply). " \
                         "Pass evidence_id to comment on that evidence item's linkage at the cell instead — " \
                         "the discussion of the feedback's relevance and valence there.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "body"                 => { "type" => "string" },
            "parent_id"            => { "type" => "string" },
            "evidence_id"          => { "type" => "string" }
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
        "description" => "Record or update a manager rating for one of your direct reports' capability × level. " \
          "Pass as_role_id to rate a cell another role reads (a role lens): the report sees it only once " \
          "you start alignment against a role that reads the cell. A cell a started alignment reads is frozen.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "frequency"            => { "type" => "string", "enum" => %w[none some occasional consistent] },
            "comment"              => { "type" => "string" },
            "rationale"            => { "type" => "string" },
            "clear"                => { "type" => "boolean" },
            "as_role_id"           => { "type" => "string" }
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
        "description" => "Record or update your own rating for one capability × level. Pass as_role_id to rate a cell " \
          "another role in the framework reads (a role lens): the rating is the same fact about you " \
          "at that capability × level, and counts wherever a role reads the cell.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "frequency"            => { "type" => "string", "enum" => %w[none some occasional consistent] },
            "comment"              => { "type" => "string" },
            "rationale"            => { "type" => "string" },
            "clear"                => { "type" => "boolean" },
            "as_role_id"           => { "type" => "string" }
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
            "valence"              => { "type" => "string", "enum" => EvidenceLink::VALENCES },
            "external_reference"   => external_reference_schema,
            "additional_links"     => {
              "type" => "array",
              "items" => {
                "type" => "object",
                "properties" => {
                  "capability_stable_id" => { "type" => "string" },
                  "level_ordinal"        => { "type" => "integer" },
                  "valence"              => { "type" => "string", "enum" => EvidenceLink::VALENCES }
                },
                "required" => %w[capability_stable_id level_ordinal valence]
              }
            }
          },
          "required" => %w[assignment_id capability_stable_id level_ordinal evidence_type content valence],
          "additionalProperties" => false,
          **custom_type_label_conditional
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
          "Re-open a completed alignment so the manager can correct it; agreed values are preserved. " \
          "Pass as_role_id to re-open an alignment against another role.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"    => { "type" => "string" },
            "as_role_id"       => { "type" => "string" },
            "as_level_ordinal" => { "type" => "integer" }
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
            "evidence_type"      => { "type" => "string", "enum" => %w[peer_feedback manager_feedback customer_feedback impact project_outcome code_review design_review incident_response presentation mentoring observation other] },
            "content"            => { "type" => "string" },
            "valence"            => { "type" => "string", "enum" => EvidenceLink::VALENCES },
            "custom_type_label"  => { "type" => "string" },
            "title"              => { "type" => "string" },
            "external_reference" => external_reference_schema
          },
          "required" => %w[request_id evidence_type content valence],
          "additionalProperties" => false,
          **custom_type_label_conditional
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
        "name" => "assessments_set_evidence_link_valence",
        "description" => "Reclassify the valence of a feedback / evidence link (what the evidence says about the behaviour at that capability × level).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "evidence_id"          => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "valence"              => { "type" => "string", "enum" => EvidenceLink::VALENCES }
          },
          "required" => %w[assignment_id evidence_id capability_stable_id level_ordinal valence],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "assessments_start_alignment",
        "description" =>
          "Start the alignment conversation for one of your direct reports — against their own role, or " \
          "against another role or level with as_role_id / as_level_ordinal. Discloses your ratings on " \
          "that role's cells to the report and freezes both parties' ratings there.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"    => { "type" => "string" },
            "as_role_id"       => { "type" => "string" },
            "as_level_ordinal" => { "type" => "integer" }
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
        "name" => "assessments_start_exploration",
        "description" => "Declare that a person is exploring another role or level — an intent both they and their " \
                         "manager see, not a rating. Name the target like a lens: as_role_id (blank = their own " \
                         "role) and/or as_level_ordinal; it can't be the role and level they hold, and only one " \
                         "exploration per role is open at a time. The other party is notified.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"    => { "type" => "string" },
            "as_role_id"       => { "type" => "string" },
            "as_level_ordinal" => { "type" => "integer" },
            "note"             => { "type" => "string" }
          },
          "required" => [ "assignment_id" ],
          "additionalProperties" => false,
          "anyOf" => [ { "required" => [ "as_role_id" ] }, { "required" => [ "as_level_ordinal" ] } ]
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
          "additionalProperties" => false,
          **custom_type_label_conditional
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
        "name" => "calibration_sessions_add_calibrant",
        "description" => "Add a person from the facilitator's org to a draft calibration session's population.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "session_id" => { "type" => "string" },
            "person_id"  => { "type" => "string" }
          },
          "required" => %w[session_id person_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "calibration_sessions_add_participant",
        "description" => "Add a participating rater to a draft calibration session (auto-removes them from the calibrant population if present).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "session_id" => { "type" => "string" },
            "person_id"  => { "type" => "string" }
          },
          "required" => %w[session_id person_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "calibration_sessions_close",
        "description" => "Close a calibration session (terminal — a closed session becomes the follow-through record).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "session_id" => { "type" => "string" }
          },
          "required" => %w[session_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "calibration_sessions_define",
        "description" => "Define a calibration session (draft) for an assessment cycle. You become the facilitator; seed the participating raters and the calibrant population (typically the participants' reports).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "cycle_id" => { "type" => "string" },
            "name"     => { "type" => "string" },
            "participant_ids" => {
              "type" => "array",
              "items" => { "type" => "string" },
              "description" => "person_ids of the participating raters"
            },
            "calibrant_person_ids" => {
              "type" => "array",
              "items" => { "type" => "string" },
              "description" => "person_ids of the people being calibrated — never a participant or the facilitator"
            }
          },
          "required" => %w[cycle_id name participant_ids],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "calibration_sessions_flag_expectation",
        "description" => "Flag a capability × level expectation as unclear from a live calibration session — raises a framework clarification.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "session_id"           => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "reason"               => { "type" => "string" }
          },
          "required" => %w[session_id capability_stable_id level_ordinal],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "calibration_sessions_flag_illustration",
        "description" => "Flag one example (role illustration) as unclear from a live calibration session — raises a framework clarification anchored on the example.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "session_id"      => { "type" => "string" },
            "illustration_id" => { "type" => "string" },
            "reason"          => { "type" => "string" }
          },
          "required" => %w[session_id illustration_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "calibration_sessions_get",
        "description" => "Get one calibration session — lifecycle state plus participant and calibrant rosters.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "session_id" => { "type" => "string" }
          },
          "required" => %w[session_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => true,
          "destructiveHint" => false,
          "idempotentHint"  => true
        }
      },
      {
        "name" => "calibration_sessions_list",
        "description" => "List calibration sessions you facilitate (admins see all), optionally filtered to one assessment cycle.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "cycle_id" => { "type" => "string" }
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
        "name" => "calibration_sessions_overview",
        "description" => "Calibration overview for a session — per-rater tendency (mean vs org, distribution, self-gap, evidence backing), capabilities ranked by tendency-corrected rater disagreement, and level cohorts of per-person % of expected (100 = meeting the level, 200 = demonstrating the next level in full; manager ratings only; a coverage-gated person carries pct: null with rated/total/unlock_target — not rated yet, never a low score).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "session_id" => { "type" => "string" }
          },
          "required" => %w[session_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => true,
          "destructiveHint" => false,
          "idempotentHint"  => true
        }
      },
      {
        "name" => "calibration_sessions_record_note",
        "description" => "Record a free-text minute on a live calibration session, optionally anchored to a capability or person.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "session_id"           => { "type" => "string" },
            "body"                 => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "person_id"            => { "type" => "string" }
          },
          "required" => %w[session_id body],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "calibration_sessions_remove_calibrant",
        "description" => "Remove a person from a draft calibration session's population.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "session_id" => { "type" => "string" },
            "person_id"  => { "type" => "string" }
          },
          "required" => %w[session_id person_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "calibration_sessions_remove_participant",
        "description" => "Remove a participating rater from a draft calibration session (their reports stay in the population).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "session_id" => { "type" => "string" },
            "person_id"  => { "type" => "string" }
          },
          "required" => %w[session_id person_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "calibration_sessions_request_evidence",
        "description" => "Ask a colleague for feedback / evidence on a capability × level from a live calibration session.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "session_id"           => { "type" => "string" },
            "person_id"            => { "type" => "string" },
            "requestee_person_id"  => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "message"              => { "type" => "string" },
            "due_at"               => { "type" => "string" }
          },
          "required" => %w[session_id person_id requestee_person_id capability_stable_id level_ordinal],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "calibration_sessions_request_rating_revisit",
        "description" => "Ask a rater to revisit a manager rating from a live calibration session — value-free, with the room's note.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "session_id"           => { "type" => "string" },
            "person_id"            => { "type" => "string" },
            "capability_stable_id" => { "type" => "string" },
            "level_ordinal"        => { "type" => "integer" },
            "note"                 => { "type" => "string" }
          },
          "required" => %w[session_id person_id capability_stable_id level_ordinal note],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "calibration_sessions_start",
        "description" => "Start a calibration session — freezes the participants and the calibrant population.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "session_id" => { "type" => "string" }
          },
          "required" => %w[session_id],
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
            "role_ids" => {
              "type" => "array",
              "items" => { "type" => "string", "minLength" => 1, "pattern" => "\\S" },
              "minItems" => 1,
              "description" => "At least one role id to bind the capability to — " \
                               "a capability bound to no role is hidden from the role-filtered matrix"
            }
          },
          "required" => %w[framework_id category_id name role_ids],
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
        "name" => "frameworks_add_collaborator",
        "description" => "Grant a person a collaborator role on a framework — framework-wide (owner/editor/collaborator/viewer) or scoped via scope_type + scope_id (the four lead roles).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "person_id" => { "type" => "string" },
            "role" => {
              "type" => "string",
              "enum" => %w[owner editor role_family_lead role_lead capability_category_lead capability_lead collaborator viewer]
            },
            "scope_type" => {
              "type" => "string",
              "enum" => %w[role_family role capability_category capability]
            },
            "scope_id" => { "type" => "string" }
          },
          "required" => %w[framework_id person_id role],
          "additionalProperties" => false,
          **collaborator_scope_conditional("role")
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
        "description" => "Archive a capability — applied directly with approval rights in editing mode, else proposed as a suggestion. A supplied migration mapping is staged only if you may define one (owner/editor); the response's mapping_recorded says whether it was, otherwise it is deferred to the publish-review gate.",
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
          "additionalProperties" => false,
          **survivor_mapping_conditional(mapping_type_optional: true)
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
        "description" => "Archive an example (role illustration) — removed directly with approval rights in editing mode, else proposed as a suggestion.",
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
        "description" => "Fetch one capability's full detail: bindings, expectations per level, examples (the illustrations key). Accepts either capability_id (version-specific) or stable_id (cross-version) in the capability_id argument.",
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
        "name" => "frameworks_change_collaborator_role",
        "description" => "Change a collaborator's framework-wide role on a framework (e.g. viewer → editor). Only the framework-wide roles (owner/editor/collaborator/viewer) can be changed in place: to move a person to or from a scoped lead role, call frameworks_remove_collaborator for the old role then frameworks_add_collaborator for the new one.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "person_id" => { "type" => "string" },
            # Framework-wide only: a scoped lead role can never be changed in
            # place, since each has its own entity type and the scope pair is
            # fixed across the change. Moving to/from one is remove + add.
            "old_role" => { "type" => "string", "enum" => %w[owner editor collaborator viewer] },
            "new_role" => { "type" => "string", "enum" => %w[owner editor collaborator viewer] },
            "scope_type" => {
              "type" => "string",
              "enum" => %w[role_family role capability_category capability]
            },
            "scope_id" => { "type" => "string" }
          },
          "required" => %w[framework_id person_id old_role new_role],
          "additionalProperties" => false,
          # Every accepted role is framework-wide, so the forbid covers the
          # whole enum — the params stay declared so a supplied scope is
          # rejected rather than silently dropped.
          "allOf" => %w[scope_type scope_id].map do |dependent|
            {
              "if" => {
                "properties" => { "new_role" => { "enum" => %w[owner editor collaborator viewer] } },
                "required" => [ "new_role" ]
              },
              "then" => { "not" => { "required" => [ dependent ] } }
            }
          end
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_comment_on_suggestion",
        "description" => "Comment on a framework suggestion's discussion thread (optionally as a reply). Threads stay open after the suggestion is resolved.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "suggestion_id" => { "type" => "string" },
            "body" => { "type" => "string" },
            "parent_id" => { "type" => "string" }
          },
          "required" => %w[framework_id suggestion_id body],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_configure_scoring_thresholds",
        "description" => "Replace a framework's scoring-threshold configuration (tenant admin only). Omitted thresholds revert to system defaults — this is a full replacement, not a partial update.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "mastery_threshold" => { "type" => "number" },
            "meeting_expectation_threshold" => { "type" => "number" },
            "underperforming_threshold" => { "type" => "number" },
            "overperformance_cap" => { "type" => "integer" },
            "deficit_threshold" => { "type" => "number" }
          },
          "required" => %w[framework_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
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
          "additionalProperties" => false,
          **survivor_mapping_conditional
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_define_migration_mappings",
        "description" => "Save migration mappings for several retiring capabilities in one atomic write; " \
          "unchanged rows are skipped and rows still needing a survivor are reported (owner/editor only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "mappings" => {
              "type" => "array",
              "items" => {
                "type" => "object",
                "properties" => {
                  "from_stable_id" => { "type" => "string" },
                  "mapping_type" => { "type" => "string", "enum" => %w[same evolved split archived new] },
                  "to_stable_id" => { "type" => "string" },
                  "mapping_id" => { "type" => "string" }
                },
                "required" => [ "from_stable_id" ]
              }
            }
          },
          "required" => %w[framework_id mappings],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_delete_suggestion_comment",
        "description" => "Delete a comment on a framework suggestion's thread (soft delete — preserves reply chains; author or tenant admin).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "comment_id" => { "type" => "string" },
            "reason" => { "type" => "string" }
          },
          "required" => %w[framework_id comment_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_edit_suggestion_comment",
        "description" => "Revise your own comment on a framework suggestion's discussion thread (author only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "comment_id" => { "type" => "string" },
            "body" => { "type" => "string" }
          },
          "required" => %w[framework_id comment_id body],
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
        "description" => "Request publication of the current draft as a new framework version; " \
          "runs in the background and notifies the requester (owner/editor only).",
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
        "name" => "frameworks_remove_collaborator",
        "description" => "Remove a collaborator role from a person on a framework (their other roles on the framework are untouched).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "person_id" => { "type" => "string" },
            "role" => {
              "type" => "string",
              "enum" => %w[owner editor role_family_lead role_lead capability_category_lead capability_lead collaborator viewer]
            },
            "scope_type" => {
              "type" => "string",
              "enum" => %w[role_family role capability_category capability]
            },
            "scope_id" => { "type" => "string" }
          },
          "required" => %w[framework_id person_id role],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "frameworks_rename",
        "description" => "Rename a framework (tenant admin or framework owner only).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "name"         => { "type" => "string", "minLength" => 1, "pattern" => "\\S" }
          },
          "required" => %w[framework_id name],
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
        "name" => "frameworks_reorder_capabilities",
        "description" => "Reorder the capabilities within one category (owner/editor/lead only). " \
                         "Pass the complete list of the category's active capability ids in the desired display order.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "category_id"  => { "type" => "string" },
            "new_ordering" => {
              "type" => "array",
              "items" => { "type" => "string" },
              "description" => "Every active capability id in this category, in the desired display order"
            }
          },
          "required" => %w[framework_id category_id new_ordering],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "frameworks_reorder_categories",
        "description" => "Reorder the framework's capability categories (owner/editor/lead only). " \
                         "Pass the complete list of active category ids in the desired display order.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "new_ordering" => {
              "type" => "array",
              "items" => { "type" => "string" },
              "description" => "Every active category id, in the desired display order"
            }
          },
          "required" => %w[framework_id new_ordering],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "frameworks_reorder_illustrations",
        "description" => "Reorder the examples (role illustrations) for one expectation and role (owner/editor/lead only). " \
                         "Pass the complete list of example (illustration) ids in the desired display order.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id"   => { "type" => "string" },
            "expectation_id" => { "type" => "string" },
            "role_id"        => { "type" => "string" },
            "new_ordering"   => {
              "type" => "array",
              "items" => { "type" => "string" },
              "description" => "Every example (illustration) id for this expectation × role, in the desired order"
            }
          },
          "required" => %w[framework_id expectation_id role_id new_ordering],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "frameworks_request_clarification",
        "description" => "Ask for clarification of a capability, one of its level expectations, or a role " \
                         "example (illustration) — opens a discussion, proposes nothing.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id"    => { "type" => "string" },
            # Exactly one anchor is required — a choice JSON Schema `required`
            # can't express, so each param's description carries the obligation
            # (the Operation enforces it).
            "capability_id"   => {
              "type" => "string", "minLength" => 1, "pattern" => "\\S",
              "description" => "The capability to anchor on. Required unless illustration_id is given."
            },
            "illustration_id" => {
              "type" => "string", "minLength" => 1, "pattern" => "\\S",
              "description" => "An example (role illustration) to anchor on — the most specific target, and its " \
                               "level is taken from the owning expectation. Required unless capability_id is given."
            },
            "level_ordinal"   => { "type" => "integer" },
            "rationale"       => { "type" => "string" }
          },
          "required" => %w[framework_id rationale],
          "additionalProperties" => false,
          "anyOf" => [
            { "required" => [ "capability_id" ] },
            { "required" => [ "illustration_id" ] }
          ]
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "frameworks_resolve_clarification",
        "description" => "Resolve a pending clarification with a note (expectation-tier authority required).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id"            => { "type" => "string" },
            "suggestion_id"           => { "type" => "string" },
            "note"                    => { "type" => "string" },
            "resulting_suggestion_id" => { "type" => "string" }
          },
          "required" => %w[framework_id suggestion_id note],
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
        "name" => "frameworks_suggest_create",
        "description" => "Propose creating a framework entity (example, expectation, capability, category, role, role family, level) as a suggestion — pending review by default; applied directly with approval rights in editing mode.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "entity_type"  => {
              "type" => "string",
              "enum" => %w[role_illustration behavioural_expectation capability capability_category role role_family level]
            },
            "proposed_attributes" => {
              "type" => "object",
              "description" => "Attributes for the new entity. Required keys by entity_type — " \
                               "role_illustration: role_id, description · behavioural_expectation: level_ordinal, description · " \
                               "capability: name · capability_category: name · role: name, code, track · " \
                               "role_family: name · level: ordinal, title, code.",
              "properties" => {
                "name"          => { "type" => "string" },
                "description"   => { "type" => "string" },
                "title"         => { "type" => "string" },
                "code"          => { "type" => "string" },
                "track"         => { "type" => "string", "enum" => %w[ic management] },
                "role_id"       => { "type" => "string" },
                "level_ordinal" => { "type" => "integer" },
                "ordinal"       => { "type" => "integer" },
                "is_entry"      => { "type" => "boolean" }
              },
              "additionalProperties" => false
            },
            "parent_id" => { "type" => "string" },
            "rationale" => { "type" => "string" },
            "mode"      => { "type" => "string", "enum" => %w[editing suggesting] }
          },
          "required" => %w[framework_id entity_type proposed_attributes],
          "additionalProperties" => false,
          **parent_id_conditional
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "frameworks_suggest_delete",
        "description" => "Propose deleting a framework entity (capability or example) as a pending suggestion — nothing is removed until a reviewer approves.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "entity_type"  => { "type" => "string", "enum" => %w[role_illustration capability] },
            "entity_id"    => { "type" => "string" },
            "rationale"    => { "type" => "string" }
          },
          "required" => %w[framework_id entity_type entity_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "frameworks_suggest_edit",
        "description" => "Edit framework content (capability/category name or description, expectation or example text) — applied directly with approval rights in editing mode, else proposed as a suggestion; consecutive edits amend your pending proposal.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "entity_type"  => {
              "type" => "string",
              "enum" => %w[capability capability_category behavioural_expectation role_illustration]
            },
            "entity_id" => { "type" => "string" },
            "field"     => { "type" => "string", "enum" => %w[name description] },
            "value"     => { "type" => "string" },
            "rationale" => { "type" => "string" },
            "mode"      => { "type" => "string", "enum" => %w[editing suggesting] }
          },
          "required" => %w[framework_id entity_type entity_id field value],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
      {
        "name" => "frameworks_suggestion_get",
        "description" => "Fetch one framework suggestion in full: proposal, resolution status, and its discussion thread (top-level comments with replies nested).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" },
            "suggestion_id" => { "type" => "string" }
          },
          "required" => %w[framework_id suggestion_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true
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
          "additionalProperties" => false,
          "anyOf" => [
            { "required" => [ "weight" ] },
            { "required" => [ "individual_tolerance" ] }
          ]
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
            "title"        => { "type" => "string", "minLength" => 1, "pattern" => "\\S" },
            "code"         => { "type" => "string", "minLength" => 1, "pattern" => "\\S" },
            "is_entry"     => { "type" => "boolean" }
          },
          "required" => %w[framework_id level_id],
          "additionalProperties" => false,
          "anyOf" => [
            { "required" => [ "title" ] },
            { "required" => [ "code" ] },
            { "required" => [ "is_entry" ] }
          ]
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
            "name"         => { "type" => "string", "minLength" => 1, "pattern" => "\\S" },
            "code"         => { "type" => "string", "minLength" => 1, "pattern" => "\\S" },
            "track"        => { "type" => "string", "enum" => %w[ic management] }
          },
          "required" => %w[framework_id role_id],
          "additionalProperties" => false,
          "anyOf" => [
            { "required" => [ "name" ] },
            { "required" => [ "code" ] },
            { "required" => [ "track" ] }
          ]
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
            "name"           => { "type" => "string", "minLength" => 1, "pattern" => "\\S" },
            "description"    => { "type" => "string" },
            "department"     => { "type" => "string" }
          },
          "required" => %w[framework_id role_family_id],
          "additionalProperties" => false,
          "anyOf" => [
            { "required" => [ "name" ] },
            { "required" => [ "description" ] },
            { "required" => [ "department" ] }
          ]
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
        "name" => "integrations_hris_titles",
        "description" => "List the job titles active HRIS people hold, each with the framework role mapping it " \
                         "resolves to (nil = unmapped, so the sync skips those people) and the people the next " \
                         "sync would change. Also lists the framework's roles and their levels as mapping targets.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "unmapped_only" => { "type" => "boolean" }
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
        "name" => "integrations_map_hris_title",
        "description" => "Map an HRIS job title to a framework role, replacing any mapping it had. Omit " \
                         "level_ordinal to take each person's level from the HRIS level column, or pass one to " \
                         "fix the level for everyone with that title. Applied by the next HRIS sync; the result " \
                         "previews what that sync will do to each person holding the title.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "title"               => { "type" => "string", "minLength" => 1, "pattern" => "\\S" },
            "framework_role_code" => { "type" => "string", "minLength" => 1, "pattern" => "\\S" },
            "level_ordinal"       => { "type" => "integer" }
          },
          "required" => %w[title framework_role_code],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "integrations_unmap_hris_title",
        "description" => "Remove an HRIS job title from the role mappings. The next sync skips people holding " \
                         "it, and they keep their current framework assignment (listed in the result).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "title" => { "type" => "string", "minLength" => 1, "pattern" => "\\S" }
          },
          "required" => %w[title],
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
          "coverage, plus the share passing each category gate. Returns aggregates only " \
          "— never individual ratings.",
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
        "name" => "reporting_evidence_coverage",
        "description" => "Aggregate feedback and evidence-request coverage for an assessment cycle " \
          "across the caller's org subtree (admins see the whole cycle): feedback " \
          "provided by request or as proactive feedback, immutable manager/report/peer directionality, " \
          "withdrawn feedback, request statuses, fulfilment rate, participant coverage, " \
          "and optional manager/role/level groups. Pass month (YYYY-MM) to narrow to feedback " \
          "recorded and requests sent in one calendar month of the cycle; the response lists " \
          "the months available.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "cycle_id" => { "type" => "string" },
            "mode" => { "type" => "string", "enum" => [ "summary", "full" ] },
            "scope" => { "type" => "string", "enum" => [ "mine", "all" ] },
            "month" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "^[0-9]{4}-(0[1-9]|1[0-2])$",
              "description" => "Calendar month within the cycle, YYYY-MM. Omit for the whole cycle."
            }
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
        "name" => "reporting_feedback_export",
        "description" => "Export every piece of feedback / evidence in an assessment cycle, one row each, " \
          "for monthly reporting (tenant admins only): recipient and provider with their roles, " \
          "direction, requested or proactive, type, title, the feedback text, the behaviours it " \
          "applies to, and status. The rows are exactly the feedback the cycle's coverage report " \
          "counts. Pass month (YYYY-MM) to narrow to feedback recorded in one calendar month, and " \
          "include_withdrawn to list withdrawn feedback too. The response carries every row's full text, " \
          "so a month is far smaller than a whole cycle; for counts alone use reporting_evidence_coverage.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "cycle_id" => { "type" => "string", "minLength" => 1, "pattern" => "\\S" },
            "month" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "^[0-9]{4}-(0[1-9]|1[0-2])$",
              "description" => "Calendar month within the cycle, YYYY-MM. Omit for the whole cycle."
            },
            "include_withdrawn" => { "type" => "boolean" }
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
        "name" => "tenants_update_scoring_vocabulary",
        "description" => "Rename the performance states for the active tenant (display labels only — the scoring states and thresholds are unchanged). Blank restores the default word.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "underperforming_label" => { "type" => "string" },
            "progressing_label" => { "type" => "string" },
            "performing_label" => { "type" => "string" },
            "mastering_label" => { "type" => "string" },
            "eligible_label" => { "type" => "string" }
          },
          "required" => [],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
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

  # `requires_when :custom_type_label, if: :evidence_type, equals: "other"` —
  # shared by the three evidence-write tools that carry the rule.
  def custom_type_label_conditional
    {
      "if" => {
        "properties" => { "evidence_type" => { "const" => "other" } },
        "required" => [ "evidence_type" ]
      },
      "then" => {
        "required" => [ "custom_type_label" ],
        "properties" => { "custom_type_label" => { "minLength" => 1, "pattern" => "\\S" } }
      }
    }
  end

  # The collaborator scope pair: each lead role pins scope_type to its own
  # entity type and demands a scope_id; the four framework-wide roles accept
  # neither. Only add_collaborator carries the full rule — change_collaborator_role
  # accepts framework-wide roles alone, so it spells out its two forbids inline.
  #
  # @param role_param [String] the parameter naming the role being granted
  def collaborator_scope_conditional(role_param)
    scoped = {
      "role_family_lead"         => "role_family",
      "role_lead"                => "role",
      "capability_category_lead" => "capability_category",
      "capability_lead"          => "capability"
    }
    pins = scoped.map do |role, scope_type|
      {
        "if" => { "properties" => { role_param => { "const" => role } }, "required" => [ role_param ] },
        "then" => { "required" => [ "scope_type" ],
                    "properties" => { "scope_type" => { "const" => scope_type } } }
      }
    end
    # scope_id carries no per-role value, so one rule covers all four.
    scope_id_required = {
      "if" => {
        "properties" => { role_param => { "enum" => scoped.keys } },
        "required" => [ role_param ]
      },
      "then" => { "required" => [ "scope_id" ],
                  "properties" => { "scope_id" => { "minLength" => 1, "pattern" => "\\S" } } }
    }
    exclusions = %w[scope_type scope_id].map do |dependent|
      {
        "if" => {
          "properties" => { role_param => { "enum" => %w[owner editor collaborator viewer] } },
          "required" => [ role_param ]
        },
        "then" => { "not" => { "required" => [ dependent ] } }
      }
    end

    { "allOf" => pins + [ scope_id_required ] + exclusions }
  end

  # A parent is required for the entity types that hang off one and forbidden
  # for the framework-level ones, so both `if`s nest under one `allOf`.
  def parent_id_conditional
    {
      "allOf" => [
        {
          "if" => {
            "properties" => {
              "entity_type" => {
                "enum" => %w[role_illustration behavioural_expectation capability role level]
              }
            },
            "required" => [ "entity_type" ]
          },
          "then" => {
            "required" => [ "parent_id" ],
            "properties" => { "parent_id" => { "minLength" => 1, "pattern" => "\\S" } }
          }
        },
        {
          "if" => {
            "properties" => { "entity_type" => { "enum" => %w[capability_category role_family] } },
            "required" => [ "entity_type" ]
          },
          "then" => { "not" => { "required" => [ "parent_id" ] } }
        }
      ]
    }
  end

  # The survivor rule has two halves — required for the mapping types that
  # carry ratings forward, forbidden for the ones that don't — so both `if`s
  # nest under one `allOf`. The matched sets are spelled out rather than read
  # from SURVIVOR_TYPES / NON_SURVIVOR_TYPES: widening either changes what
  # these two tools advertise, and this snapshot exists to make that land in
  # review.
  #
  # @param mapping_type_optional [Boolean] true for archive_capability, whose
  #   mapping_type may be omitted — so it alone also declares the presence
  #   pairing that stops a survivor arriving with no mapping type at all
  def survivor_mapping_conditional(mapping_type_optional: false)
    branches = [
      {
        "if" => {
          "properties" => { "mapping_type" => { "enum" => %w[evolved split] } },
          "required" => [ "mapping_type" ]
        },
        "then" => {
          "required" => [ "to_stable_id" ],
          "properties" => { "to_stable_id" => { "minLength" => 1, "pattern" => "\\S" } }
        }
      },
      {
        "if" => {
          "properties" => { "mapping_type" => { "enum" => %w[same archived new] } },
          "required" => [ "mapping_type" ]
        },
        "then" => { "not" => { "required" => [ "to_stable_id" ] } }
      }
    ]
    if mapping_type_optional
      branches << { "dependentRequired" => { "to_stable_id" => [ "mapping_type" ] } }
    end

    { "allOf" => branches }
  end
end
