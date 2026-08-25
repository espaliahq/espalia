# frozen_string_literal: true

require "application_system_test_case"

# Esc on the evidence modal must not silently discard typed input (audit
# issue #315): the overlay's dirty guard asks before closing. × / Cancel stay
# immediate — Esc is the accidental dismissal being guarded.
class AssessmentsEvidenceEscGuardSystemTest < ApplicationSystemTestCase
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

      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)

      cap_id = SecureRandom.uuid_v7
      @cap_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, cap_id, @cap_stable, cat_id, "Critical Thinking")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, cap_id, @role_id, weight: 1.0
      )
      handler.set_behavioural_expectation(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, cap_id, 1,
        "Synthesises information"
      )

      handler.publish_version(@framework_id, "test")

      level = FrameworkState::Level.find_by!(level_id: @level_id)
      pd_handler.assign_to_framework(@person.id, @framework_id, @role_id, level.level_id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end

    sign_in_as(@user)
  end

  # Opens the unified evidence modal in :new mode for the seeded cell and
  # types into "What happened?". Returns after the lazy frame has rendered.
  def open_modal_and_type(text)
    visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
    wait_for_stimulus "evidence-modal"
    assert_selector "[data-evidence-modal-mode-param='new']", visible: :all
    page.execute_script(
      "document.querySelector(\"[data-evidence-modal-mode-param='new']\").click();"
    )
    assert_selector "#evidence-modal-overlay", visible: true
    assert_selector "#evm-content", visible: true
    page.execute_script(<<~JS)
      const ta = document.querySelector("#evm-content");
      ta.value = #{text.to_json};
      ta.dispatchEvent(new Event("input", { bubbles: true }));
    JS
  end

  # Stubs window.confirm with a fixed answer and a call counter readable via
  # window.__confirmCalls (the suite's auto_confirm pattern, plus counting).
  def stub_confirm(answer)
    page.execute_script(
      "window.__confirmCalls = 0; window.confirm = () => { window.__confirmCalls++; return #{answer}; };"
    )
  end

  context "Esc with typed input" do
    should "keep the modal open and the text intact when the user declines" do
      open_modal_and_type("A paragraph of carefully-worded feedback")
      stub_confirm(false)
      find("body").send_keys(:escape)

      assert_selector "#evidence-modal-overlay", visible: true
      assert_equal 1, page.evaluate_script("window.__confirmCalls")
      assert_equal "A paragraph of carefully-worded feedback",
        page.evaluate_script("document.querySelector('#evm-content').value")
    end

    should "close when the user confirms the discard" do
      open_modal_and_type("Text I am willing to lose")
      stub_confirm(true)
      find("body").send_keys(:escape)

      assert_no_selector "#evidence-modal-overlay", visible: true
      assert_equal 1, page.evaluate_script("window.__confirmCalls")
    end
  end

  context "Esc with no typed input" do
    should "close immediately without asking" do
      visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
      wait_for_stimulus "evidence-modal"
      page.execute_script(
        "document.querySelector(\"[data-evidence-modal-mode-param='new']\").click();"
      )
      assert_selector "#evidence-modal-overlay", visible: true
      assert_selector "#evm-content", visible: true
      stub_confirm(false)
      find("body").send_keys(:escape)

      assert_no_selector "#evidence-modal-overlay", visible: true
      assert_equal 0, page.evaluate_script("window.__confirmCalls")
    end
  end
end
