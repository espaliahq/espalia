# frozen_string_literal: true

require "test_helper"

# A ceiling on what the framework explorer puts on the wire.
#
# Four rounds of work (#378 on-demand expanded rows, #379 one shared inline
# editor, #380 delegated menus + an icon sprite, #383 class components) took the
# edit-mode matrix frame from 7.6 MB to under 1 MB, and nothing failed when it
# grew in the first place. This test does: it renders a framework the size of
# the real one and fails if the payload or the per-element machinery creeps back.
#
# It is a REGRESSION guard, not a benchmark — the ceilings sit ~20% above the
# measured numbers, so ordinary content changes pass and a structural regression
# (a form or a controller mount per cell, a utility string per element) does not.
# When a change genuinely earns more bytes, move the ceiling in the same commit
# and say why.
#
# Built from `ExplorerGraph` values in memory rather than through the command
# handler: this measures the view layer, and a fixture this size costs minutes
# of event writes to build any other way.
class Frameworks::ExplorerPayloadTest < ActiveSupport::TestCase
  # Mirrors the seeded me&u framework: 11 roles × 8 levels, 38 capabilities
  # across 6 categories, ~900 illustrations.
  ROLE_COUNT = 11
  LEVEL_COUNT = 8
  CATEGORY_COUNT = 6
  CAPABILITIES_PER_CATEGORY = 6
  # Per expectation, spread across roles — the real framework averages ~26
  # illustrations per capability, not 26 per role.
  ILLUSTRATIONS_PER_EXPECTATION = 3

  # Measured 2026-09-09 on this fixture — matrix 740,053 B, expanded row
  # 149,935 B — then rounded up ~20%.
  MATRIX_MAX_BYTES = 890_000
  EXPANDED_ROW_MAX_BYTES = 180_000

  # The structural ceilings — the shapes that made the frame multi-megabyte.
  # Zero is the real contract for the matrix's three; a small ceiling rather
  # than `assert_equal 0` so a single deliberate exception is possible without
  # rewriting the guard, while a per-cell regression still fails loudly.
  MATRIX_MAX_STIMULUS_MOUNTS = 2
  MATRIX_MAX_FORMS = 2
  MATRIX_MAX_TEXTAREAS = 2

  # The expanded row keeps ONE `reorder-list` mount per reorderable list — the
  # list is the reorder unit, so this scales with the fixture's lists (8), not
  # with its illustrations (24). Set below the illustration count so a
  # per-illustration mount blows straight through it.
  EXPANDED_ROW_MAX_STIMULUS_MOUNTS = 12

  # An icon is a `<use>` reference to the page sprite, never an inline path.
  MATRIX_MAX_ICON_PATHS = 0

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @graph = build_graph
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context "the edit-mode matrix frame" do
    setup { @html = render_matrix }

    should "stay under its byte ceiling" do
      assert_operator @html.bytesize, :<, MATRIX_MAX_BYTES, budget_message("matrix", @html.bytesize)
    end

    should "ship no per-element Stimulus mounts, forms or textareas" do
      # #379 moved the inline editor into one <template> on the root and #380
      # moved every kebab menu behind one delegated controller. Re-introducing
      # either per cell is what made a role toggle cost seconds of parse.
      assert_operator count_of(@html, "data-controller="), :<=, MATRIX_MAX_STIMULUS_MOUNTS
      assert_operator count_of(@html, "<form"), :<=, MATRIX_MAX_FORMS
      assert_operator count_of(@html, "<textarea"), :<=, MATRIX_MAX_TEXTAREAS
    end

    should "reference sprite icons rather than inlining their paths" do
      assert_operator count_of(@html, "<path"), :<=, MATRIX_MAX_ICON_PATHS
      assert_operator count_of(@html, "<use "), :>, 0, "expected the grid to use the icon sprite"
    end

    should "actually render the whole framework it is measuring" do
      # Without this the ceilings above pass vacuously on an empty grid.
      assert_equal capability_count, count_of(@html, "data-matrix-target=\"row\"")
      assert_includes @html, "Capability 1-1"
      assert_includes @html, "Expectation for capability 1-1 at level 1"
    end
  end

  context "one expanded row" do
    setup { @html = render_expanded_row }

    should "stay under its byte ceiling" do
      assert_operator @html.bytesize, :<, EXPANDED_ROW_MAX_BYTES,
                      budget_message("expanded row", @html.bytesize)
    end

    should "ship no per-illustration Stimulus mounts" do
      assert_operator count_of(@html, "data-controller="), :<=, EXPANDED_ROW_MAX_STIMULUS_MOUNTS
    end

    should "render every illustration it is measuring" do
      assert_equal LEVEL_COUNT * ILLUSTRATIONS_PER_EXPECTATION,
                   count_of(@html, "data-reorder-item-id=")
    end
  end

  private

  def capability_count
    CATEGORY_COUNT * CAPABILITIES_PER_CATEGORY
  end

  def budget_message(what, bytes)
    "the #{what} is #{bytes} B — over its ceiling. If the growth is deliberate, " \
      "raise the constant in this file and say what bought the bytes."
  end

  def count_of(html, needle)
    html.scan(needle).size
  end

  def matrix_data(include_illustrations:)
    Frameworks::MatrixDataBuilder.new(
      framework: @graph,
      role_families: @graph.role_families,
      categories: @graph.capability_categories,
      selected_role_ids: [],
      track_filter: "both",
      mode: :edit,
      include_illustrations: include_illustrations
    )
  end

  def render_matrix
    view_context.render(Views::Frameworks::MatrixFrameView.new(
      framework: @graph,
      matrix_data: matrix_data(include_illustrations: false).build,
      selected_role_ids: [],
      mode: :edit,
      can_edit_structure: true,
      approval_authority: Frameworks::SuggestionApprovalAuthority.none
    ))
  end

  def render_expanded_row
    capability_id = @graph.capability_categories.first.capabilities.first.capability_id
    row = matrix_data(include_illustrations: true).build_capability(capability_id)

    view_context.render(Views::Frameworks::Explorer::ExpandedRow.new(
      capability_data: row[:capability],
      merged_levels: row[:merged_levels],
      framework_id: @graph.framework_id,
      loaded: true,
      mode: :edit,
      roles_by_id: row[:selected_roles].index_by(&:role_id),
      can_edit_structure: true,
      approval_authority: Frameworks::SuggestionApprovalAuthority.none
    ))
  end

  # The frames wrap themselves in turbo_frame_tag, so they need a real view
  # context — same shape as the other explorer component tests.
  def view_context
    @view_context ||= ApplicationController.new
      .tap { |controller| controller.request = ActionDispatch::TestRequest.create }
      .view_context
  end

  # ── Fixture ──────────────────────────────────────────────────────────────

  def build_graph
    family_id = SecureRandom.uuid_v7
    roles = Array.new(ROLE_COUNT) { |i| build_role(i, family_id) }
    family = Frameworks::ExplorerGraph::RoleFamily.new(
      role_family_id: family_id, name: "Engineering",
      description: "Builds the product", department: "Product + Engineering", roles: roles
    )
    role_ids = roles.map(&:role_id)

    Frameworks::ExplorerGraph::Framework.new(
      framework_id: SecureRandom.uuid_v7, name: "Payload Framework",
      current_published_version: 1, draft_in_progress: false, draft_version: nil,
      role_families: [ family ],
      capability_categories: Array.new(CATEGORY_COUNT) { |i| build_category(i, role_ids) }
    )
  end

  def build_role(index, family_id)
    role_id = SecureRandom.uuid_v7
    Frameworks::ExplorerGraph::Role.new(
      role_id: role_id, role_family_id: family_id, name: "Role #{index + 1}",
      code: "R#{index + 1}", track: index.even? ? "ic" : "management",
      levels: Array.new(LEVEL_COUNT) do |l|
        Frameworks::ExplorerGraph::Level.new(
          level_id: SecureRandom.uuid_v7, role_id: role_id, ordinal: l + 1,
          title: "Role #{index + 1} level #{l + 1}", code: "R#{index + 1}L#{l + 1}",
          is_entry: l.zero?, added_in_draft: false
        )
      end
    )
  end

  def build_category(index, role_ids)
    category_id = SecureRandom.uuid_v7
    Frameworks::ExplorerGraph::CapabilityCategory.new(
      category_id: category_id, name: "Category #{index + 1}",
      description: "What this group of capabilities is for, in a sentence.",
      ordinal: index + 1, deficit_threshold: nil, overperformance_cap: nil, status: "active",
      capabilities: Array.new(CAPABILITIES_PER_CATEGORY) do |c|
        build_capability(category_id, "#{index + 1}-#{c + 1}", role_ids)
      end
    )
  end

  def build_capability(category_id, label, role_ids)
    capability_id = SecureRandom.uuid_v7
    Frameworks::ExplorerGraph::Capability.new(
      capability_id: capability_id, stable_id: SecureRandom.uuid_v7, category_id: category_id,
      name: "Capability #{label}",
      description: "A sentence describing what capability #{label} means in practice.",
      status: "active", added_in_draft: false, pending_archive: false,
      bindings: role_ids.map do |role_id|
        Frameworks::ExplorerGraph::CapabilityRoleBinding.new(
          binding_id: SecureRandom.uuid_v7, capability_id: capability_id, role_id: role_id,
          weight: 1.0, individual_tolerance: nil, added_in_draft: false
        )
      end,
      expectations: Array.new(LEVEL_COUNT) { |l| build_expectation(capability_id, label, l + 1, role_ids) }
    )
  end

  def build_expectation(capability_id, label, ordinal, role_ids)
    expectation_id = SecureRandom.uuid_v7
    Frameworks::ExplorerGraph::BehaviouralExpectation.new(
      expectation_id: expectation_id, stable_id: SecureRandom.uuid_v7,
      capability_id: capability_id, level_ordinal: ordinal,
      description: "Expectation for capability #{label} at level #{ordinal}", added_in_draft: false,
      illustrations: Array.new(ILLUSTRATIONS_PER_EXPECTATION) do |n|
        Frameworks::ExplorerGraph::RoleIllustration.new(
          illustration_id: SecureRandom.uuid_v7, stable_id: SecureRandom.uuid_v7,
          # All of a level's examples belong to one role, rotating by level —
          # so each list holds more than one and carries a `reorder-list` mount,
          # which is what the mount ceiling below is measuring.
          expectation_id: expectation_id, role_id: role_ids[ordinal % role_ids.size],
          ordinal: n + 1,
          description: "An example of capability #{label} at level #{ordinal}, number #{n + 1}."
        )
      end
    )
  end
end
