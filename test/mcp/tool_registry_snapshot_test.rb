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
        "name" => "assessments_accept_evidence_suggestion",
        "description" => "Accept a placement suggestion: link the feedback / evidence to the suggested capability × level. " \
                         "Pass valence to place it with a different judgement than the one suggested; the decision is then " \
                         "recorded as edited rather than accepted.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "suggestion_id" => { "type" => "string" },
            "valence"       => { "type" => "string", "enum" => EvidenceLink::VALENCES }
          },
          "required" => %w[suggestion_id],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint"    => false,
          "destructiveHint" => false,
          "idempotentHint"  => false
        }
      },
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
        "description" => "Fetch one capability's detail, the assessee's per-level ratings (self/manager/aligned), and the capability's own score on the same level-independent scale. Accepts either capability_id (version-specific) or stable_id (cross-version) in the capability_id argument. Pass as_role_id and/or as_level_ordinal to score it against another role or level (a lens); lens.home is then false, and in_role says whether the record's role and the lens role read the capability. Pass cycle_id (from assessments_get's past_cycles) to read a past cycle: its ratings and score at that cycle's own role and level, lens.past_cycle true; the assessee sees the manager's ratings only where alignment had started, as on the open cycle.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"    => { "type" => "string" },
            "capability_id"    => { "type" => "string" },
            "as_role_id"       => { "type" => "string" },
            "as_level_ordinal" => { "type" => "integer" },
            "cycle_id"         => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S",
              "description" => "A cycle the person joined on this framework, from past_cycles. Ratings and scores are then that cycle's, at its own role and level. Omit for the open cycle."
            }
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
        "name" => "assessments_dismiss_evidence_suggestion",
        "description" => "Dismiss a placement suggestion for a piece of feedback / evidence, optionally saying why. " \
                         "The same capability × level is not suggested for that item again.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "suggestion_id" => { "type" => "string" },
            "reason"        => { "type" => "string" }
          },
          "required" => %w[suggestion_id],
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
        "description" => "Edit the body of one of your own comments on an assessment. " \
                         "`body` is Markdown: links, **bold**, _italic_, lists and `code` render, a bare URL becomes a link, typed HTML shows as text and images render as links.",
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
        "description" => "List active feedback / evidence on an assessment for one capability (optionally one level), " \
                         "or — with no capability — the unplaced items still waiting to be placed on one. " \
                         "Accepts either capability_id (version-specific) or stable_id (cross-version) in " \
                         "the capability_stable_id argument. Each item carries its full set of linked cells.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "capability_stable_id" => { "type" => "string", "minLength" => 1, "pattern" => "\\S" },
            "level_ordinal"        => { "type" => "integer" }
          },
          "required" => %w[assignment_id],
          "additionalProperties" => false,
          "dependentRequired" => { "level_ordinal" => [ "capability_stable_id" ] }
        },
        "annotations" => {
          "readOnlyHint"    => true,
          "destructiveHint" => false,
          "idempotentHint"  => true
        }
      },
      {
        "name" => "assessments_evidence_requests_list",
        "description" => "List feedback / evidence requests addressed to you (incoming) and ones you've made (outgoing), " \
          "each with when it was requested, due, last reminded, and responded to, declined (with the " \
          "reason) or cancelled.",
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
        "name" => "assessments_evidence_suggestions_list",
        "description" => "List the pending placement suggestions on an assessment, or for one feedback / evidence item: " \
                         "the suggested capability × level and valence, a confidence from 0 to 1 and a rationale quoting " \
                         "the feedback (null when the model gives none). Accept or dismiss them with assessments_accept_evidence_suggestion / " \
                         "assessments_dismiss_evidence_suggestion.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id" => { "type" => "string" },
            "evidence_id"   => { "type" => "string", "minLength" => 1, "pattern" => "\\S" }
          },
          "required" => %w[assignment_id],
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
        "name" => "assessments_feedback_recipients",
        "description" => "Find colleagues you can give feedback to: people with a framework assignment, by name or email, " \
                         "or your manager, peers and reports when no query is given. Each row carries the assignment_id " \
                         "to pass to assessments_record_evidence; a peer cannot read the assessment itself.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "query" => { "type" => "string" },
            "limit" => { "type" => "integer" }
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
        "name" => "assessments_feedback_to_place",
        "description" => "List feedback waiting for you to place on a capability: items about you, and items about the people " \
                         "you place feedback for. scope \"team\" (the default) covers your direct reports and the assessments " \
                         "you hold a rating delegation for; \"org\" adds everyone deeper in your org. counts gives both sizes, " \
                         "so you can tell when more waits beyond your team. Each item carries its assignment_id; place one " \
                         "with assessments_add_evidence_link, or read its pending suggestions with " \
                         "assessments_evidence_suggestions_list.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "scope" => { "type" => "string", "enum" => [ "team", "org" ] }
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
        "description" => "Fetch one assessment's framework structure, the assessee's current role/level/cycle status, and their score on the level-independent scale (100 = meeting their current level in full) with a per-category breakdown. Each score carries the scale's own meaning, its parts and the framework's thresholds; a score the screen withholds, for lack of coverage or while an alignment is still agreeing cells (unscored_reason agreement_incomplete), reports scored: false rather than a number. Pass as_role_id and/or as_level_ordinal to read the same ratings against another role or level (a lens): scoring.lens.home is then false and it is not the assessment of record, and each capability's in_role says whether the record's role and the lens role read it. When that role has an open declared exploration, current_exploration describes it. Carried-forward ratings count as rated but are not this cycle's until confirmed: scoring.coverage.to_confirm_at_assessed_level says how many wait, and assessments_confirm_carried_ratings confirms them. current_cycle says when each milestone happened (enrolled, started, self and manager assessment complete, alignment started and completed, with who acted) and each alignment's started, aligned and re-opened times. past_cycles lists every other cycle the person joined on this framework, closed or withdrawn from, newest first, with the same lifecycle fields; pass one's id as cycle_id to read that cycle's ratings and score at its own role and level (scoring.lens.past_cycle true; the assessee sees the manager's ratings only where alignment had started, as on the open cycle). Its alignments are under role_alignments (the reporting_cycle_cohort name), with the same fields as current_cycle.alignments. Timestamps are ISO 8601 UTC and record the latest occurrence: a re-open clears aligned_at until the next completion. framework.versions lists every published version of the framework with when and by whom.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"    => { "type" => "string" },
            "as_role_id"       => { "type" => "string" },
            "as_level_ordinal" => { "type" => "integer" },
            "cycle_id"         => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S",
              "description" => "A cycle the person joined on this framework, from past_cycles. Ratings and scores are then that cycle's, at its own role and level. Omit for the open cycle."
            }
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
        "description" => "Post a comment on a capability × level of an assessment (optionally as a reply). Pass evidence_id to comment on that evidence item's linkage at the cell instead — the discussion of the feedback's relevance and valence there. " \
                         "`body` is Markdown: links, **bold**, _italic_, lists and `code` render, a bare URL becomes a link, typed HTML shows as text and images render as links.",
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
            "confirm"              => { "type" => "boolean" },
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
            "confirm"              => { "type" => "boolean" },
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
        "description" => "Recent assessment activity, most recent first (metadata only, no rating values): ratings, " \
          "evidence, comments, and alignment milestones started, completed and re-opened against any " \
          "role (role_id, role_code, role_name, home). Covers the caller and their whole org subtree; " \
          "person_id narrows to one person whose assessment the caller may view, and then alignment " \
          "milestones come from the event stream, so a completion later re-opened still appears. since " \
          "/ until (ISO 8601; a bare date is its UTC day, inclusive; a date-time needs an offset) bound " \
          "the window, applied before the limit. Ratings and alignment rows keep only each cell's or " \
          "role's latest stamp, so a window misses activity later overwritten (with person_id, " \
          "alignments are read in full from the stream). cycle_id keeps one cycle's activity (comments " \
          "carry no cycle and are left out). kinds narrows by kind; an empty list returns none. limit " \
          "defaults to 8, at most 50.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "limit" => { "type" => "integer" },
            "person_id" => { "type" => "string", "minLength" => 1, "pattern" => "\\S" },
            "since" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S",
              "description" => "ISO 8601 date-time, or a date for the start of that UTC day."
            },
            "until" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S",
              "description" => "ISO 8601 date-time, or a date for the end of that UTC day."
            },
            "cycle_id" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S",
              "description" => "An assessment cycle's id, from reporting_cycles_list."
            },
            "kinds" => {
              "type" => "array",
              "items" => {
                "type" => "string",
                "enum" => [
                  "self_rated", "manager_rated", "assessment_aligned", "evidence_recorded",
                  "comment_posted", "alignment_started", "alignment_completed", "alignment_reopened"
                ]
              },
              "description" => "Keep only these kinds of activity."
            }
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
        "description" => "Record a piece of feedback / evidence on an assessment — against a capability × level, or " \
                         "with no cell at all when you don't know which expectation it speaks to: the recipient or their " \
                         "manager places it later. Find a colleague's assignment_id with assessments_feedback_recipients. " \
                         "`content` is Markdown: links, **bold**, _italic_, lists and `code` render, a bare URL becomes a link, typed HTML shows as text and images render as links.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id"        => { "type" => "string" },
            "capability_stable_id" => { "type" => "string", "minLength" => 1, "pattern" => "\\S" },
            "level_ordinal"        => { "type" => "integer" },
            "evidence_type"        => { "type" => "string", "enum" => EvidenceItem::EVIDENCE_TYPES },
            "custom_type_label"    => { "type" => "string" },
            "title"                => { "type" => "string" },
            "content"              => { "type" => "string" },
            "valence"              => { "type" => "string", "enum" => EvidenceLink::VALENCES, "minLength" => 1, "pattern" => "\\S" },
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
          "required" => %w[assignment_id evidence_type content],
          "additionalProperties" => false,
          "allOf" => [
            custom_type_label_conditional,
            { "dependentRequired" => {
              "capability_stable_id" => %w[level_ordinal valence],
              "level_ordinal"        => [ "capability_stable_id" ],
              "valence"              => [ "capability_stable_id" ],
              "additional_links"     => [ "capability_stable_id" ]
            } }
          ]
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
        "description" => "Respond to a feedback / evidence request by providing the requested feedback. " \
                         "`content` is Markdown: links, **bold**, _italic_, lists and `code` render, a bare URL becomes a link, typed HTML shows as text and images render as links.",
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
        "name" => "assessments_timeline",
        "description" => "A person's lifecycle history on one assessment, oldest first, from their event stream: " \
          "assignment to the framework and removal from it, cycle joins, exits and conclusions, every " \
          "alignment started, completed and re-opened (per role, with role_id, role_code, role_name and " \
          "home — whether it was the role they held when they joined the cycle), role, level and " \
          "reporting-manager changes, explorations started and closed, and manager-rating delegations " \
          "granted and revoked — each with occurred_at (ISO 8601 UTC) and the actor. Unlike " \
          "assessments_get and reporting_cycle_cohort, which keep only the latest stamp, this answers " \
          "when an alignment was first completed and how often it was re-opened. Self and manager " \
          "assessment completion have no event: they appear with derived: true, at their latest " \
          "completion only. Pass cycle_id for one cycle's milestones, and kinds to narrow by kind (an " \
          "empty list returns none). Free-text reasons appear only for the manager chain and tenant admins. " \
          "Returns no rating values.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "assignment_id" => { "type" => "string" },
            "cycle_id" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S",
              "description" => "Keep only the milestones of this cycle (from reporting_cycles_list or assessments_get)."
            },
            "kinds" => {
              "type" => "array",
              "items" => {
                "type" => "string",
                "enum" => [
                  "assigned_to_framework", "unassigned_from_framework", "joined_cycle",
                  "left_cycle", "cycle_concluded", "alignment_started",
                  "alignment_completed", "alignment_reopened", "role_changed",
                  "level_changed", "reporting_manager_recorded", "exploration_started",
                  "exploration_closed", "manager_rating_delegated", "manager_rating_delegation_revoked",
                  "self_assessment_completed", "manager_assessment_completed"
                ]
              },
              "description" => "Keep only these kinds of milestone."
            }
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
        "description" => "Edit an existing feedback / evidence item's type, title, content, and external reference. " \
                         "`content` is Markdown: links, **bold**, _italic_, lists and `code` render, a bare URL becomes a link, typed HTML shows as text and images render as links.",
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
        "name" => "calibration_sessions_archive",
        "description" => "Archive a closed calibration session — hides it from the default list; nothing is deleted " \
                         "and calibration_sessions_unarchive restores it.",
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
        "description" => "List calibration sessions you facilitate (admins see all), optionally filtered to one " \
                         "assessment cycle. Archived sessions are omitted unless include_archived is true.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "cycle_id"         => { "type" => "string" },
            "include_archived" => { "type" => "boolean" }
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
        "description" => "Calibration overview for a session — readiness per rater and for the whole population (readiness.reference groups people whose rater is not in the session), as fractions of cell_total, the at-level cells: coverage_pct rated, carried_pct carried from last cycle and not yet confirmed, evidence_coverage_pct with at least one active evidence link, and ready_state (ready | to_confirm | unrated | no_cells); per-rater tendency (mean vs org, distribution, self-gap; evidence_pct is the backed share of RATED cells), capabilities ranked by tendency-corrected rater disagreement, and people grouped by assessed level, each with a per-person % of expected (100 = meeting the level, 200 = demonstrating the next level in full; manager ratings only; a coverage-gated person carries pct: null with rated/total/unlock_target — not rated yet, never a low score).",
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
        "description" => "Record a free-text minute on a live calibration session, optionally anchored to a capability or person. " \
                         "`body` is Markdown: links, **bold**, _italic_, lists and `code` render, a bare URL becomes a link, typed HTML shows as text and images render as links.",
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
        "name" => "calibration_sessions_rename",
        "description" => "Rename a calibration session (any status; the session log records the previous name).",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "session_id" => { "type" => "string" },
            "name"       => { "type" => "string", "minLength" => 1, "pattern" => "\\S" }
          },
          "required" => %w[session_id name],
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
        "name" => "calibration_sessions_unarchive",
        "description" => "Restore an archived calibration session to the default list (it stays closed). " \
                         "Only closed sessions can be archived or restored.",
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
        "description" => "Revise your own pending framework suggested edit (author only). " \
                         "`rationale` is Markdown: links, **bold**, _italic_, lists and `code` render, a bare URL becomes a link, typed HTML shows as text and images render as links.",
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
        "description" => "Approve a pending framework suggested edit (tier authority required). " \
                         "`comment` is Markdown: links, **bold**, _italic_, lists and `code` render, a bare URL becomes a link, typed HTML shows as text and images render as links.",
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
        "description" => "Comment on a framework suggestion's discussion thread (optionally as a reply). Threads stay open after the suggestion is resolved. " \
                         "`body` is Markdown: links, **bold**, _italic_, lists and `code` render, a bare URL becomes a link, typed HTML shows as text and images render as links.",
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
        "name" => "frameworks_draft_changes",
        "description" => "What publishing the open draft would change (capabilities, categories, role " \
          "bindings, levels, expectations) and how many open-cycle people each change reaches.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "framework_id" => { "type" => "string" }
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
        "name" => "frameworks_edit_suggestion_comment",
        "description" => "Revise your own comment on a framework suggestion's discussion thread (author only). " \
                         "`body` is Markdown: links, **bold**, _italic_, lists and `code` render, a bare URL becomes a link, typed HTML shows as text and images render as links.",
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
        "description" => "Fetch one framework's top-level structure (role families, categories, child IDs and names) " \
          "and every published version, newest first, with when and by whom it was published.",
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
        "description" => "Reject a pending framework suggested edit, optionally with a reason (tier authority required). " \
                         "`comment` is Markdown: links, **bold**, _italic_, lists and `code` render, a bare URL becomes a link, typed HTML shows as text and images render as links.",
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
        "description" => "Ask for clarification of a capability, one of its level expectations, or a role example (illustration) — opens a discussion, proposes nothing. " \
                         "`rationale` is Markdown: links, **bold**, _italic_, lists and `code` render, a bare URL becomes a link, typed HTML shows as text and images render as links.",
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
        "description" => "Resolve a pending clarification with a note (expectation-tier authority required). " \
                         "`note` is Markdown: links, **bold**, _italic_, lists and `code` render, a bare URL becomes a link, typed HTML shows as text and images render as links.",
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
        "description" => "Propose creating a framework entity (example, expectation, capability, category, role, role family, level) as a suggestion — pending review by default; applied directly with approval rights in editing mode. " \
                         "`rationale` is Markdown: links, **bold**, _italic_, lists and `code` render, a bare URL becomes a link, typed HTML shows as text and images render as links.",
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
        "description" => "Propose deleting a framework entity (capability or example) as a pending suggestion — nothing is removed until a reviewer approves. " \
                         "`rationale` is Markdown: links, **bold**, _italic_, lists and `code` render, a bare URL becomes a link, typed HTML shows as text and images render as links.",
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
        "description" => "Edit framework content (capability/category name or description, expectation or example text) — applied directly with approval rights in editing mode, else proposed as a suggestion; consecutive edits amend your pending proposal. " \
                         "`rationale` is Markdown: links, **bold**, _italic_, lists and `code` render, a bare URL becomes a link, typed HTML shows as text and images render as links.",
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
        "name" => "integrations_ai_model_status",
        "description" => "Show how this workspace's AI model is set up for feedback placement suggestions: whether it is " \
                         "ready (a complete provider, address and model with an API key stored; it does not prove the " \
                         "endpoint answers), the provider, the host of its address, the model id, whether suggestions are " \
                         "on, and whether a key is stored. Never returns the key. Names of people in the workspace are " \
                         "always replaced with placeholders before feedback reaches the model.",
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
        "name" => "integrations_feedback_exchange_status",
        "description" => "Show the state of this workspace's feedback exchange with a peer system: whether it is " \
                         "set up (connected means enabled with a peer and both signing secrets stored; it does not " \
                         "prove the peer answers), the peer and its address, the last sync, the types it sends and imports " \
                         "as stored (\"all\" means every type, including any added later; an empty list means none), " \
                         "the types actually sent today with \"all\" resolved, whether the secrets and sync cursors are present, and " \
                         "what the import has done: records imported, updated, withdrawn and skipped, with each skip reason " \
                         "and the people the peer named that no Person matched at the last sync. Never returns a secret.",
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
        "name" => "integrations_hand_back_hris_level",
        "description" => "Hand an Org Graph structure level back from the HRIS to Espalia, so people edit its units here again. Pass the fingerprint integrations_hris_level_handover gave for the level. Units and memberships stay as they are; successions and retirements made by the handover stand.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "level_id" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            },
            "fingerprint" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            }
          },
          "required" => [ "level_id", "fingerprint" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "integrations_hand_over_hris_level",
        "description" => "Hand an Org Graph structure level to an HRIS field, as integrations_hris_level_handover compared it. Pass the same matches and resolutions and that comparison's fingerprint; a changed HRIS or level refuses it. In one change it records the field as the level's source, gives each matched unit its value, succeeds or retires every other unit, and moves memberships to agree with the HRIS. When the comparison is over the brake, pass the memberships it ends and the units it retires as confirm_memberships_ended and confirm_units_retired, exactly as the comparison gave them.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "level_id" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            },
            "field_id" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            },
            "matches" => {
              "type" => "object",
              "additionalProperties" => {
                "type" => "string"
              }
            },
            "resolutions" => {
              "type" => "object",
              "additionalProperties" => {
                "type" => "string"
              }
            },
            "fingerprint" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            },
            "confirm_memberships_ended" => {
              "type" => "integer"
            },
            "confirm_units_retired" => {
              "type" => "integer"
            }
          },
          "required" => [ "level_id", "field_id", "matches", "fingerprint" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "integrations_hris_field_preview",
        "description" => "Preview what an HRIS field would give before choosing it as the source of an Org Graph " \
                         "level or fact. For target \"level\": the units it would create, with their labels and how " \
                         "many people fall in each, largest first. For a fact (\"cost_centre\", \"country\"): how many " \
                         "people have a value and how many would change from what the Org Graph holds now. Both count " \
                         "people the field is blank for and people whose record withholds it. Reads the HRIS live; " \
                         "writes nothing.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "field_id" => { "type" => "string", "minLength" => 1, "pattern" => "\\S" },
            "target"   => { "type" => "string", "enum" => %w[level cost_centre country] }
          },
          "required" => %w[field_id target],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true
        }
      },
      {
        "name" => "integrations_hris_level_handover",
        "description" => "Compare an Org Graph structure level with an HRIS field before handing the level to the HRIS. Each unit gets a suggested value by name, never a match: pass the values a person confirmed in matches (unit id => value key), and for each unit left over a resolution (unit id => a matched unit's id to succeed into, or \"retire\"). Returns the units, the field's values, how many people differ, are blank, were added by hand or would join, the units still unresolved, the counts the brake weighs, and a fingerprint integrations_hand_over_hris_level needs. For a level the HRIS already supplies, says what handing it back would keep, with its fingerprint. Reads the HRIS live; writes nothing.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "level_id" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            },
            "field_id" => {
              "type" => "string"
            },
            "matches" => {
              "type" => "object",
              "additionalProperties" => {
                "type" => "string"
              }
            },
            "resolutions" => {
              "type" => "object",
              "additionalProperties" => {
                "type" => "string"
              }
            }
          },
          "required" => [ "level_id" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true
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
        "name" => "org_graph_add_member",
        "description" => "Place a person in a live unit of the Org Graph, from effective_on (today by default), with " \
                         "an optional role and allocation (greater than 0, at most 1). A person can be in several " \
                         "units. A unit an HRIS supplies takes only people that HRIS doesn't hold; place the others " \
                         "in the HRIS. Someone already in the unit is refused.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "effective_on" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            },
            "unit_id" => {
              "type" => "string"
            },
            "person_id" => {
              "type" => "string"
            },
            "role" => {
              "type" => "string"
            },
            "allocation" => {
              "type" => "number"
            }
          },
          "required" => [ "unit_id", "person_id" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "org_graph_add_unit_owner",
        "description" => "Name a person as an owner of a live unit in the Org Graph, from effective_on (today by " \
                         "default). An owner may change the unit and every unit beneath it, so this grants " \
                         "permissions. Units an HRIS supplies take owners too.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "effective_on" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            },
            "unit_id" => {
              "type" => "string"
            },
            "person_id" => {
              "type" => "string"
            }
          },
          "required" => [ "unit_id", "person_id" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "org_graph_as_of",
        "description" => "Read the Org Graph as it stood on one UTC date: the live units with their parent, " \
          "level, owners and direct member count, and the number of employed people. A future " \
          "date includes changes already recorded for it, such as a hire who starts then or a " \
          "scheduled move. known_on reads what the Org Graph knew at 23:59:59 UTC on that " \
          "earlier date, not in the tenant's local time, leaving out corrections learned " \
          "since. mode \"full\" adds each employed " \
          "person's facts (title, level, manager, site, employment) and every membership. " \
          "unit_id narrows to that unit and the units under it, counting only the people " \
          "placed there. People are named by id only.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "date" => { "type" => "string", "minLength" => 1, "pattern" => "^[0-9]{4}-[0-9]{2}-[0-9]{2}$",
                        "description" => "UTC date, YYYY-MM-DD." },
            "known_on" => { "type" => "string", "minLength" => 1, "pattern" => "^[0-9]{4}-[0-9]{2}-[0-9]{2}$",
                            "description" => "UTC date, YYYY-MM-DD. Omit for what is known now." },
            "mode" => { "type" => "string", "enum" => %w[summary full] },
            "unit_id" => { "type" => "string", "minLength" => 1, "pattern" => "\\S", "format" => "uuid" }
          },
          "required" => %w[date],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true
        }
      },
      {
        "name" => "org_graph_changes_between",
        "description" => "What changed in the Org Graph between two UTC dates: joiners (with every fact and " \
          "membership and the units they own on their first day), leavers, person " \
          "fact changes (title, level, manager, cost centre, site, employment), memberships " \
          "started, ended or changed, moves between units, and units created, renamed, moved, " \
          "retired, succeeded or re-owned. by \"effective\" (the default) lists what took " \
          "effect after from, up to and including to; known_on reads what the Org Graph knew " \
          "at 23:59:59 UTC on that date, not in the tenant's local time. by \"learned\" lists " \
          "what the Org Graph learned after 23:59:59 UTC on from, up to 23:59:59 UTC on to, " \
          "whatever date it took effect, so backdated corrections show, and a change it " \
          "no longer believes comes back withdrawn. A change's effective_on is the first day " \
          "it holds, so a leaving dated 30 April shows on 1 May. Defaults to a count per kind, " \
          "with withdrawn changes counted apart; mode \"full\" lists every change. People are " \
          "named by id only.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "from" => { "type" => "string", "minLength" => 1, "pattern" => "^[0-9]{4}-[0-9]{2}-[0-9]{2}$",
                        "description" => "UTC date, YYYY-MM-DD. The day before the window opens." },
            "to" => { "type" => "string", "minLength" => 1, "pattern" => "^[0-9]{4}-[0-9]{2}-[0-9]{2}$",
                      "description" => "UTC date, YYYY-MM-DD. The window's last day." },
            "by" => { "type" => "string", "enum" => %w[effective learned] },
            "known_on" => { "type" => "string", "minLength" => 1, "pattern" => "^[0-9]{4}-[0-9]{2}-[0-9]{2}$",
                            "description" => "UTC date, YYYY-MM-DD. By effective date only; omit for what is known now." },
            "mode" => { "type" => "string", "enum" => %w[summary full] }
          },
          "required" => %w[from to],
          "additionalProperties" => false,
          "if" => { "properties" => { "by" => { "const" => "learned" } }, "required" => %w[by] },
          "then" => { "not" => { "required" => %w[known_on] } }
        },
        "annotations" => {
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true
        }
      },
      {
        "name" => "org_graph_merge_unit",
        "description" => "Merge a unit into another live unit from effective_on (today by default). Every membership moves to into_unit_id, keeping its role and allocation, and unit_id retires, all under one cause. A unit with live sub-units is refused, as is either unit when an HRIS supplies it. The caller must be able to change both units.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "effective_on" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            },
            "unit_id" => {
              "type" => "string"
            },
            "into_unit_id" => {
              "type" => "string"
            }
          },
          "required" => [ "unit_id", "into_unit_id" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "org_graph_move_member",
        "description" => "Move a person's membership of one unit to another live unit, keeping its role and " \
                         "allocation, from effective_on (today by default). A membership an HRIS supplies moves in " \
                         "the HRIS, not here.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "effective_on" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            },
            "person_id" => {
              "type" => "string"
            },
            "from_unit_id" => {
              "type" => "string"
            },
            "unit_id" => {
              "type" => "string"
            }
          },
          "required" => [ "person_id", "from_unit_id", "unit_id" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "org_graph_move_unit",
        "description" => "Move a unit in the Org Graph beneath another live unit at a higher level, or to the top " \
                         "when parent_id is omitted, from effective_on (today by default). Only a unit Espalia holds " \
                         "can be moved here. Moving a unit changes who inherits its ownership, so the caller needs " \
                         "rights on the unit and where it lands.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "effective_on" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            },
            "unit_id" => {
              "type" => "string"
            },
            "parent_id" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            }
          },
          "required" => [ "unit_id" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "org_graph_person_get",
        "description" => "Read one person as the Org Graph holds them: their memberships of live units (unit, role, " \
                         "allocation, since, and the provider that holds each, \"espalia\" or an HRIS), their employment " \
                         "facts in effect today (title, level, manager, cost centre, site, employment, start date), each " \
                         "with its provider and since when, and their history newest first: each change with the day it " \
                         "took effect, when the Org Graph learned it, its provider and who made it. A forgotten person " \
                         "reads as \"Former member\". Admins only while the Org Graph is unfinished.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "person_id" => {
              "type" => "string"
            }
          },
          "required" => [ "person_id" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true
        }
      },
      {
        "name" => "org_graph_remove_member",
        "description" => "End a person's membership of a unit in the Org Graph; effective_on (today by default) is " \
                         "their last day in it. A membership an HRIS supplies ends in the HRIS, not here.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "effective_on" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            },
            "person_id" => {
              "type" => "string"
            },
            "unit_id" => {
              "type" => "string"
            }
          },
          "required" => [ "person_id", "unit_id" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "org_graph_remove_unit_owner",
        "description" => "Remove a person from a live unit's owners in the Org Graph, from effective_on (today by " \
                         "default). This takes away their rights over the unit and the units beneath it.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "effective_on" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            },
            "unit_id" => {
              "type" => "string"
            },
            "person_id" => {
              "type" => "string"
            }
          },
          "required" => [ "unit_id", "person_id" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "org_graph_rename_unit",
        "description" => "Rename a unit in the Org Graph, from effective_on (today by default). Only a unit Espalia " \
                         "holds can be renamed here; one an HRIS supplies is renamed in the HRIS. Refused unless the " \
                         "caller is a tenant admin, an Org Graph editor or an owner of the unit or a unit above it.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "effective_on" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            },
            "unit_id" => {
              "type" => "string"
            },
            "name" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            }
          },
          "required" => [ "unit_id", "name" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "org_graph_retire_unit",
        "description" => "Retire a unit in the Org Graph from effective_on (today by default), ending every membership in it, so its people show as in no team. A unit with live sub-units is refused until they are moved or retired, and one an HRIS supplies is retired in the HRIS. Refused unless the caller is a tenant admin, an Org Graph editor or an owner of the unit or a unit above it.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "effective_on" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            },
            "unit_id" => {
              "type" => "string"
            }
          },
          "required" => [ "unit_id" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "org_graph_split_unit",
        "description" => "Split a unit into two or more new units from effective_on (today by default). The successors take the unit's level and parent. Each person placements names moves to their successor with the same role and allocation; anyone not named leaves and shows as in no team. The unit retires, and everything shares one cause. A unit with live sub-units, or one an HRIS supplies, is refused.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "effective_on" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "\\S"
            },
            "unit_id" => {
              "type" => "string"
            },
            "successor_names" => {
              "type" => "array",
              "items" => {
                "type" => "string"
              },
              "minItems" => 2,
              "description" => "names of the new units, at least two, each different"
            },
            "placements" => {
              "type" => "object",
              "additionalProperties" => {
                "type" => "string"
              },
              "description" => "person_id => the name of the successor they move to, one of successor_names. Members left out end their membership and show as in no team."
            }
          },
          "required" => [ "unit_id", "successor_names" ],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "org_graph_units",
        "description" => "List the Org Graph's live units in tree order, the order the Units page shows them: each " \
                         "with its id, name, level, parent, the provider that holds it (\"espalia\" or an HRIS), its " \
                         "head count (distinct people in it and every unit beneath it) and the person ids of its own " \
                         "members. Also returns the taxonomy levels, top first, and the ids of active people in no live " \
                         "unit. Admins only while the Org Graph is unfinished.",
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
        "name" => "reporting_capability_attainment",
        "description" => "Aggregate capability attainment for an assessment cycle across the caller's " \
          "org subtree (admins see the whole cycle): per role and role family, the share " \
          "of people at or above their assessed level on each capability with assessed " \
          "coverage, plus the share passing each category gate. Returns aggregates only " \
          "— never individual ratings.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "cycle_id" => { "type" => "string", "description" => "An assessment cycle's id, from reporting_cycles_list." },
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
          "counts, at-risk count, the cycle's opened/closed times and the median days from " \
          "enrolment to alignment. In full mode, grouped breakdowns and per-participant " \
          "progress with when each milestone happened (enrolled, self and manager assessment " \
          "complete, alignment started and completed, with who acted) and every role " \
          "alignment, including re-opens. Timestamps are ISO 8601 UTC and record the LATEST " \
          "occurrence: a re-open clears aligned_at until the next completion. The self/manager " \
          "completion stamps update on rating events only, so after a role or framework " \
          "change they can disagree with self_done / manager_done until the next rating. " \
          "aligned_from / aligned_to (full mode only, UTC dates, inclusive) narrow the " \
          "participant list to those with an alignment, against any role, completed in that " \
          "window. Returns no rating values.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "cycle_id" => { "type" => "string", "description" => "An assessment cycle's id, from reporting_cycles_list." },
            "mode" => { "type" => "string", "enum" => [ "summary", "full" ] },
            "scope" => { "type" => "string", "enum" => [ "mine", "all" ] },
            "aligned_from" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "^[0-9]{4}-[0-9]{2}-[0-9]{2}$",
              "description" => "UTC date, YYYY-MM-DD. Full mode only."
            },
            "aligned_to" => {
              "type" => "string",
              "minLength" => 1,
              "pattern" => "^[0-9]{4}-[0-9]{2}-[0-9]{2}$",
              "description" => "UTC date, YYYY-MM-DD, inclusive. Full mode only."
            }
          },
          "required" => [ "cycle_id" ],
          "additionalProperties" => false,
          "allOf" => [
            {
              "if" => { "properties" => { "mode" => { "const" => "summary" } }, "required" => [ "mode" ] },
              "then" => { "not" => { "required" => [ "aligned_from" ] } }
            },
            {
              "if" => { "properties" => { "mode" => { "const" => "summary" } }, "required" => [ "mode" ] },
              "then" => { "not" => { "required" => [ "aligned_to" ] } }
            },
            { "dependentRequired" => { "aligned_from" => [ "mode" ], "aligned_to" => [ "mode" ] } }
          ]
        },
        "annotations" => {
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true
        }
      },
      {
        "name" => "reporting_cycles_list",
        "description" => "List the assessment cycles the caller can report on, newest first, with their " \
          "status, opened / planned end / closed dates, framework and version range, and " \
          "participant count. Admins see every cycle (scope: \"mine\" narrows to their own " \
          "org subtree); a manager sees the cycles with someone from their subtree enrolled, " \
          "and counts only that subtree. A listed id works with reporting_cycle_cohort, " \
          "reporting_capability_attainment and reporting_evidence_coverage; " \
          "reporting_feedback_export is for tenant admins only.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "status" => { "type" => "string", "enum" => [ "open", "closed" ] },
            "framework_id" => { "type" => "string", "minLength" => 1, "pattern" => "\\S", "format" => "uuid" },
            "scope" => { "type" => "string", "enum" => [ "mine", "all" ] }
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
        "name" => "reporting_evidence_coverage",
        "description" => "Aggregate feedback and evidence-request coverage for an assessment cycle " \
          "across the caller's org subtree (admins see the whole cycle): feedback " \
          "provided by request or as proactive feedback, immutable manager/report/peer directionality, " \
          "withdrawn feedback, where it was given (by_origin: the stable key 'growthos' for feedback given here — labelled with the tenant's product name — or the system it arrived from), " \
          "request statuses, fulfilment rate, participant coverage, " \
          "and optional manager/role/level groups. Pass month (YYYY-MM) to narrow to feedback " \
          "recorded and requests sent in one calendar month of the cycle; the response lists " \
          "the months available.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "cycle_id" => { "type" => "string", "description" => "An assessment cycle's id, from reporting_cycles_list." },
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
          "direction, requested or proactive (a request made here), where it was given (origin) and the request " \
          "it answered there, type, title, the feedback text, the behaviours it applies to, and status. " \
          "The rows match the feedback the cycle's coverage report counts as provided; include_withdrawn " \
          "adds the withdrawn items it reports separately. Pass month (YYYY-MM) to narrow to feedback " \
          "recorded in one calendar month. The response carries every row's full text, " \
          "so a month is far smaller than a whole cycle; for counts alone use reporting_evidence_coverage.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "cycle_id" => { "type" => "string", "minLength" => 1, "pattern" => "\\S", "description" => "An assessment cycle's id, from reporting_cycles_list." },
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
        "name" => "tenants_disable_scheduled_forgetting",
        "description" => "Turn off scheduled forgetting for the active tenant. Anyone already forgotten stays forgotten.",
        "inputSchema" => { "type" => "object", "properties" => {}, "required" => [], "additionalProperties" => false },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "tenants_enable_scheduled_forgetting",
        "description" => "Turn on scheduled forgetting for the active tenant. Pass confirm_count, the count " \
                         "tenants_forgetting_dry_run gives now; the call is refused if it differs.",
        "inputSchema" => {
          "type" => "object",
          "properties" => { "confirm_count" => { "type" => "integer" } },
          "required" => %w[confirm_count],
          "additionalProperties" => false
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
        }
      },
      {
        "name" => "tenants_forgetting_dry_run",
        "description" => "Count the leavers the active tenant would forget today, after checking the HRIS, " \
                         "and list their person ids. Erases nothing. reason, why you ask, is recorded and " \
                         "doesn't change the answer.",
        "inputSchema" => {
          "type" => "object",
          "properties" => { "reason" => { "type" => "string", "enum" => %w[retention request] } },
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
        "name" => "tenants_update_retention_period",
        "description" => "Set how many years after a person leaves the active tenant forgets their identifiers " \
                         "(default 7), or never forget them.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "retention_years" => { "type" => "integer" },
            "never" => { "type" => "boolean" }
          },
          "required" => [],
          "additionalProperties" => false,
          "if" => { "properties" => { "never" => { "const" => true } }, "required" => [ "never" ] },
          "then" => { "not" => { "required" => [ "retention_years" ] } }
        },
        "annotations" => {
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false
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
        "description" => "Update the active tenant's theme: default, bento, or custom with its own " \
                         "colour-role values (light and dark hex) and Google font. custom_theme merges " \
                         "per role; a blank value restores the default for that role. product_name is " \
                         "what this tenant calls the platform; blank restores the instance default. " \
                         "custom_domain is the tenant's own sign-in host (domain or subdomain); blank clears it.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "theme"         => { "type" => "string", "enum" => %w[default bento custom] },
            "custom_theme"  => custom_theme_schema,
            "font_family"   => { "type" => "string" },
            "product_name"  => { "type" => "string" },
            "custom_domain" => { "type" => "string" }
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

  # A Custom theme's role values: one object per role with a --tenant-* hook
  # in roles.css, each taking a light and a dark hex (or blank, to clear it).
  def custom_theme_schema
    hex = { "type" => "string", "pattern" => "^#[0-9a-fA-F]{6}$|^$" }
    role = { "type" => "object", "properties" => { "light" => hex, "dark" => hex }, "additionalProperties" => false }
    { "type" => "object", "properties" => { "brand" => role, "nav-surface" => role }, "additionalProperties" => false }
  end

  # The published JSON Schema for an evidence item's external_reference,
  # shared by every evidence-write tool's snapshot. Mirrors
  # ExternalReference.json_schema (deep-stringified) so clients see the
  # accepted keys + the known systems instead of a bare free-form object.
  def external_reference_schema
    {
      "type" => "object",
      "description" => "Optional pointer to a supporting source in an external system.",
      "properties" => {
        "system"      => { "type" => "string", "pattern" => "^[a-z0-9]+(?:[_-][a-z0-9]+)*$",
                           "examples" => ExternalReference::KNOWN_SYSTEMS,
                           "description" => "Originating system, as a lowercase slug." },
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
