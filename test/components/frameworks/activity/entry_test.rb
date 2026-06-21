# frozen_string_literal: true

require "test_helper"

# Summary copy for activity-feed entries. Focuses on the org-structure rename
# kinds, whose summary names the field(s) that changed (e.g. "Updated a role's
# name") rather than a bare noun.
class Views::Frameworks::Activity::EntryTest < ActiveSupport::TestCase
  # occurred_at is nil so the footer's time_ago_in_words view helper isn't
  # invoked in this context-free unit render — the summary line is unaffected.
  def render_entry(kind:, payload:)
    entry = Frameworks::ActivityFeedQuery::Entry.new(
      id: SecureRandom.uuid_v7, kind: kind, occurred_at: nil,
      payload: payload, actor_name: "Ada", superseded: false
    )
    Views::Frameworks::Activity::Entry.new(entry: entry).call
  end

  context "org-structure update summaries" do
    should "name the field for a role-family rename" do
      assert_includes render_entry(kind: "role_family_updated", payload: { name: "Platform" }),
                      "Updated a role family&#39;s name"
    end

    should "name the field for a role rename" do
      assert_includes render_entry(kind: "role_updated", payload: { name: "Backend Engineer" }),
                      "Updated a role&#39;s name"
    end

    should "list multiple changed fields" do
      assert_includes render_entry(kind: "role_updated", payload: { name: "X", track: "management" }),
                      "Updated a role&#39;s name and track"
    end

    should "name the title for a level rename" do
      assert_includes render_entry(kind: "level_updated", payload: { title: "Engineer One" }),
                      "Updated a level&#39;s title"
    end

    should "fall back to a bare summary when no known field changed" do
      assert_includes render_entry(kind: "role_updated", payload: {}), "Updated a role"
    end
  end
end
