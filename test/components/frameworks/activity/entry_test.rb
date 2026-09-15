# frozen_string_literal: true

require "test_helper"

# Summary copy for activity-feed entries. Focuses on the org-structure rename
# kinds, whose summary names the field(s) that changed (e.g. "Updated a role's
# name") rather than a bare noun.
class Views::Frameworks::Activity::EntryTest < ActiveSupport::TestCase
  # occurred_at is nil so the footer's time_ago_in_words view helper isn't
  # invoked in this context-free unit render — the summary line is unaffected.
  def render_entry(kind:, payload:, capability_id: nil, category_id: nil)
    entry = Frameworks::ActivityFeedQuery::Entry.new(
      id: SecureRandom.uuid_v7, kind: kind, occurred_at: nil,
      payload: payload, actor_name: "Ada", superseded: false,
      capability_id: capability_id, category_id: category_id
    )
    Views::Frameworks::Activity::Entry.new(entry: entry).call
  end

  # An entry anchored to a capability, for the navigation data-attr assertions.
  def render_anchored_entry(payload:)
    render_entry(kind: "suggestion_edit", payload: payload,
                 capability_id: "cap-1", category_id: "cat-1")
  end

  context "org-structure update summaries" do
    should "name the new name for a framework rename" do
      assert_includes render_entry(kind: "framework_renamed", payload: { name: "Engineering Career Path" }),
                      "Renamed the framework to \u201CEngineering Career Path\u201D"
    end

    should "name the field for a role-family rename" do
      assert_includes render_entry(kind: "role_family_updated", payload: { name: "Platform" }),
                      "Updated a role family&#39;s name"
    end

    should "name the field for a role rename" do
      assert_includes render_entry(kind: "role_updated", payload: { name: "Backend Engineer" }),
                      "Updated a role&#39;s name"
    end

    should "name the department for a role-family move" do
      assert_includes render_entry(kind: "role_family_updated", payload: { department: "Finance" }),
                      "Updated a role family&#39;s department"
    end

    should "list multiple changed fields" do
      assert_includes render_entry(kind: "role_updated", payload: { name: "X", track: "management" }),
                      "Updated a role&#39;s name and track"
    end

    should "name the title for a level rename" do
      assert_includes render_entry(kind: "level_updated", payload: { title: "Engineer One" }),
                      "Updated a level&#39;s title"
    end

    should "count a field intentionally cleared to blank (keyed, not value, presence)" do
      assert_includes render_entry(kind: "role_family_updated", payload: { description: "" }),
                      "Updated a role family&#39;s description"
    end

    should "fall back to a bare summary when no known field changed" do
      assert_includes render_entry(kind: "role_updated", payload: {}), "Updated a role"
    end
  end

  context "matrix navigation data attrs" do
    should "navigate to the cell when the entry knows its level" do
      html = render_anchored_entry(payload: { expectation_level: 3 })
      assert_includes html, 'data-nav-level="cell"'
      assert_includes html, 'data-nav-level-ordinal="3"'
      assert_includes html, 'data-nav-capability-id="cap-1"'
    end

    should "fall back to capability navigation without a level" do
      html = render_anchored_entry(payload: {})
      assert_includes html, 'data-nav-level="capability"'
      assert_not_includes html, "data-nav-level-ordinal"
    end
  end

  context "collaborator summaries" do
    should "name the added collaborator and their role" do
      html = render_entry(kind: "collaborator_added",
        payload: { collaborator_name: "Cora Collaborator", collaborator_role: "capability_lead" })
      assert_includes html, "Added Cora Collaborator as capability lead"
    end

    should "name the collaborator on a role change" do
      html = render_entry(kind: "collaborator_role_changed",
        payload: { collaborator_name: "Cora Collaborator", new_role: "owner" })
      assert_includes html, "Changed Cora Collaborator&#39;s role to Owner"
    end

    should "name the removed collaborator" do
      html = render_entry(kind: "collaborator_removed",
        payload: { collaborator_name: "Cora Collaborator" })
      assert_includes html, "Removed Cora Collaborator as a collaborator"
    end

    should "fall back to anonymous phrasing when the name didn't resolve" do
      assert_includes render_entry(kind: "collaborator_added", payload: { collaborator_role: "editor" }),
        "Added a collaborator (Editor)"
      assert_includes render_entry(kind: "collaborator_removed", payload: {}),
        "Removed a collaborator"
    end
  end
end
