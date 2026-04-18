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

ActiveRecord::Schema[8.1].define(version: 2026_04_08_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "assessment_cycle_participants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "aligned_at"
    t.datetime "created_at", null: false
    t.uuid "cycle_id", null: false
    t.datetime "enrolled_at", null: false
    t.datetime "manager_completed_at"
    t.uuid "person_id", null: false
    t.datetime "self_completed_at"
    t.datetime "started_at"
    t.string "status", default: "enrolled", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.string "withdrawal_reason"
    t.datetime "withdrawn_at"
    t.index ["cycle_id", "person_id"], name: "idx_assessment_cycle_participants_unique", unique: true
    t.index ["tenant_id", "person_id", "status"], name: "idx_assessment_cycle_participants_by_person_status"
    t.index ["tenant_id"], name: "index_assessment_cycle_participants_on_tenant_id"
  end

  create_table "assessment_cycles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "closed_at"
    t.datetime "created_at", null: false
    t.uuid "cycle_id", null: false
    t.string "cycle_type", null: false
    t.uuid "defined_by"
    t.uuid "framework_id", null: false
    t.integer "framework_version", null: false
    t.string "name", null: false
    t.datetime "opened_at", null: false
    t.string "status", default: "open", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "cycle_id"], name: "idx_assessment_cycles_unique_cycle_id", unique: true
    t.index ["tenant_id", "framework_id"], name: "idx_assessment_cycles_by_framework"
    t.index ["tenant_id", "framework_id"], name: "idx_assessment_cycles_one_open_per_framework", unique: true, where: "((status)::text = 'open'::text)"
    t.index ["tenant_id"], name: "index_assessment_cycles_on_tenant_id"
  end

  create_table "assessment_level_ratings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
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
    t.text "manager_rated_comment"
    t.string "manager_rated_frequency"
    t.string "migration_status", default: "not_flagged", null: false
    t.uuid "person_id", null: false
    t.text "reassessment_reason"
    t.text "self_rated_comment"
    t.string "self_rated_frequency"
    t.string "source", default: "human", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["cycle_id", "person_id", "framework_id", "capability_stable_id", "level_ordinal"], name: "idx_assessment_ratings_cycle_person_cap_level", unique: true
    t.index ["cycle_id", "person_id"], name: "idx_assessment_ratings_cycle_person"
    t.index ["person_id", "framework_id"], name: "index_assessment_level_ratings_on_person_id_and_framework_id"
    t.index ["tenant_id"], name: "index_assessment_level_ratings_on_tenant_id"
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

  create_table "framework_behavioural_expectations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
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

  create_table "framework_capabilities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "capability_id", null: false
    t.uuid "category_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.uuid "stable_id", null: false
    t.string "status", default: "active", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "capability_id"], name: "index_framework_capabilities_on_tenant_id_and_capability_id", unique: true
    t.index ["tenant_id", "stable_id"], name: "index_framework_capabilities_on_tenant_id_and_stable_id"
    t.index ["tenant_id"], name: "index_framework_capabilities_on_tenant_id"
  end

  create_table "framework_capability_categories", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "category_id", null: false
    t.datetime "created_at", null: false
    t.decimal "deficit_threshold", precision: 5, scale: 2
    t.text "description"
    t.uuid "framework_id", null: false
    t.string "name", null: false
    t.integer "ordinal"
    t.integer "overperformance_cap"
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "category_id"], name: "idx_fw_cap_categories_on_tenant_and_category", unique: true
    t.index ["tenant_id"], name: "index_framework_capability_categories_on_tenant_id"
  end

  create_table "framework_capability_role_bindings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
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

  create_table "framework_collaborators", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
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

  create_table "framework_explorer_graphs", primary_key: "framework_id", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "format_version", default: 1, null: false
    t.jsonb "graph_data", null: false
    t.datetime "updated_at", null: false
  end

  create_table "framework_levels", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
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

  create_table "framework_migration_mappings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
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

  create_table "framework_role_families", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
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

  create_table "framework_role_illustrations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
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

  create_table "framework_roles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
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

  create_table "framework_states", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "current_published_version", default: 0, null: false
    t.decimal "deficit_threshold", precision: 5, scale: 2, default: "1.0", null: false
    t.boolean "draft_in_progress", default: false, null: false
    t.integer "draft_version"
    t.uuid "framework_id", null: false
    t.decimal "mastery_threshold", precision: 5, scale: 2
    t.decimal "meeting_expectation_threshold", precision: 5, scale: 2
    t.string "name", null: false
    t.integer "overperformance_cap", default: 1, null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "framework_id"], name: "index_framework_states_on_tenant_id_and_framework_id", unique: true
    t.index ["tenant_id"], name: "index_framework_states_on_tenant_id"
  end

  create_table "framework_suggested_edits", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "author_id", null: false
    t.datetime "created_at", null: false
    t.text "current_value"
    t.string "field"
    t.uuid "framework_id", null: false
    t.string "kind", default: "edit", null: false
    t.uuid "parent_id"
    t.jsonb "proposed_attributes", default: {}, null: false
    t.text "rationale"
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

  create_table "people", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
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

  create_table "person_framework_assignments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
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

  create_table "tenant_users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "person_id"
    t.string "role", default: "member", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["person_id"], name: "index_tenant_users_on_person_id"
    t.index ["tenant_id", "user_id"], name: "index_tenant_users_on_tenant_id_and_user_id", unique: true
    t.index ["tenant_id"], name: "index_tenant_users_on_tenant_id"
    t.index ["user_id"], name: "index_tenant_users_on_user_id"
  end

  create_table "tenants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "hris_config", default: {}, null: false
    t.string "hris_credentials"
    t.string "name", null: false
    t.jsonb "settings", default: {}, null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_tenants_on_slug", unique: true
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.boolean "global_admin", default: false, null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "assessment_cycle_participants", "tenants"
  add_foreign_key "assessment_cycles", "tenants"
  add_foreign_key "assessment_level_ratings", "tenants"
  add_foreign_key "event_store_events_in_streams", "event_store_events", column: "event_id", primary_key: "event_id"
  add_foreign_key "framework_behavioural_expectations", "tenants"
  add_foreign_key "framework_capabilities", "tenants"
  add_foreign_key "framework_capability_categories", "tenants"
  add_foreign_key "framework_capability_role_bindings", "tenants"
  add_foreign_key "framework_collaborators", "tenants"
  add_foreign_key "framework_levels", "tenants"
  add_foreign_key "framework_migration_mappings", "tenants"
  add_foreign_key "framework_role_families", "tenants"
  add_foreign_key "framework_role_illustrations", "tenants"
  add_foreign_key "framework_roles", "tenants"
  add_foreign_key "framework_states", "tenants"
  add_foreign_key "framework_suggested_edits", "people", column: "author_id"
  add_foreign_key "framework_suggested_edits", "people", column: "reviewed_by"
  add_foreign_key "framework_suggested_edits", "tenants"
  add_foreign_key "people", "people", column: "manager_id"
  add_foreign_key "people", "tenants"
  add_foreign_key "person_framework_assignments", "tenants"
  add_foreign_key "tenant_users", "people"
  add_foreign_key "tenant_users", "tenants"
  add_foreign_key "tenant_users", "users"
end
