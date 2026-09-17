# frozen_string_literal: true

# Per-tenant words for the five performance states (#415).
#
# The state a score lands in is scoring policy and stays internal
# (`:mastering` in code, events, and the MCP payload); the WORD shown for it
# is culture, and "Mastering" reads oddly in plenty of teams next to "62% of
# the way to E4".
#
# One `json_translate` column per state from the start, per
# docs/guidelines/rails-models.md: user-facing text that may need
# translating never lives in a plain string column, and json_translate works
# on model columns rather than inside a store_model — which is why these are
# not `settings` keys like the theme colours beside them. All five ship even
# though the UI exposes only `mastering_label` today; adding a column later
# is a migration, and the read helper already falls back per state.
#
# A nil or blank value falls back to the locale default, so a tenant stores
# only what it overrode and a change to the shipped word still reaches them.
class AddStateLabelTranslationsToTenants < ActiveRecord::Migration[8.1]
  STATES = %w[underperforming progressing performing mastering eligible].freeze

  def change
    STATES.each do |state|
      add_column :tenants, :"#{state}_label_translations", :jsonb, default: {}, null: false
    end
  end
end
