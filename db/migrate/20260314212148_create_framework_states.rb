# frozen_string_literal: true

class CreateFrameworkStates < ActiveRecord::Migration[8.1]
  def change
    create_table :framework_states, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :framework_id, null: false
      t.string :name, null: false
      t.integer :current_published_version, default: 0, null: false
      t.boolean :draft_in_progress, default: false, null: false
      t.integer :draft_version
      t.decimal :mastery_threshold, precision: 5, scale: 2, null: true
      t.decimal :promotion_score_threshold, precision: 5, scale: 2, null: true
      t.timestamps
    end

    add_index :framework_states, [ :tenant_id, :framework_id ], unique: true

    # One serialized graph snapshot per framework — the dedicated view model
    # powering the Framework Explorer (both view and edit modes). Written
    # atomically with each framework event in the same DB transaction. Read
    # by FrameworksController#show/#edit. See
    # docs/architecture/framework-edit-mode-benchmarks.md for why the
    # explorer uses this snapshot rather than the FrameworkState AR tables.
    # framework_id is the natural key — no auto-generated default, every
    # insert must name the framework the snapshot belongs to. `id: false` +
    # explicit primary_key column keeps Rails from giving `framework_id`
    # the gen_random_uuid() default the :uuid id shortcut adds.
    create_table :framework_explorer_graphs, id: false do |t|
      t.uuid :framework_id, null: false, primary_key: true
      # Every framework read model is row-level tenant-scoped via
      # acts_as_tenant (see CLAUDE.md). Defence-in-depth — framework_id is
      # a UUID and already unique globally, but the convention is that
      # every tenant-owned projection row carries tenant_id + FK so a
      # mis-set ActsAsTenant scope can't leak cross-tenant data.
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      # Plain-hash tree serialized as JSON — no Marshal. The shape is versioned
      # via `format_version` so schema bumps can be detected and lazily
      # rebuilt rather than break reads.
      t.jsonb :graph_data, null: false
      t.integer :format_version, null: false, default: 1
      t.timestamps
    end
  end
end
