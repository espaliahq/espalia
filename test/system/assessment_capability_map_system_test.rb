# frozen_string_literal: true

require "application_system_test_case"

# The capability radar in the hero, and the map it opens, on a framework
# shaped nothing like the default: two categories, a ladder with its own codes
# and a gap between ordinals.
class AssessmentCapabilityMapSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  MAP = "##{Views::Assessments::CapabilityMapModal::ID}".freeze
  TRIGGER = "button[data-modal-target-id='#{Views::Assessments::CapabilityMapModal::ID}']".freeze

  # Rated at PM2, the assessed level.
  CAPABILITIES = {
    "Discovery" => [ "Product sense", "consistent" ],
    "Prioritisation" => [ "Product sense", "occasional" ],
    "Stakeholders" => [ "Influence", "consistent" ]
  }.freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Robin Product")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      handler = Frameworks::CommandHandler.new
      framework_id = SecureRandom.uuid_v7
      handler.create_framework(framework_id, "Product Ladder")

      rf_id = SecureRandom.uuid_v7
      role_id = SecureRandom.uuid_v7
      handler.add_role_family(framework_id, rf_id, "Product")
      handler.add_role(framework_id, role_id, rf_id, "Product Manager", "PM", "ic")
      levels = { 10 => "PM1", 20 => "PM2", 40 => "PM4" }
      level_ids = levels.to_h { |ordinal, _| [ ordinal, SecureRandom.uuid_v7 ] }
      levels.each_with_index do |(ordinal, code), i|
        handler.add_level(framework_id, level_ids[ordinal], role_id, ordinal, "Level #{code}", code, is_entry: i.zero?)
      end

      categories = CAPABILITIES.values.map(&:first).uniq.each_with_index.to_h do |name, i|
        id = SecureRandom.uuid_v7
        handler.add_capability_category(framework_id, id, name, ordinal: i + 1)
        [ name, id ]
      end

      @stable_ids = CAPABILITIES.to_h do |name, (category, _)|
        cap_id = SecureRandom.uuid_v7
        stable_id = SecureRandom.uuid_v7
        handler.add_capability(framework_id, cap_id, stable_id, categories.fetch(category), name)
        handler.create_capability_role_binding(framework_id, SecureRandom.uuid_v7, cap_id, role_id)
        levels.each do |ordinal, code|
          handler.set_behavioural_expectation(framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                              cap_id, ordinal, "#{name} at #{code}")
        end
        [ name, stable_id ]
      end
      handler.publish_version(framework_id, "test")

      pd_handler = PersonDevelopment::CommandHandler.new
      pd_handler.assign_to_framework(@person.id, framework_id, role_id, level_ids[20])
      cycle_id = @cycle_id = SecureRandom.uuid_v7
      cycle_handler = AssessmentCycles::CommandHandler.new
      cycle_handler.define_cycle(cycle_id, framework_id, "H2 Review", "regular", 1, defined_by: @person.id)
      cycle_handler.enroll(cycle_id, @person.id, enrolled_by: @person.id)
      CAPABILITIES.each do |name, (_, frequency)|
        pd_handler.rate_self(@person.id, framework_id, @stable_ids.fetch(name),
                             level_ordinal: 20, frequency: frequency, cycle_id: cycle_id)
      end

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end

    sign_in_as(@user)
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
    should "open the map from the hero and jump from a lane to its capability on #{label}" do
      page.driver.browser.manage.window.resize_to(*size)
      visit assessment_path(@assignment)
      assert_selector "#{TRIGGER} [data-radar-key] li", text: "Influence", visible: true
      open_map

      within(MAP) do
        assert_text "You at PM2"
        assert_selector "[data-capability-lane]", count: 3
        assert_selector "[data-capability-lane-group]", text: "Influence"
        assert_selector "[data-capability-lane='2']", text: "PM1 + 67% to PM2"
      end

      click_selector_with_js_fallback("#{MAP} [data-capability-lane='3']", expect_selector: focused_card("Stakeholders"))
      assert_no_selector MAP, visible: true
    end
  end

  should "jump from a spoke to its capability" do
    open_map

    spoke = "#{MAP} svg a[href='#cell-#{@stable_ids.fetch('Discovery')}-20']"
    click_selector_with_js_fallback(spoke, expect_selector: focused_card("Discovery"))
    assert_no_selector MAP, visible: true
  end

  should "move focus to the capability's card after a jump from the map" do
    open_map
    page.execute_script(%(document.querySelector("#{MAP} [data-capability-lane='3']").focus()))
    click_selector_with_js_fallback("#{MAP} [data-capability-lane='3']", expect_selector: focused_card("Stakeholders"))

    assert_selector "#{focused_card('Stakeholders')}:focus"
  end

  should "leave focus where the reader moves it straight after a jump from the map" do
    open_map
    click_selector_with_js_fallback("#{MAP} [data-capability-lane='3']", expect_selector: "#{focused_card('Stakeholders')}:focus")
    page.execute_script("document.querySelector(\"#{TRIGGER}\").focus()")

    # Past the matrix's settle pass, which once took focus back to the card.
    sleep 1
    assert_selector "#{TRIGGER}:focus", visible: :all
  end

  should "leave focus alone when the reader drops it straight after a jump from the map" do
    open_map
    click_selector_with_js_fallback("#{MAP} [data-capability-lane='3']", expect_selector: "#{focused_card('Stakeholders')}:focus")
    # After the modal's last focus-return pass (300ms after the click), before the matrix's settle pass (600ms after the card).
    sleep 0.35
    page.execute_script("document.activeElement.blur()")

    sleep 1
    assert_no_selector "#{focused_card('Stakeholders')}:focus"
  end

  should "show the folded band again while the radar trigger has keyboard focus" do
    visit assessment_path(@assignment)
    assert_selector "turbo-frame#assessment-scoring[complete]", visible: :all
    band_height = "Math.round(document.querySelector(\"#{TRIGGER}\").closest('.hero-collapsible').getBoundingClientRect().height)"
    page.execute_script("window.scrollTo(0, 400)")
    wait_until("the band folds") { page.evaluate_script(band_height).zero? }

    page.execute_script("document.querySelector(\"#{TRIGGER}\").focus()")
    wait_until("the band unfolds") { page.evaluate_script(band_height).positive? }

    page.execute_script("document.querySelector(\"#{TRIGGER}\").blur()")
    wait_until("the band folds again") { page.evaluate_script(band_height).zero? }
  end

  should "stay open, and update, when a rating lands while the map is open" do
    open_map
    assert_selector "#{MAP} [data-capability-lane='2']", text: "PM1 + 67% to PM2"
    page.execute_script("document.getElementById('#{Views::Assessments::CapabilityMapModal::ID}').dataset.kept = 'yes'")
    rate_behind_map("Prioritisation", "consistent")

    assert_selector "#{MAP}[data-kept='yes'] [data-capability-lane='2']", text: "PM2 met", visible: true
    assert_equal "hidden", page.evaluate_script("document.body.style.overflow")
  end

  should "update an open map, keeping it open and its lane focused, when someone else's rating arrives" do
    open_map
    assert_selector "turbo-cable-stream-source[connected]", visible: :all
    wait_for_stimulus "assessment-sync"
    wait_for_stimulus "capability-map"
    page.execute_script(<<~JS)
      document.getElementById("#{Views::Assessments::CapabilityMapModal::ID}").dataset.kept = "yes"
      document.querySelector("#{MAP} [data-capability-lane='2']").focus()
    JS

    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.rate_self(
        @person.id, @assignment.framework_id, @stable_ids.fetch("Prioritisation"),
        level_ordinal: 20, frequency: "consistent", cycle_id: @cycle_id
      )
    end

    assert_selector "#{MAP}[data-kept='yes'] [data-capability-lane='2']", text: "PM2 met", visible: true
    assert_selector "#{MAP} [data-capability-lane='2']:focus"
    assert_equal "hidden", page.evaluate_script("document.body.style.overflow")
  end

  should "keep focus and scroll on the lane being read when a rating lands" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    open_map
    wait_for_stimulus "capability-map"
    scrolled = page.evaluate_script(<<~JS)
      (() => {
        const lane = document.querySelector("#{MAP} [data-capability-lane='2']")
        lane.focus()
        let scroller = lane.parentElement
        while (scroller.scrollHeight <= scroller.clientHeight) scroller = scroller.parentElement
        scroller.dataset.scroller = "true"
        scroller.scrollTop = 120
        return scroller.scrollTop
      })()
    JS
    assert_operator scrolled, :>, 0, "the map must scroll on a phone, or keeping its scroll proves nothing"

    rate_behind_map("Prioritisation", "consistent")

    assert_selector "#{MAP} [data-capability-lane='2']:focus", text: "PM2 met"
    assert_equal scrolled, page.evaluate_script("document.querySelector('[data-scroller]').scrollTop")
  end

  should "light a spoke's lane while the spoke is pointed at" do
    open_map
    wait_for_stimulus "capability-map"

    page.execute_script(<<~JS)
      document.querySelector("#{MAP} svg [data-capability-map-key='1'] line")
        .dispatchEvent(new MouseEvent("mouseover", { bubbles: true }))
    JS
    assert_selector "#{MAP} [data-capability-lane='1'][data-hot='true']"
    assert_no_selector "#{MAP} [data-capability-lane='2'][data-hot='true']"

    page.execute_script(<<~JS)
      document.querySelector("#{MAP} svg [data-capability-map-key='1'] line")
        .dispatchEvent(new MouseEvent("mouseout", { bubbles: true }))
    JS
    assert_no_selector "#{MAP} [data-hot='true']"
  end

  should "keep a focused spoke's lane lit after the pointer leaves it" do
    open_map
    wait_for_stimulus "capability-map"

    spoke_event = ->(type, klass) {
      page.execute_script(<<~JS)
        document.querySelector("#{MAP} svg [data-capability-map-key='1'] line")
          .dispatchEvent(new #{klass}("#{type}", { bubbles: true }))
      JS
    }
    spoke_event.call("focusin", "FocusEvent")
    spoke_event.call("mouseover", "MouseEvent")
    spoke_event.call("mouseout", "MouseEvent")
    assert_selector "#{MAP} [data-capability-lane='1'][data-hot='true']"

    spoke_event.call("focusout", "FocusEvent")
    assert_no_selector "#{MAP} [data-hot='true']"
  end

  private

  def open_map
    visit assessment_path(@assignment)
    assert_selector TRIGGER
    assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
    wait_for_stimulus "modal"
    click_selector_with_js_fallback(TRIGGER, expect_selector: "#{MAP} [data-capability-lane]")
  end

  # Submits a self-rating through the matrix's own form while the map covers it.
  def rate_behind_map(name, frequency)
    stable_id = @stable_ids.fetch(name)
    assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
    assert_selector "form input[name='rating[capability_stable_id]'][value='#{stable_id}']", visible: :all
    page.execute_script(<<~JS)
      [...document.querySelectorAll("form")].find((f) =>
        f.querySelector("input[name='rating[capability_stable_id]'][value='#{stable_id}']") &&
        f.querySelector("input[name='rating[level_ordinal]'][value='20']") &&
        f.querySelector("input[name='rating[frequency]'][value='#{frequency}']") &&
        !f.querySelector("input[name='rating[confirm]'], input[name='rating[clear]']")).requestSubmit()
    JS
  end

  def focused_card(name)
    "[data-matrix-target='card'][data-capability-stable-id='#{@stable_ids.fetch(name)}'][data-focused='true']"
  end

  # Retries the block until it returns truthy, failing with the message after Capybara's wait.
  def wait_until(message)
    page.document.synchronize { yield || raise(Capybara::ExpectationNotMet, "timed out waiting until #{message}") }
  end
end
