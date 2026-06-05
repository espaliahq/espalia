# frozen_string_literal: true

# Introduces multi-linkage evidence: one evidence item can be linked to
# many (capability_stable_id, level_ordinal) coordinates. Content stays on
# `evidence_items`; the coordinates move to a dedicated `evidence_links`
# table (one active row per cell the item appears in).
#
# Single deploy. Because existing data is strictly 1 link → 1 row, the
# backfill is a one-time INSERT … SELECT (one active link per existing
# item, any item status — item-level withdrawal still governs visibility).
#
# The `evidence_items.capability_stable_id` / `level_ordinal` columns are
# KEPT (NOT NULL) as the item's ORIGIN link — the coordinate it was first
# recorded against. The activity feed anchors evidence-recorded/withdrawn
# entries on them, so they stay populated. `evidence_links` is the
# authoritative source for which cells an item currently appears in (the
# assessment matrix reads from it); the origin columns are a denormalised
# convenience, not the multi-link source of truth.
#
# Owned exclusively by PersonDevelopment::Projections::EvidenceCollection
# (single-writer invariant). The projection's CODE_VERSION is bumped to 3;
# the version row is stamped via `mark_rebuilt` after this verified
# backfill, so a full event replay is not required.
class CreateEvidenceLinks < ActiveRecord::Migration[8.1]
  def up
    create_table :evidence_links, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, foreign_key: true, null: false
      t.uuid :evidence_id,          null: false
      t.uuid :person_id,            null: false
      t.uuid :framework_id,         null: false
      t.uuid :capability_stable_id, null: false
      t.integer :level_ordinal,     null: false

      t.string :link_status, default: "active", null: false # active | removed
      t.uuid :linked_by_id
      t.datetime :linked_at, null: false
      t.uuid :removed_by_id
      t.datetime :removed_at
      t.text :removal_reason

      t.timestamps
    end

    add_index :evidence_links, %i[evidence_id capability_stable_id level_ordinal],
              unique: true, name: "idx_evidence_links_natural_key"
    add_index :evidence_links,
              %i[person_id framework_id capability_stable_id level_ordinal link_status],
              name: "idx_evidence_links_anchor"
    add_index :evidence_links, :evidence_id, name: "index_evidence_links_on_evidence_id"

    add_foreign_key :evidence_links, :evidence_items, column: :evidence_id, on_delete: :cascade
    add_foreign_key :evidence_links, :people, column: :linked_by_id, on_delete: :nullify
    add_foreign_key :evidence_links, :people, column: :removed_by_id, on_delete: :nullify

    backfill_links
  end

  def down
    drop_table :evidence_links
  end

  private

  # One active link per existing evidence item. Ids are generated app-side
  # as UUID v7 (Postgres 16 has no uuidv7()); inserted in batches.
  def backfill_links
    now = Time.current
    say_with_time "backfilling evidence_links from evidence_items" do
      total = 0
      select_all(<<~SQL).to_a.each_slice(500) do |slice|
        SELECT id, tenant_id, person_id, framework_id,
               capability_stable_id, level_ordinal, author_id, recorded_at
        FROM evidence_items
      SQL
        rows = slice.map do |r|
          {
            id: SecureRandom.uuid_v7,
            tenant_id: r["tenant_id"],
            evidence_id: r["id"],
            person_id: r["person_id"],
            framework_id: r["framework_id"],
            capability_stable_id: r["capability_stable_id"],
            level_ordinal: r["level_ordinal"],
            link_status: "active",
            linked_by_id: r["author_id"],
            linked_at: r["recorded_at"],
            created_at: now,
            updated_at: now
          }
        end
        insert_all_rows(rows)
        total += rows.size
      end
      total
    end
  end

  def insert_all_rows(rows)
    return if rows.empty?

    columns = rows.first.keys
    values = rows.map do |row|
      "(" + columns.map { |c| quote(row[c]) }.join(", ") + ")"
    end.join(", ")
    execute(<<~SQL)
      INSERT INTO evidence_links (#{columns.join(', ')})
      VALUES #{values}
    SQL
  end
end
