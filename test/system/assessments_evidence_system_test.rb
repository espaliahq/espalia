# frozen_string_literal: true

require "application_system_test_case"

class AssessmentsEvidenceSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze

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
      handler.create_framework(@framework_id, "Test Framework")

      rf_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, @role_id, rf_id, "Software Engineer", "E", "ic")
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
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap_id, 1,
        "Synthesises information"
      )

      handler.publish_version(@framework_id, "test")

      level = FrameworkState::Level.find_by!(level_id: @level_id)
      pd_handler.assign_to_framework(@person.id, @framework_id, @role_id, level.level_id)

      cycle_handler = AssessmentCycles::CommandHandler.new
      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, @framework_id, "Q1", "regular", 1, defined_by: @person.id)
      cycle_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end

    sign_in_as(@user)
  end

  context "edit modal" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @evidence_id = SecureRandom.uuid_v7
        PersonDevelopment::CommandHandler.new.record_evidence(
          @person.id, @framework_id, @evidence_id,
          capability_stable_id: @cap_stable, level_ordinal: 1,
          source: "self", evidence_type: "project_outcome",
          title: "Original title", content: "Original content.",
          author_id: @person.id, valence: "demonstrated"
        )
      end
    end

    # Kebab → Edit opens the unified modal prefilled, the diff-save lands, and
    # the focused cell re-renders in place with the new content + "edited"
    # footer (no full-page reload). JS-dispatched clicks bypass the
    # hover-revealed kebab + lazy-frame races on starved CI.
    should "open prefilled, submit a change, and stamp edited_at on the card" do
      visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
      wait_for_stimulus "evidence-modal"
      assert_selector "#evidence-#{@evidence_id}", visible: true
      assert_selector "#evidence-#{@evidence_id} [data-controller~='dropdown'][data-connected]", visible: :all

      page.execute_script(<<~JS)
        document.querySelector(
          "#evidence-#{@evidence_id} [data-evidence-modal-mode-param='edit']"
        ).click();
      JS
      # The modal opens and the lazy frame renders the prefilled form.
      assert_selector "#evidence-modal-overlay", visible: true
      assert_selector "#evm-content", visible: true

      content_val, type_val = page.evaluate_script(<<~JS)
        [ document.querySelector("#evm-content").value,
          document.querySelector("#evm-type").value ]
      JS
      assert_equal "Original content.", content_val
      assert_equal "project_outcome", type_val

      page.execute_script(<<~JS)
        const f = document.querySelector("#evidence-modal form");
        f.querySelector("#evm-title").value = "Updated title";
        f.querySelector("#evm-content").value = "Revised content.";
        f.querySelector("#evm-type").value = "code_review";
        f.requestSubmit();
      JS

      # The focused cell re-renders in place (Turbo Stream), no navigation.
      assert_selector "#evidence-#{@evidence_id}", visible: true
      assert_text "Updated title"
      assert_text "edited"

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(@evidence_id)
        assert_equal "Updated title", item.title
        assert_equal "Revised content.", item.content
        assert_equal "code_review", item.evidence_type
        assert_equal @person.id, item.edited_by_id
        assert_not_nil item.edited_at
      end
    end

    should "not render an Edit menu item for evidence the viewer did NOT author" do
      ActsAsTenant.with_tenant(@tenant) do
        peer_user = FactoryBot.create(:user, password: "password123")
        peer = FactoryBot.create(:person, tenant: @tenant, email: peer_user.email, name: "Peer")
        FactoryBot.create(:tenant_user, tenant: @tenant, user: peer_user, person: peer)
        other_evidence_id = SecureRandom.uuid_v7
        PersonDevelopment::CommandHandler.new.record_evidence(
          @person.id, @framework_id, other_evidence_id,
          capability_stable_id: @cap_stable, level_ordinal: 1,
          source: "peer", evidence_type: "peer_feedback",
          content: "Solid collaborator.", author_id: peer.id, valence: "demonstrated"
        )

        visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
        wait_for_stimulus "evidence-modal"
        assert_selector "#evidence-#{other_evidence_id}", visible: true
        # The author's own item carries an Edit menuitem; the peer-authored
        # one must not.
        assert_no_selector "#evidence-#{other_evidence_id} [role='menuitem']", text: "Edit", visible: :all
      end
    end
  end

  context "evidence modal" do
    # The full create flow is covered by the diff-save integration tests. The
    # system test's unique value is the Stimulus wiring: the matrix "+ Add"
    # button loads the lazy modal frame for the right cell, with the primary
    # cell + behavioural-expectation context primed.
    should "open with the cell's capability + expectation context" do
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      page.execute_script(<<~JS)
        document.querySelector(
          "[data-evidence-modal-mode-param='new']" +
          "[data-evidence-modal-capability-stable-id-param='#{@cap_stable}']" +
          "[data-evidence-modal-level-ordinal-param='1']"
        )?.click();
      JS

      assert_selector "#evidence-modal-overlay", visible: true
      # Context block ties the form to the cell's behaviour.
      assert_text "Critical Thinking · Level 1"
      assert_text "Synthesises information"
      assert_equal "#{@cap_stable}|1", page.evaluate_script(
        "document.querySelector(\"#evidence-modal input[name='evidence[primary_cell]']\")?.value"
      )
    end

    # The modal holds unsaved input — a stray background click must NOT discard
    # it; Esc still closes it (accessibility). See modal_controller.js.
    should "stay open on an outside click but close on Esc" do
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      page.execute_script(<<~JS)
        document.querySelector(
          "[data-evidence-modal-mode-param='new']" +
          "[data-evidence-modal-capability-stable-id-param='#{@cap_stable}']" +
          "[data-evidence-modal-level-ordinal-param='1']"
        )?.click();
      JS
      assert_selector "#evidence-modal-overlay", visible: true
      assert_selector "#evm-content", visible: true

      page.execute_script(<<~JS)
        document.querySelector("#evidence-modal-overlay").dispatchEvent(
          new MouseEvent("click", { bubbles: true, cancelable: true, view: window })
        );
      JS
      assert_selector "#evidence-modal-overlay", visible: true, wait: 1

      find("#evm-content").send_keys(:escape)
      assert_no_selector "#evidence-modal-overlay", visible: true
    end
  end

  context "level chip activity indicators" do
    # The chip fill carries the rating language (solid colour, or a
    # diagonal split when perspectives disagree); content is a separate
    # glyph language in the bottom-right corner — a paperclip when the
    # cell has evidence, a speech bubble when it has a comment. Both
    # appear together when both kinds exist. Glyphs (not coloured dots)
    # so they can't be mistaken for the frequency palette.
    should "render an evidence glyph when the cell has evidence" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.record_evidence(
          @person.id, @framework_id, SecureRandom.uuid_v7,
          capability_stable_id: @cap_stable, level_ordinal: 1,
          source: "self", evidence_type: "project_outcome",
          title: "Q1 launch", content: "Shipped Q1.",
          author_id: @person.id, valence: "demonstrated"
        )
      end

      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      chip = find("#cell-#{@cap_stable}-1")
      assert chip.has_css?("[data-glyph='evidence']", visible: :all),
        "expected the level chip to show an evidence glyph"
    end

    should "render a comment glyph when the cell has a comment" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.post_comment(
          @person.id, @framework_id, SecureRandom.uuid_v7,
          commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
          capability_stable_id: @cap_stable, level_ordinal: 1,
          author_id: @person.id, body: "Lots of work here."
        )
      end

      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      chip = find("#cell-#{@cap_stable}-1")
      assert chip.has_css?("[data-glyph='comment']", visible: :all),
        "expected the level chip to show a comment glyph"
    end

    should "render no glyph when the cell has neither evidence nor comments" do
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      chip = find("#cell-#{@cap_stable}-1")
      assert chip.has_no_css?("[data-glyph='evidence']", wait: 1),
        "did not expect an evidence glyph on a cell without evidence"
      assert chip.has_no_css?("[data-glyph='comment']", wait: 1),
        "did not expect a comment glyph on a cell without comments"
    end
  end
end
