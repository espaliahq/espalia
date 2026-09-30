# frozen_string_literal: true

require "test_helper"

# Summary copy for assessment activity-feed entries. Focuses on actor
# attribution for evidence kinds — the feed must name who recorded /
# linked / unlinked / moved / withdrew evidence, falling back to a
# generic, actor-less phrasing for unattributed (historical) entries.
class Views::Assessments::Activity::EntryTest < ActiveSupport::TestCase
  Person = Struct.new(:name)
  Item   = Struct.new(:title, :content, :author, :withdrawn_by, keyword_init: true)

  # occurred_at is nil so the footer's time_ago_in_words helper isn't invoked
  # in this context-free unit render — only the summary line is under test.
  def render_entry(kind:, payload:, capability_name: "Critical Thinking", level_ordinal: 2)
    entry = Assessments::ActivityFeedQuery::Entry.new(
      id: SecureRandom.uuid_v7, kind: kind, occurred_at: nil, payload: payload,
      capability_stable_id: SecureRandom.uuid_v7, level_ordinal: level_ordinal,
      capability_name: capability_name
    )
    Views::Assessments::Activity::Entry.new(entry: entry).call
  end

  context "evidence_recorded" do
    should "name the author who recorded it" do
      item = Item.new(title: "Launch", content: "Shipped X.", author: Person.new("Ada"))
      html = render_entry(kind: "evidence_recorded", payload: item)
      assert_includes html, "Ada recorded “Launch” on Critical Thinking · L2"
    end

    should "fall back to a generic phrasing when the author is unknown" do
      item = Item.new(title: "Launch", content: "Shipped X.", author: nil)
      html = render_entry(kind: "evidence_recorded", payload: item)
      assert_includes html, "Recorded “Launch” on Critical Thinking · L2"
    end

    should "say 'feedback' when there is no title" do
      item = Item.new(title: "", content: "Shipped X.", author: Person.new("Ada"))
      html = render_entry(kind: "evidence_recorded", payload: item)
      assert_includes html, "Ada recorded feedback on Critical Thinking · L2"
    end
  end

  context "ratings made through a role lens" do
    should "name the lens a self rating was made through" do
      html = render_entry(kind: "self_rated", payload: { frequency: "some", via_role_code: "PM2" })
      assert_includes html, "Self-rated Critical Thinking · L2 while exploring PM2"
    end

    should "name the lens a manager rating was made through" do
      html = render_entry(kind: "manager_rated", payload: { frequency: "some", actor_name: "Morgan",
                                                           via_role_code: "PM2" })
      assert_includes html, "Morgan rated Critical Thinking · L2 while exploring PM2"
    end

    should "say nothing extra for a rating on the home role" do
      html = render_entry(kind: "self_rated", payload: { frequency: "some" })
      assert_not_includes html, "exploring"
    end
  end

  context "evidence link entries" do
    should "name who linked the evidence" do
      html = render_entry(kind: "evidence_linked",
        payload: { actor_name: "Ada", evidence_title: "Launch" })
      assert_includes html, "Ada linked “Launch” to Critical Thinking · L2"
    end

    should "name who unlinked the evidence" do
      html = render_entry(kind: "evidence_unlinked",
        payload: { actor_name: "Ada", evidence_title: "Launch" })
      assert_includes html, "Ada unlinked “Launch” from Critical Thinking · L2"
    end

    should "fall back to an actor-less, capitalised phrasing when unknown" do
      html = render_entry(kind: "evidence_linked",
        payload: { actor_name: nil, evidence_title: "Launch" })
      assert_includes html, "Linked “Launch” to Critical Thinking · L2"
    end
  end

  context "evidence_relinked" do
    should "name who moved the evidence" do
      html = render_entry(kind: "evidence_relinked", payload: {
        actor_name: "Ada", previous_capability_name: "Old Cap", previous_level_ordinal: 1
      })
      assert_includes html, "Ada relinked feedback from Old Cap · L1 to Critical Thinking · L2"
    end
  end

  context "evidence_withdrawn" do
    should "name who withdrew the evidence" do
      item = Item.new(withdrawn_by: Person.new("Ada"))
      html = render_entry(kind: "evidence_withdrawn", payload: item)
      assert_includes html, "Ada withdrew feedback on Critical Thinking · L2"
    end
  end

  context "self_rated" do
    should "label the lowest rating Not yet on the secondary line" do
      html = render_entry(kind: "self_rated", payload: { frequency: "none" })
      assert_includes html, "Not yet"
    end
  end
end
