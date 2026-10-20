# frozen_string_literal: true

require "test_helper"

# Summary copy for assessment activity-feed entries. Focuses on actor
# attribution for evidence kinds — the feed must name who recorded /
# linked / unlinked / moved / withdrew evidence, falling back to a
# generic, actor-less phrasing for unattributed (historical) entries.
class Views::Assessments::Activity::EntryTest < ActiveSupport::TestCase
  Person = Struct.new(:name)
  Item   = Struct.new(:title, :content, :author, :withdrawn_by, :recorded_unplaced, keyword_init: true)

  # occurred_at is nil so the footer's time_ago_in_words helper isn't invoked
  # in this context-free unit render — only the summary line is under test.
  def render_entry(kind:, payload:, capability_name: "Critical Thinking", level_ordinal: 2,
                   capability_stable_id: SecureRandom.uuid_v7)
    entry = Assessments::ActivityFeedQuery::Entry.new(
      id: SecureRandom.uuid_v7, kind: kind, occurred_at: nil, payload: payload,
      capability_stable_id: capability_stable_id, level_ordinal: level_ordinal,
      capability_name: capability_name
    )
    Views::Assessments::Activity::Entry.new(entry: entry).call
  end

  ImportedItem = Struct.new(:title, :content, :author, :withdrawn_by, :recorded_unplaced, :external_reference,
                            keyword_init: true)

  context "evidence_recorded from a peer system" do
    should "say where it was given, linking to the original" do
      reference = ExternalReference.new(system: "chip", url: "https://chip.example.com/f/1",
                                        metadata: { "given_at" => "2026-10-18T03:12:44Z" })
      item = ImportedItem.new(title: "", content: "Calm call.", author: Person.new("Priya"), external_reference: reference)
      html = Nokogiri::HTML5.fragment(render_entry(kind: "evidence_recorded", payload: item, capability_stable_id: nil,
                                                   level_ordinal: nil))
      assert_includes html.text, "Priya gave feedback, not yet placed on a capability"
      assert_equal "https://chip.example.com/f/1", html.at_css("a[data-origin='chip']")["href"]
    end

    should "carry no badge for a reference the exchange did not write" do
      reference = ExternalReference.new(system: "github", url: "https://github.com/o/r/pull/1")
      item = ImportedItem.new(title: "", content: "PR.", author: Person.new("Ada"), external_reference: reference)
      assert_not_includes render_entry(kind: "evidence_recorded", payload: item), "data-origin"
    end
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

    should "say a withdrawn item was never placed when it had no cell" do
      item = Item.new(title: "", content: "x", author: nil, withdrawn_by: Person.new("Ada"))
      html = render_entry(kind: "evidence_withdrawn", payload: item,
        capability_name: nil, level_ordinal: nil, capability_stable_id: nil)
      assert_includes html, "Ada withdrew feedback that was never placed on a capability"
    end

    should "say the cell was chosen later for an item given without one" do
      item = Item.new(title: "", content: "Great call.", author: Person.new("Ada"), recorded_unplaced: true)
      html = render_entry(kind: "evidence_recorded", payload: item)
      assert_includes html, "Ada gave feedback, placed later on Critical Thinking · L2"
    end

    should "say an unplaced item has no capability yet, and not make it focusable" do
      item = Item.new(title: "", content: "Great call.", author: Person.new("Ada"))
      html = render_entry(kind: "evidence_recorded", payload: item,
        capability_name: nil, level_ordinal: nil, capability_stable_id: nil)
      assert_includes html, "Ada gave feedback, not yet placed on a capability"
      refute_includes html, "focusEntry"
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

  context "declared explorations" do
    should "say who started exploring which role, with the note beneath" do
      html = render_entry(kind: "exploration_started", payload: {
        actor_name: "Alex", role_label: "Product Manager · PM3", note: "Curious about discovery", by_assessee: true
      })
      assert_includes html, "Alex started exploring Product Manager · PM3"
      assert_includes html, "Curious about discovery"
    end

    should "say the manager side shared it when they declared it" do
      html = render_entry(kind: "exploration_started", payload: {
        actor_name: "Morgan", role_label: "Product Manager · PM3", by_assessee: false
      })
      assert_includes html, "Morgan shared an exploration of Product Manager · PM3"
    end

    should "say who closed it and what came of it" do
      html = render_entry(kind: "exploration_closed", payload: {
        actor_name: "Morgan", role_label: "Product Manager · PM3", outcome: "not_now"
      })
      assert_includes html, "Morgan closed the exploration of Product Manager · PM3 — not now"
    end
  end

  context "an exploration a move into the role closed" do
    should "say it closed without naming anyone" do
      html = render_entry(kind: "exploration_closed", payload: {
        actor_name: nil, role_label: "Product Manager · PM3", outcome: "moved"
      })
      assert_includes html, "The exploration of Product Manager · PM3 closed — moved into the role"
    end
  end
end
