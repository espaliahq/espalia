# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_16_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "assessment_cycle_enrollments", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "concluded_at"
    t.datetime "created_at", null: false
    t.uuid "cycle_id", null: false
    t.datetime "enrolled_at", null: false
    t.uuid "level_id"
    t.integer "level_ordinal"
    t.uuid "person_id", null: false
    t.uuid "role_id"
    t.string "status", default: "enrolled", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.string "withdrawal_reason"
    t.datetime "withdrawn_at"
    t.index ["cycle_id", "person_id"], name: "idx_assessment_cycle_enrollments_unique", unique: true
    t.index ["tenant_id", "person_id", "status"], name: "idx_assessment_cycle_enrollments_by_person_status"
    t.index ["tenant_id"], name: "index_assessment_cycle_enrollments_on_tenant_id"
  end

  create_table "assessment_cycle_progress", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "aligned_at"
    t.uuid "aligned_by_id"
    t.integer "aligned_framework_version"
    t.datetime "alignment_started_at"
    t.uuid "alignment_started_by_id"
    t.datetime "created_at", null: false
    t.uuid "cycle_id", null: false
    t.datetime "manager_completed_at"
    t.uuid "person_id", null: false
    t.datetime "self_completed_at"
    t.datetime "started_at"
    t.string "status", default: "in_progress", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["aligned_by_id"], name: "idx_assessment_cycle_progress_aligned_by_id", where: "(aligned_by_id IS NOT NULL)"
    t.index ["alignment_started_by_id"], name: "idx_assessment_cycle_progress_alignment_started_by_id", where: "(alignment_started_by_id IS NOT NULL)"
    t.index ["cycle_id", "person_id"], name: "idx_assessment_cycle_progress_unique", unique: true
    t.index ["tenant_id", "person_id", "status"], name: "idx_assessment_cycle_progress_by_person_status"
    t.index ["tenant_id"], name: "index_assessment_cycle_progress_on_tenant_id"
  end

  create_table "assessment_cycles", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "closed_at"
    t.datetime "created_at", null: false
    t.uuid "cycle_id", null: false
    t.string "cycle_type", null: false
    t.uuid "defined_by"
    t.uuid "framework_id", null: false
    t.integer "framework_version", null: false
    t.integer "latest_framework_version", null: false
    t.string "name", null: false
    t.datetime "opened_at", null: false
    t.date "planned_end_at"
    t.string "status", default: "open", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "cycle_id"], name: "idx_assessment_cycles_unique_cycle_id", unique: true
    t.index ["tenant_id", "framework_id"], name: "idx_assessment_cycles_by_framework"
    t.index ["tenant_id", "framework_id"], name: "idx_assessment_cycles_one_open_per_framework", unique: true, where: "((status)::text = 'open'::text)"
    t.index ["tenant_id"], name: "index_assessment_cycles_on_tenant_id"
  end

  create_table "assessment_level_ratings", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "aligned_by_id"
    t.text "aligned_comment"
    t.string "aligned_frequency"
    t.uuid "capability_stable_id", null: false
    t.datetime "created_at", null: false
    t.uuid "cycle_id", null: false
    t.uuid "framework_id", null: false
    t.datetime "last_aligned_at"
    t.datetime "last_manager_rated_at"
    t.datetime "last_self_rated_at"
    t.integer "level_ordinal", null: false
    t.uuid "manager_rated_by_id"
    t.text "manager_rated_comment"
    t.string "manager_rated_frequency"
    t.string "manager_rating_source"
    t.string "migration_status", default: "not_flagged", null: false
    t.uuid "person_id", null: false
    t.text "reassessment_reason"
    t.uuid "seeded_from_cycle_id"
    t.text "self_rated_comment"
    t.string "self_rated_frequency"
    t.string "self_rating_source"
    t.string "source", default: "human", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["cycle_id", "person_id", "framework_id", "capability_stable_id", "level_ordinal"], name: "idx_assessment_ratings_cycle_person_cap_level", unique: true
    t.index ["cycle_id", "person_id"], name: "idx_assessment_ratings_cycle_person"
    t.index ["person_id", "framework_id"], name: "index_assessment_level_ratings_on_person_id_and_framework_id"
    t.index ["seeded_from_cycle_id"], name: "idx_assessment_ratings_seeded_from_cycle_id", where: "(seeded_from_cycle_id IS NOT NULL)"
    t.index ["tenant_id"], name: "index_assessment_level_ratings_on_tenant_id"
  end

  create_table "calibration_session_members", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "added_by"
    t.datetime "created_at", null: false
    t.string "member_type", null: false
    t.uuid "person_id", null: false
    t.uuid "session_id", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["person_id"], name: "index_calibration_session_members_on_person_id"
    t.index ["session_id", "member_type"], name: "idx_on_session_id_member_type_9b43d58e4d"
    t.index ["session_id", "person_id"], name: "index_calibration_session_members_on_session_id_and_person_id", unique: true
    t.index ["tenant_id"], name: "index_calibration_session_members_on_tenant_id"
  end

  create_table "calibration_sessions", id: :uuid, default: nil, force: :cascade do |t|
    t.string "close_reason"
    t.datetime "closed_at"
    t.uuid "closed_by_id"
    t.datetime "created_at", null: false
    t.uuid "cycle_id", null: false
    t.uuid "defined_by"
    t.uuid "facilitator_id", null: false
    t.uuid "framework_id", null: false
    t.integer "framework_version"
    t.string "name", null: false
    t.datetime "started_at"
    t.uuid "started_by_id"
    t.string "status", default: "draft", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["facilitator_id"], name: "index_calibration_sessions_on_facilitator_id"
    t.index ["status"], name: "index_calibration_sessions_on_status"
    t.index ["tenant_id", "cycle_id"], name: "index_calibration_sessions_on_tenant_id_and_cycle_id"
    t.index ["tenant_id"], name: "index_calibration_sessions_on_tenant_id"
  end

  create_table "event_store_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.binary "data", null: false
    t.uuid "event_id", null: false
    t.string "event_type", null: false
    t.binary "metadata"
    t.datetime "valid_at"
    t.index ["created_at"], name: "index_event_store_events_on_created_at"
    t.index ["event_id"], name: "index_event_store_events_on_event_id", unique: true
    t.index ["event_type"], name: "index_event_store_events_on_event_type"
    t.index ["valid_at"], name: "index_event_store_events_on_valid_at"
  end

  create_table "event_store_events_in_streams", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "event_id", null: false
    t.integer "position"
    t.string "stream", null: false
    t.index ["created_at"], name: "index_event_store_events_in_streams_on_created_at"
    t.index ["event_id"], name: "index_event_store_events_in_streams_on_event_id"
    t.index ["stream", "event_id"], name: "index_event_store_events_in_streams_on_stream_and_event_id", unique: true
    t.index ["stream", "position"], name: "index_event_store_events_in_streams_on_stream_and_position", unique: true
  end

  create_table "evidence_items", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "author_id", null: false
    t.uuid "capability_stable_id", null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.string "custom_type_label"
    t.uuid "cycle_id"
    t.datetime "edited_at"
    t.uuid "edited_by_id"
    t.string "evidence_type", null: false
    t.jsonb "external_reference", default: {}, null: false
    t.string "feedback_direction"
    t.uuid "framework_id", null: false
    t.integer "level_ordinal", null: false
    t.string "link_status", default: "active", null: false
    t.uuid "person_id", null: false
    t.datetime "recorded_at", null: false
    t.string "source", null: false
    t.uuid "tenant_id", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.text "withdrawal_reason"
    t.datetime "withdrawn_at"
    t.uuid "withdrawn_by_id"
    t.index ["author_id"], name: "index_evidence_items_on_author_id"
    t.index ["edited_by_id"], name: "idx_evidence_items_edited_by_id", where: "(edited_by_id IS NOT NULL)"
    t.index ["person_id", "framework_id", "capability_stable_id", "level_ordinal"], name: "idx_evidence_items_anchor"
    t.index ["tenant_id", "cycle_id", "person_id"], name: "idx_evidence_items_tenant_cycle_person"
    t.index ["tenant_id", "person_id", "link_status"], name: "idx_evidence_items_tenant_person_status"
    t.index ["tenant_id"], name: "index_evidence_items_on_tenant_id"
    t.index ["withdrawn_by_id"], name: "idx_evidence_items_withdrawn_by_id", where: "(withdrawn_by_id IS NOT NULL)"
  end

  create_table "evidence_links", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "capability_stable_id", null: false
    t.datetime "created_at", null: false
    t.uuid "evidence_id", null: false
    t.uuid "framework_id", null: false
    t.integer "level_ordinal", null: false
    t.string "link_status", default: "active", null: false
    t.datetime "linked_at", null: false
    t.uuid "linked_by_id"
    t.uuid "person_id", null: false
    t.text "removal_reason"
    t.datetime "removed_at"
    t.uuid "removed_by_id"
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.string "valence"
    t.index ["evidence_id", "capability_stable_id", "level_ordinal"], name: "idx_evidence_links_natural_key", unique: true
    t.index ["evidence_id"], name: "index_evidence_links_on_evidence_id"
    t.index ["person_id", "framework_id", "capability_stable_id", "level_ordinal", "link_status"], name: "idx_evidence_links_anchor"
    t.index ["tenant_id"], name: "index_evidence_links_on_tenant_id"
  end

  create_table "evidence_requests", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "cancelled_at"
    t.uuid "capability_stable_id", null: false
    t.datetime "created_at", null: false
    t.uuid "cycle_id"
    t.text "decline_reason"
    t.datetime "declined_at"
    t.datetime "due_at"
    t.datetime "due_soon_reminded_at"
    t.uuid "evidence_id"
    t.uuid "framework_id", null: false
    t.datetime "last_reminded_at"
    t.integer "level_ordinal", null: false
    t.text "message"
    t.datetime "no_response_reminded_at"
    t.uuid "person_id", null: false
    t.jsonb "reminder_history", default: [], null: false
    t.datetime "requested_at", null: false
    t.uuid "requested_by_id", null: false
    t.uuid "requestee_person_id", null: false
    t.datetime "responded_at"
    t.string "status", default: "pending", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["person_id", "framework_id"], name: "index_evidence_requests_on_person_id_and_framework_id"
    t.index ["requested_by_id"], name: "index_evidence_requests_on_requested_by_id"
    t.index ["requestee_person_id"], name: "index_evidence_requests_on_requestee_person_id"
    t.index ["status", "requested_at"], name: "index_evidence_requests_on_status_and_requested_at"
    t.index ["status"], name: "index_evidence_requests_on_status"
    t.index ["tenant_id", "cycle_id", "person_id"], name: "idx_evidence_requests_tenant_cycle_person"
    t.index ["tenant_id"], name: "index_evidence_requests_on_tenant_id"
  end

  create_table "framework_behavioural_expectations", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "capability_id", null: false
    t.datetime "created_at", null: false
    t.text "description", null: false
    t.uuid "expectation_id", null: false
    t.integer "level_ordinal", null: false
    t.uuid "stable_id", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "capability_id", "level_ordinal"], name: "idx_fw_behav_expectations_on_tenant_cap_level", unique: true
    t.index ["tenant_id", "expectation_id"], name: "idx_fw_behav_expectations_on_tenant_and_expectation", unique: true
    t.index ["tenant_id"], name: "index_framework_behavioural_expectations_on_tenant_id"
  end

  create_table "framework_capabilities", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "capability_id", null: false
    t.uuid "category_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.integer "ordinal"
    t.uuid "stable_id", null: false
    t.string "status", default: "active", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "capability_id"], name: "index_framework_capabilities_on_tenant_id_and_capability_id", unique: true
    t.index ["tenant_id", "stable_id"], name: "index_framework_capabilities_on_tenant_id_and_stable_id"
    t.index ["tenant_id"], name: "index_framework_capabilities_on_tenant_id"
  end

  create_table "framework_capability_categories", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "category_id", null: false
    t.datetime "created_at", null: false
    t.decimal "deficit_threshold", precision: 5, scale: 2
    t.text "description"
    t.uuid "framework_id", null: false
    t.string "name", null: false
    t.integer "ordinal"
    t.integer "overperformance_cap"
    t.string "status", default: "active", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "category_id"], name: "idx_fw_cap_categories_on_tenant_and_category", unique: true
    t.index ["tenant_id"], name: "index_framework_capability_categories_on_tenant_id"
  end

  create_table "framework_capability_role_bindings", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "binding_id", null: false
    t.uuid "capability_id", null: false
    t.datetime "created_at", null: false
    t.decimal "deficit_threshold", precision: 5, scale: 2
    t.integer "overperformance_cap"
    t.uuid "role_id", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.decimal "weight", precision: 5, scale: 2, default: "1.0", null: false
    t.index ["tenant_id", "binding_id"], name: "idx_fw_cap_role_bindings_on_tenant_and_binding", unique: true
    t.index ["tenant_id", "capability_id", "role_id"], name: "idx_fw_cap_role_bindings_on_tenant_cap_role", unique: true
    t.index ["tenant_id"], name: "index_framework_capability_role_bindings_on_tenant_id"
  end

  create_table "framework_collaborators", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "framework_id", null: false
    t.uuid "person_id", null: false
    t.string "role", null: false
    t.uuid "scope_id"
    t.string "scope_type"
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["framework_id", "person_id", "role", "scope_type", "scope_id"], name: "idx_framework_collaborators_scoped_unique", unique: true, where: "((scope_type IS NOT NULL) AND (scope_id IS NOT NULL))"
    t.index ["framework_id", "person_id", "role"], name: "idx_framework_collaborators_unscoped_unique", unique: true, where: "((scope_type IS NULL) AND (scope_id IS NULL))"
    t.index ["framework_id", "person_id"], name: "index_framework_collaborators_on_framework_id_and_person_id"
    t.index ["person_id"], name: "index_framework_collaborators_on_person_id"
    t.index ["tenant_id"], name: "index_framework_collaborators_on_tenant_id"
    t.check_constraint "(scope_type IS NULL) = (scope_id IS NULL)", name: "chk_framework_collaborators_scope_consistency"
  end

  create_table "framework_explorer_graphs", primary_key: "framework_id", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "format_version", default: 1, null: false
    t.jsonb "graph_data", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id"], name: "index_framework_explorer_graphs_on_tenant_id"
  end

  create_table "framework_levels", id: :uuid, default: nil, force: :cascade do |t|
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.boolean "is_entry", default: false, null: false
    t.uuid "level_id", null: false
    t.integer "ordinal", null: false
    t.uuid "role_id", null: false
    t.uuid "tenant_id", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "level_id"], name: "index_framework_levels_on_tenant_id_and_level_id", unique: true
    t.index ["tenant_id", "role_id", "ordinal"], name: "index_framework_levels_on_tenant_id_and_role_id_and_ordinal", unique: true
    t.index ["tenant_id"], name: "index_framework_levels_on_tenant_id"
  end

  create_table "framework_migration_mappings", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "framework_id", null: false
    t.uuid "from_stable_id"
    t.uuid "mapping_id", null: false
    t.string "mapping_type", null: false
    t.integer "published_version", null: false
    t.string "reason"
    t.boolean "requires_reassessment", default: false, null: false
    t.uuid "tenant_id", null: false
    t.uuid "to_stable_id"
    t.datetime "updated_at", null: false
    t.index ["framework_id", "published_version"], name: "idx_on_framework_id_published_version_db5c09f0b2"
    t.index ["mapping_id"], name: "index_framework_migration_mappings_on_mapping_id", unique: true
    t.index ["tenant_id"], name: "index_framework_migration_mappings_on_tenant_id"
  end

  create_table "framework_publications", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "draft_version", null: false
    t.text "error_message"
    t.datetime "finished_at"
    t.uuid "framework_id", null: false
    t.string "job_id"
    t.integer "published_version"
    t.uuid "requested_by_id", null: false
    t.datetime "started_at"
    t.integer "status", default: 0, null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["framework_id", "created_at"], name: "index_framework_publications_on_framework_id_and_created_at"
    t.index ["framework_id"], name: "idx_framework_publications_one_in_flight", unique: true, where: "(finished_at IS NULL)"
    t.index ["requested_by_id"], name: "index_framework_publications_on_requested_by_id"
    t.index ["tenant_id"], name: "index_framework_publications_on_tenant_id"
  end

  create_table "framework_role_families", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "department"
    t.text "description"
    t.uuid "framework_id", null: false
    t.string "name", null: false
    t.uuid "role_family_id", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "framework_id"], name: "index_framework_role_families_on_tenant_id_and_framework_id"
    t.index ["tenant_id", "role_family_id"], name: "index_framework_role_families_on_tenant_id_and_role_family_id", unique: true
    t.index ["tenant_id"], name: "index_framework_role_families_on_tenant_id"
  end

  create_table "framework_role_illustrations", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description", null: false
    t.uuid "expectation_id", null: false
    t.uuid "illustration_id", null: false
    t.integer "ordinal", null: false
    t.uuid "role_id", null: false
    t.uuid "stable_id", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "expectation_id", "role_id"], name: "idx_fw_role_illustrations_on_tenant_exp_role"
    t.index ["tenant_id", "illustration_id"], name: "idx_fw_role_illustrations_on_tenant_and_illustration", unique: true
    t.index ["tenant_id"], name: "index_framework_role_illustrations_on_tenant_id"
  end

  create_table "framework_roles", id: :uuid, default: nil, force: :cascade do |t|
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.uuid "role_family_id", null: false
    t.uuid "role_id", null: false
    t.uuid "tenant_id", null: false
    t.string "track", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "role_id"], name: "index_framework_roles_on_tenant_id_and_role_id", unique: true
    t.index ["tenant_id"], name: "index_framework_roles_on_tenant_id"
  end

  create_table "framework_states", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "current_published_version", default: 0, null: false
    t.decimal "deficit_threshold", precision: 5, scale: 2, default: "0.75", null: false
    t.boolean "draft_in_progress", default: false, null: false
    t.integer "draft_version"
    t.uuid "framework_id", null: false
    t.decimal "mastery_threshold", precision: 5, scale: 2
    t.decimal "meeting_expectation_threshold", precision: 5, scale: 2
    t.string "name", null: false
    t.integer "overperformance_cap", default: 1, null: false
    t.uuid "tenant_id", null: false
    t.decimal "underperforming_threshold", precision: 5, scale: 2
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "framework_id"], name: "index_framework_states_on_tenant_id_and_framework_id", unique: true
    t.index ["tenant_id"], name: "index_framework_states_on_tenant_id"
  end

  create_table "framework_suggested_edits", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "author_id", null: false
    t.datetime "created_at", null: false
    t.text "current_value"
    t.string "field"
    t.uuid "framework_id", null: false
    t.string "kind", default: "edit", null: false
    t.uuid "parent_id"
    t.jsonb "proposed_attributes", default: {}, null: false
    t.text "rationale"
    t.uuid "resulting_suggestion_id"
    t.datetime "reviewed_at"
    t.uuid "reviewed_by"
    t.text "reviewer_comment"
    t.string "status", default: "pending", null: false
    t.text "suggested_value"
    t.uuid "suggestion_id", null: false
    t.uuid "target_entity_id"
    t.string "target_entity_type", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["framework_id", "kind", "status"], name: "index_fw_suggested_edits_on_kind"
    t.index ["framework_id", "status"], name: "index_framework_suggested_edits_on_framework_id_and_status"
    t.index ["suggestion_id"], name: "index_framework_suggested_edits_on_suggestion_id", unique: true
    t.index ["target_entity_type", "target_entity_id", "field"], name: "index_fw_suggested_edits_on_target"
    t.index ["tenant_id"], name: "index_framework_suggested_edits_on_tenant_id"
  end

  create_table "framework_suggestion_comments", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "author_id", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.uuid "deleted_by_id"
    t.text "deletion_reason"
    t.datetime "edited_at"
    t.uuid "edited_by_id"
    t.uuid "framework_id", null: false
    t.uuid "parent_id"
    t.datetime "posted_at", null: false
    t.string "status", default: "active", null: false
    t.uuid "suggestion_id", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["framework_id", "status"], name: "idx_fw_suggestion_comments_framework"
    t.index ["parent_id"], name: "idx_fw_suggestion_comments_parent", where: "(parent_id IS NOT NULL)"
    t.index ["suggestion_id", "status"], name: "idx_fw_suggestion_comments_thread"
    t.index ["tenant_id"], name: "index_framework_suggestion_comments_on_tenant_id"
  end

  create_table "manager_assessment_delegations", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "delegate_person_id", null: false
    t.datetime "expires_at"
    t.uuid "framework_id", null: false
    t.uuid "granted_by_id", null: false
    t.uuid "person_id", null: false
    t.string "reason"
    t.datetime "revoked_at"
    t.uuid "revoked_by_id"
    t.string "status", default: "active", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "delegate_person_id"], name: "idx_manager_assessment_delegations_on_delegate"
    t.index ["tenant_id", "person_id", "framework_id", "delegate_person_id"], name: "idx_manager_assessment_delegations_unique", unique: true
    t.index ["tenant_id"], name: "index_manager_assessment_delegations_on_tenant_id"
  end

  create_table "mcp_pending_approvals", id: :uuid, default: nil, force: :cascade do |t|
    t.jsonb "arguments", default: {}, null: false
    t.uuid "client_application_id", null: false
    t.datetime "created_at", null: false
    t.datetime "executed_at"
    t.datetime "expires_at", null: false
    t.string "operation_class", null: false
    t.jsonb "result_payload"
    t.integer "status", default: 0, null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["client_application_id"], name: "index_mcp_pending_approvals_on_client_application_id"
    t.index ["tenant_id", "status", "expires_at"], name: "idx_on_tenant_id_status_expires_at_7ab622369a"
    t.index ["tenant_id"], name: "index_mcp_pending_approvals_on_tenant_id"
    t.index ["user_id"], name: "idx_mcp_pending_approvals_pending_by_user", where: "(status = 0)"
    t.index ["user_id"], name: "index_mcp_pending_approvals_on_user_id"
  end

  create_table "noticed_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "notifications_count"
    t.jsonb "params"
    t.uuid "record_id"
    t.string "record_type"
    t.string "type"
    t.datetime "updated_at", null: false
    t.index ["record_type", "record_id"], name: "index_noticed_events_on_record"
  end

  create_table "noticed_notifications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "event_id", null: false
    t.datetime "read_at"
    t.uuid "recipient_id", null: false
    t.string "recipient_type", null: false
    t.datetime "seen_at"
    t.string "type"
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_noticed_notifications_on_event_id"
    t.index ["recipient_type", "recipient_id"], name: "index_noticed_notifications_on_recipient"
  end

  create_table "oauth_access_grants", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "application_id", null: false
    t.string "code_challenge"
    t.string "code_challenge_method"
    t.datetime "created_at", null: false
    t.integer "expires_in", null: false
    t.text "redirect_uri", null: false
    t.uuid "resource_owner_id", null: false
    t.datetime "revoked_at"
    t.string "scopes", default: "", null: false
    t.uuid "tenant_id", null: false
    t.string "token", null: false
    t.index ["application_id"], name: "index_oauth_access_grants_on_application_id"
    t.index ["resource_owner_id"], name: "index_oauth_access_grants_on_resource_owner_id"
    t.index ["tenant_id"], name: "index_oauth_access_grants_on_tenant_id"
    t.index ["token"], name: "index_oauth_access_grants_on_token", unique: true
  end

  create_table "oauth_access_tokens", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "application_id", null: false
    t.datetime "created_at", null: false
    t.integer "expires_in"
    t.string "previous_refresh_token", default: "", null: false
    t.string "refresh_token"
    t.uuid "resource_owner_id"
    t.datetime "revoked_at"
    t.string "scopes"
    t.uuid "tenant_id", null: false
    t.string "token", null: false
    t.index ["application_id"], name: "index_oauth_access_tokens_on_application_id"
    t.index ["refresh_token"], name: "index_oauth_access_tokens_on_refresh_token", unique: true
    t.index ["resource_owner_id"], name: "index_oauth_access_tokens_on_resource_owner_id"
    t.index ["tenant_id"], name: "index_oauth_access_tokens_on_tenant_id"
    t.index ["token"], name: "index_oauth_access_tokens_on_token", unique: true
  end

  create_table "oauth_applications", id: :uuid, default: nil, force: :cascade do |t|
    t.boolean "confidential", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "dynamically_registered_at"
    t.string "name", null: false
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.string "secret", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.index ["dynamically_registered_at"], name: "idx_oauth_applications_dcr_registered", where: "(dynamically_registered_at IS NOT NULL)"
    t.index ["uid"], name: "index_oauth_applications_on_uid", unique: true
  end

  create_table "people", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "department"
    t.string "email", null: false
    t.string "external_id"
    t.integer "hris_level_ordinal"
    t.jsonb "hris_raw_data"
    t.string "hris_source"
    t.string "job_title"
    t.string "level_id"
    t.uuid "manager_id"
    t.string "name", null: false
    t.string "role_id"
    t.string "status", default: "active", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["manager_id"], name: "index_people_on_manager_id"
    t.index ["tenant_id", "email"], name: "index_people_on_tenant_id_and_email", unique: true
    t.index ["tenant_id", "external_id"], name: "index_people_on_tenant_id_and_external_id", unique: true, where: "(external_id IS NOT NULL)"
    t.index ["tenant_id", "status"], name: "index_people_on_tenant_id_and_status"
    t.index ["tenant_id"], name: "index_people_on_tenant_id"
  end

  create_table "person_development_comments", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "author_id", null: false
    t.text "body", null: false
    t.uuid "capability_stable_id"
    t.string "commentable_type", null: false
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.uuid "deleted_by_id"
    t.text "deletion_reason"
    t.datetime "edited_at"
    t.uuid "edited_by_id"
    t.uuid "evidence_id"
    t.uuid "framework_id", null: false
    t.integer "level_ordinal"
    t.uuid "parent_id"
    t.uuid "person_id", null: false
    t.datetime "posted_at", null: false
    t.string "status", default: "active", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_person_development_comments_on_author_id"
    t.index ["evidence_id", "capability_stable_id", "level_ordinal"], name: "idx_pdc_evidence_link_anchor", where: "(evidence_id IS NOT NULL)"
    t.index ["parent_id"], name: "idx_pdc_parent", where: "(parent_id IS NOT NULL)"
    t.index ["person_id", "framework_id", "commentable_type", "capability_stable_id", "level_ordinal"], name: "idx_pdc_cell_anchor"
    t.index ["tenant_id", "person_id", "status"], name: "idx_pdc_tenant_person_status"
    t.index ["tenant_id"], name: "index_person_development_comments_on_tenant_id"
  end

  create_table "person_framework_assignments", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "framework_id", null: false
    t.uuid "level_id", null: false
    t.uuid "person_id", null: false
    t.uuid "role_id", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["person_id", "framework_id"], name: "idx_on_person_id_framework_id_860f7ad292"
    t.index ["tenant_id", "person_id", "framework_id"], name: "idx_person_framework_assignments_unique", unique: true
    t.index ["tenant_id"], name: "index_person_framework_assignments_on_tenant_id"
  end

  create_table "projection_versions", primary_key: "name", id: :string, force: :cascade do |t|
    t.datetime "applied_at", null: false
    t.integer "version", null: false
  end

  create_table "recorded_reporting_managers", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "framework_id", null: false
    t.uuid "manager_id", null: false
    t.uuid "person_id", null: false
    t.string "source", default: "hris", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "person_id", "framework_id"], name: "idx_recorded_reporting_managers_unique", unique: true
    t.index ["tenant_id"], name: "index_recorded_reporting_managers_on_tenant_id"
  end

  create_table "tenant_users", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "person_id"
    t.string "role", default: "member", null: false
    t.string "slack_user_id"
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["person_id"], name: "index_tenant_users_on_person_id"
    t.index ["tenant_id", "user_id"], name: "index_tenant_users_on_tenant_id_and_user_id", unique: true
    t.index ["tenant_id"], name: "index_tenant_users_on_tenant_id"
    t.index ["user_id"], name: "index_tenant_users_on_user_id"
  end

  create_table "tenants", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "hris_config", default: {}, null: false
    t.string "hris_credentials"
    t.string "name", null: false
    t.jsonb "settings", default: {}, null: false
    t.string "slack_credentials"
    t.string "slack_team_id"
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slack_team_id"], name: "index_tenants_on_slack_team_id", unique: true, where: "(slack_team_id IS NOT NULL)"
    t.index ["slug"], name: "index_tenants_on_slug", unique: true
  end

  create_table "users", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.datetime "external_notifications_disclosed_at"
    t.boolean "global_admin", default: false, null: false
    t.jsonb "notification_preferences", default: {}, null: false
    t.string "provider"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.string "uid"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid", unique: true, where: "(provider IS NOT NULL)"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "assessment_cycle_enrollments", "tenants"
  add_foreign_key "assessment_cycle_progress", "people", column: "aligned_by_id", on_delete: :nullify
  add_foreign_key "assessment_cycle_progress", "people", column: "alignment_started_by_id", on_delete: :nullify
  add_foreign_key "assessment_cycle_progress", "tenants"
  add_foreign_key "assessment_cycles", "tenants"
  add_foreign_key "assessment_level_ratings", "tenants"
  add_foreign_key "calibration_session_members", "tenants"
  add_foreign_key "calibration_sessions", "tenants"
  add_foreign_key "event_store_events_in_streams", "event_store_events", column: "event_id", primary_key: "event_id"
  add_foreign_key "evidence_items", "people", column: "author_id", on_delete: :restrict
  add_foreign_key "evidence_items", "people", column: "edited_by_id", on_delete: :nullify
  add_foreign_key "evidence_items", "people", column: "withdrawn_by_id", on_delete: :nullify
  add_foreign_key "evidence_items", "tenants"
  add_foreign_key "evidence_links", "evidence_items", column: "evidence_id", on_delete: :cascade
  add_foreign_key "evidence_links", "people", column: "linked_by_id", on_delete: :nullify
  add_foreign_key "evidence_links", "people", column: "removed_by_id", on_delete: :nullify
  add_foreign_key "evidence_links", "tenants"
  add_foreign_key "evidence_requests", "people", column: "requested_by_id", on_delete: :cascade
  add_foreign_key "evidence_requests", "people", column: "requestee_person_id", on_delete: :cascade
  add_foreign_key "evidence_requests", "tenants"
  add_foreign_key "framework_behavioural_expectations", "tenants"
  add_foreign_key "framework_capabilities", "tenants"
  add_foreign_key "framework_capability_categories", "tenants"
  add_foreign_key "framework_capability_role_bindings", "tenants"
  add_foreign_key "framework_collaborators", "tenants"
  add_foreign_key "framework_explorer_graphs", "tenants"
  add_foreign_key "framework_levels", "tenants"
  add_foreign_key "framework_migration_mappings", "tenants"
  add_foreign_key "framework_publications", "tenant_users", column: "requested_by_id"
  add_foreign_key "framework_publications", "tenants"
  add_foreign_key "framework_role_families", "tenants"
  add_foreign_key "framework_role_illustrations", "tenants"
  add_foreign_key "framework_roles", "tenants"
  add_foreign_key "framework_states", "tenants"
  add_foreign_key "framework_suggested_edits", "people", column: "author_id", on_delete: :restrict
  add_foreign_key "framework_suggested_edits", "people", column: "reviewed_by", on_delete: :nullify
  add_foreign_key "framework_suggested_edits", "tenants"
  add_foreign_key "framework_suggestion_comments", "framework_suggestion_comments", column: "parent_id", on_delete: :restrict
  add_foreign_key "framework_suggestion_comments", "people", column: "author_id", on_delete: :restrict
  add_foreign_key "framework_suggestion_comments", "people", column: "deleted_by_id", on_delete: :nullify
  add_foreign_key "framework_suggestion_comments", "people", column: "edited_by_id", on_delete: :nullify
  add_foreign_key "framework_suggestion_comments", "tenants"
  add_foreign_key "manager_assessment_delegations", "tenants"
  add_foreign_key "mcp_pending_approvals", "oauth_applications", column: "client_application_id"
  add_foreign_key "mcp_pending_approvals", "tenants"
  add_foreign_key "mcp_pending_approvals", "users"
  add_foreign_key "noticed_notifications", "noticed_events", column: "event_id", on_delete: :cascade
  add_foreign_key "oauth_access_grants", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_grants", "tenants"
  add_foreign_key "oauth_access_grants", "users", column: "resource_owner_id"
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_tokens", "tenants"
  add_foreign_key "oauth_access_tokens", "users", column: "resource_owner_id"
  add_foreign_key "people", "people", column: "manager_id"
  add_foreign_key "people", "tenants"
  add_foreign_key "person_development_comments", "people", column: "author_id", on_delete: :restrict
  add_foreign_key "person_development_comments", "people", column: "deleted_by_id", on_delete: :nullify
  add_foreign_key "person_development_comments", "people", column: "edited_by_id", on_delete: :nullify
  add_foreign_key "person_development_comments", "person_development_comments", column: "parent_id", on_delete: :restrict
  add_foreign_key "person_development_comments", "tenants"
  add_foreign_key "person_framework_assignments", "tenants"
  add_foreign_key "recorded_reporting_managers", "tenants"
  add_foreign_key "tenant_users", "people"
  add_foreign_key "tenant_users", "tenants"
  add_foreign_key "tenant_users", "users"
end
