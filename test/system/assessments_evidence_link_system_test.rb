# frozen_string_literal: true

require "application_system_test_case"

# Evidence multi-linkage: the kebab "Link to another capability" action
# attaches one piece of evidence to a second capability × level, and
# "Remove from this cell" is greyed out while it has only one link.
class AssessmentsEvidenceLinkSystemTest < ApplicationSystemTestCase
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
      handler.create_framework(@framework_id, "Test FW")

      rf_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, @role_id, rf_id, "Engineer", "E", "ic")
      @level_id = SecureRandom.uuid_v7
      handler.add_level(@framework_id, @level_id, @role_id, 1, "Engineer 1", "E1", is_entry: true)

      @cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)

      @cap1_id = SecureRandom.uuid_v7
      @cap1_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap1_id, @cap1_stable, @cat_id, "Critical Thinking")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, @cap1_id, @role_id, weight: 1.0
      )
      handler.set_behavioural_expectation(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap1_id, 1, "Synthesises"
      )

      @cap2_id = SecureRandom.uuid_v7
      @cap2_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap2_id, @cap2_stable, @cat_id, "Problem Solving")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, @cap2_id, @role_id, weight: 1.0
      )
      handler.set_behavioural_expectation(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap2_id, 1, "Decomposes"
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
        capability_stable_id: @cap1_stable, level_ordinal: 1, source: "self",
        evidence_type: "project_outcome", title: "Cap1 launch",
        content: "Done.", author_id: @person.id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end

    sign_in_as(@user)
  end

  context "kebab menu + link" do
    should "link evidence to a second capability and show the also-linked indicator" do
      # Evidence rendering is gated on cell focus (`data-focused="true"`
      # on the expanded `<td>`), so deep-link to the cell.
      visit assessment_path(@assignment, capability: @cap1_stable, level_ordinal: 1)
      wait_for_stimulus "evidence-link-form"
      assert_selector "#evidence-#{@evidence_id}", visible: true
      assert_selector "#evidence-#{@evidence_id} [data-controller~='dropdown'][data-connected]", visible: :all

      # The menu lives in an opacity-0 hover wrapper behind useTransition —
      # assert the items exist in the DOM and drive the action directly.
      assert_selector "#evidence-#{@evidence_id} [role='menuitem']",
                      text: "Link to another capability", visible: :all
      assert_selector "#evidence-#{@evidence_id} [role='menuitem']", text: "Withdraw", visible: :all
      # With only one link, "Remove from this cell" is rendered disabled.
      assert_selector "#evidence-#{@evidence_id} [role='menuitem'][aria-disabled='true']",
                      text: "Remove from this cell", visible: :all

      page.execute_script(<<~JS)
        document.querySelector(
          "#evidence-#{@evidence_id} [data-action*='evidence-link-form#open']"
        ).click();
      JS
      assert_selector "#evidence-link-modal", visible: true

      # Submit a link to cap2.
      page.execute_script(<<~JS)
        const f = document.querySelector("#evidence-link-modal form");
        f.querySelector("#evidence_link_capability_field").value = "#{@cap2_stable}";
        f.querySelector("#evidence_link_level_field").value = "1";
        f.querySelector("#evidence_link_rationale_field").value = "Also applies";
        f.requestSubmit();
      JS

      assert_text "Also linked to 1 other place"

      ActsAsTenant.with_tenant(@tenant) do
        links = EvidenceLink.active.where(evidence_id: @evidence_id)
          .pluck(:capability_stable_id, :level_ordinal)
        assert_includes links, [ @cap1_stable, 1 ]
        assert_includes links, [ @cap2_stable, 1 ]
      end
    end
  end
end
