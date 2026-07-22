# frozen_string_literal: true

require "application_system_test_case"

# The per-linkage discussion thread on the evidence card: the collapsed
# "Discuss" disclosure lazily loads the thread (lifecycle rows + comments
# + composer), posting lands in place, and the collapsed affordance
# carries the count + latest excerpt on the next render.
class AssessmentsEvidenceLinkThreadSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Alice")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      handler = Frameworks::CommandHandler.new
      pd_handler = PersonDevelopment::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test FW")

      rf_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, @role_id, rf_id, "Engineer", "E", "ic")
      @level_id = SecureRandom.uuid_v7
      handler.add_level(@framework_id, @level_id, @role_id, 1, "Engineer 1", "E1", is_entry: true)

      @cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)

      @cap_id = SecureRandom.uuid_v7
      @cap_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap_id, @cap_stable, @cat_id, "Critical Thinking")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, @cap_id, @role_id, weight: 1.0
      )
      handler.set_behavioural_expectation(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap_id, 1, "Synthesises"
      )

      handler.publish_version(@framework_id, "test")

      level = FrameworkState::Level.find_by!(level_id: @level_id)
      pd_handler.assign_to_framework(@person.id, @framework_id, @role_id, level.level_id)

      cycle_handler = AssessmentCycles::CommandHandler.new
      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, @framework_id, "Q1", "regular", 1, defined_by: @person.id)
      cycle_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)

      @evidence_id = SecureRandom.uuid_v7
      pd_handler.record_evidence(@person.id, @framework_id, @evidence_id,
        capability_stable_id: @cap_stable, level_ordinal: 1, source: "self",
        evidence_type: "project_outcome", title: "Launch",
        content: "Done.", author_id: @person.id, valence: "demonstrated")

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end

    sign_in_as(@user)
  end

  def thread_frame_selector
    "#evidence-link-thread-#{@evidence_id}-#{@cap_stable}-1"
  end

  def open_disclosure
    visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
    # The matrix frame eagerly re-fetches after initial render; opening
    # the disclosure before that fetch lands means the replacement swaps
    # in a fresh (closed) card and the thread frame never loads — seen as
    # a mobile-only CI flake (slower render widens the race). Wait for
    # the frame's first load per testing.md's lazy-frame rule.
    assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
    assert_selector "#evidence-#{@evidence_id}", visible: true
    # Native <details>; the summary is not Stimulus-driven, but the
    # synthetic click can still drop on starved CI — open via JS toggle.
    # Scroll it into view too: the lazy frame only fetches once it
    # intersects the viewport, and on the mobile viewport the card can
    # sit below the fold (a real user scrolls to tap the summary).
    page.execute_script(<<~JS)
      const details = document.querySelector('#evidence-#{@evidence_id} details');
      details.open = true;
      details.scrollIntoView({ block: 'center' });
    JS
    assert_selector "#{thread_frame_selector}[complete]", visible: :all
  end

  context "desktop" do
    should "lazily load the thread with the linked lifecycle row and post a comment" do
      open_disclosure

      # Lifecycle row read from the stream: who linked it and as what.
      within thread_frame_selector do
        assert_text "Alice linked this feedback as “Demonstrates”"
        assert_selector "textarea[name='comment[body]']", visible: true
      end

      page.execute_script(<<~JS)
        const frame = document.querySelector("#{thread_frame_selector}");
        const textarea = frame.querySelector("textarea[name='comment[body]']");
        textarea.value = "Is this a growth signal?";
        textarea.dispatchEvent(new Event("input", { bubbles: true }));
        textarea.dispatchEvent(new Event("change", { bubbles: true }));
        frame.querySelector("form").requestSubmit();
      JS

      within thread_frame_selector do
        assert_text "Is this a growth signal?"
        assert_text "Alice"
      end

      # The collapsed affordance carries count + excerpt on the next render.
      visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
      assert_selector "#evidence-#{@evidence_id} summary", text: /1 comment/
      assert_selector "#evidence-#{@evidence_id} summary", text: /Is this a growth signal\?/
    end

    should "show the preserved-history notice on a removed linkage's thread" do
      ActsAsTenant.with_tenant(@tenant) do
        pd = PersonDevelopment::CommandHandler.new
        pd.post_comment(@person.id, @framework_id, SecureRandom.uuid_v7,
          commentable_type: PersonDevelopmentComment::EVIDENCE_LINK,
          capability_stable_id: @cap_stable, level_ordinal: 1,
          evidence_id: @evidence_id,
          body: "Maybe this belongs elsewhere.", author_id: @person.id)
        pd.add_evidence_link(@person.id, @framework_id, @evidence_id,
          capability_stable_id: @cap_stable, level_ordinal: 2,
          linked_by_id: @person.id, valence: "growth_area")
        pd.remove_evidence_link(@person.id, @framework_id, @evidence_id,
          capability_stable_id: @cap_stable, level_ordinal: 1,
          removed_by_id: @person.id, reason: "Moved per discussion")
      end

      # The card is gone from the cell (link removed), so reach the thread
      # frame directly — the deep URL every feed entry / permalink resolves.
      visit assessment_evidence_link_thread_path(
        @assignment, @evidence_id, capability_stable_id: @cap_stable, level_ordinal: 1
      )
      assert_text "This feedback is no longer linked to this behaviour."
      assert_text "Maybe this belongs elsewhere."
      assert_text "removed this feedback from this behaviour — Moved per discussion"
      # Thread stays open for a closing word.
      assert_selector "textarea[name='comment[body]']", visible: true
    end
  end

  context "mobile" do
    should "open the disclosure and read the thread" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      open_disclosure

      within thread_frame_selector do
        assert_text "Alice linked this feedback as “Demonstrates”"
      end
    end
  end
end
