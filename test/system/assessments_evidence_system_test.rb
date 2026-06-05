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
          author_id: @person.id
        )
      end
    end

    # Kebab → Edit opens the modal with current field values, PATCH lands,
    # card re-renders with the new content and an "edited" footer. Same
    # JS-dispatched-click approach as the relink test — the hover-revealed
    # kebab is hostile to Capybara's pointer-click on starved CI runners.
    should "open prefilled, submit a change, and stamp edited_at on the card" do
      visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
      wait_for_stimulus "evidence-edit-form"
      assert_selector "#evidence-#{@evidence_id}", visible: true
      assert_selector "#evidence-#{@evidence_id} [data-controller~='dropdown'][data-connected]", visible: :all
      assert_selector "#evidence-#{@evidence_id} [role='menuitem']", text: "Edit", visible: :all

      page.execute_script(<<~JS)
        document.querySelector(
          "#evidence-#{@evidence_id} [data-action*='evidence-edit-form#open']"
        ).click();
      JS
      assert_selector "#evidence-edit-form-modal", visible: true

      title_val, content_val, type_val = page.evaluate_script(<<~JS)
        (() => {
          const f = document.querySelector("#evidence-edit-form-modal form");
          return [
            f.querySelector("#evidence_edit_title_field").value,
            f.querySelector("#evidence_edit_content_field").value,
            f.querySelector("#evidence_edit_type_field").value
          ];
        })()
      JS
      assert_equal "Original title", title_val
      assert_equal "Original content.", content_val
      assert_equal "project_outcome", type_val

      page.execute_script(<<~JS)
        const f = document.querySelector("#evidence-edit-form-modal form");
        f.querySelector("#evidence_edit_title_field").value = "Updated title";
        f.querySelector("#evidence_edit_content_field").value = "Revised content.";
        f.querySelector("#evidence_edit_type_field").value = "code_review";
        f.requestSubmit();
      JS

      # The post-PATCH redirect carries capability + category + level_ordinal,
      # which lands the page back in the focused-cell state the user
      # triggered the edit from. Sync on `category=` — only the redirect
      # adds it, so this can't match the pre-submit URL.
      assert_current_path(/category=#{@cat_id}/)
      # Cell focus preserved — the updated content and "edited" footer
      # are visible immediately without a second visit.
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
          content: "Solid collaborator.", author_id: peer.id
        )

        visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
        wait_for_stimulus "evidence-edit-form"
        assert_selector "#evidence-#{other_evidence_id}", visible: true
        # The author's own item carries an Edit menuitem; the peer-authored
        # one must not.
        assert_no_selector "#evidence-#{other_evidence_id} [role='menuitem']", text: "Edit", visible: :all
      end
    end
  end

  context "evidence modal" do
    # The full create flow is covered end-to-end by the integration test in
    # test/controllers/assessments/evidence_controller_test.rb. The system
    # test's unique value is asserting the Stimulus wiring: the `+ Add`
    # affordance next to the EVIDENCE header inside the matrix turbo-frame
    # actually opens the modal hosted on the page wrapper, and the
    # capability + level coords are primed correctly.
    should "open with the cell's capability and level pre-populated" do
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      # The "+ Add evidence" button lives inside the auto-focused level's
      # expansion panel. Card layout: every card auto-focuses the
      # person's level by default, so the button is visible without
      # any further interaction. JS-dispatched click bypasses Selenium's
      # synthetic pointer click which can be lost on starved CI.
      page.execute_script(<<~JS)
        const btn = document.querySelector(
          "[data-action~='click->modal#open']" +
          "[data-evidence-form-capability-stable-id-param='#{@cap_stable}']" +
          "[data-evidence-form-level-ordinal-param='1']"
        );
        btn?.click();
      JS

      # Modal is hosted on the page wrapper; opening flips the modal's
      # `hidden`/`flex` classes. The form's hidden capability + level
      # inputs get populated from the Stimulus params on open.
      assert_selector "#evidence-form-modal.flex", visible: true
      assert_equal @cap_stable, page.evaluate_script(
        "document.querySelector(\"#evidence-form-modal input[name='evidence[capability_stable_id]']\")?.value"
      )
      assert_equal "1", page.evaluate_script(
        "document.querySelector(\"#evidence-form-modal input[name='evidence[level_ordinal]']\")?.value"
      )
    end
  end

  context "level chip activity indicators" do
    # The level chip already shows: green ✓ for a rating, amber dot for
    # cross-perspective divergence, YOU pill at the person's level. The
    # dots in the bottom-right corner extend that vocabulary: a slate
    # dot when there's evidence on the cell, a violet dot when there's
    # a comment. Both appear together when both kinds exist.
    should "render a slate dot when the cell has evidence" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.record_evidence(
          @person.id, @framework_id, SecureRandom.uuid_v7,
          capability_stable_id: @cap_stable, level_ordinal: 1,
          source: "self", evidence_type: "project_outcome",
          title: "Q1 launch", content: "Shipped Q1.",
          author_id: @person.id
        )
      end

      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      chip = find("#cell-#{@cap_stable}-1")
      assert chip.has_css?(".bg-slate-500", visible: :all),
        "expected the level chip to show an evidence dot"
    end

    should "render a violet dot when the cell has a comment" do
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
      assert chip.has_css?(".bg-violet-500", visible: :all),
        "expected the level chip to show a comment dot"
    end

    should "render no dot when the cell has neither evidence nor comments" do
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      chip = find("#cell-#{@cap_stable}-1")
      assert chip.has_no_css?(".bg-slate-500", wait: 1),
        "did not expect an evidence dot on a cell without evidence"
      assert chip.has_no_css?(".bg-violet-500", wait: 1),
        "did not expect a comment dot on a cell without comments"
    end
  end
end
