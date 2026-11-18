# frozen_string_literal: true

require "application_system_test_case"

# The capability radar in the hero, and the map it opens, on a framework
# shaped nothing like the default: two categories, a ladder with its own codes,
# a gap between ordinals and one level more than the map zooms to.
class AssessmentCapabilityMapSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  MAP = "##{Views::Assessments::CapabilityMapModal::ID}".freeze
  TRIGGER = "button[data-modal-target-id='#{Views::Assessments::CapabilityMapModal::ID}']".freeze

  # Rated at PM2, the assessed level, except Negotiation.
  CAPABILITIES = {
    "Discovery" => [ "Product sense", "consistent" ],
    "Prioritisation" => [ "Product sense", "occasional" ],
    "Stakeholders" => [ "Influence", "consistent" ],
    "Negotiation" => [ "Influence", nil ]
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
      @role_id = role_id
      levels = { 10 => "PM1", 20 => "PM2", 40 => "PM4", 50 => "PM5" }
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
      @categories = categories

      pd_handler = PersonDevelopment::CommandHandler.new
      pd_handler.assign_to_framework(@person.id, framework_id, role_id, level_ids[20])
      cycle_id = @cycle_id = SecureRandom.uuid_v7
      cycle_handler = AssessmentCycles::CommandHandler.new
      cycle_handler.define_cycle(cycle_id, framework_id, "H2 Review", "regular", 1, defined_by: @person.id)
      cycle_handler.enroll(cycle_id, @person.id, enrolled_by: @person.id)
      CAPABILITIES.each do |name, (_, frequency)|
        next unless frequency

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
        assert_selector "[data-capability-lane]", count: 4
        assert_selector "[data-capability-lane-group]", text: "Influence"
        assert_selector "[data-capability-lane='2']", text: "PM1 + 67% to PM2"
      end

      click_selector_with_js_fallback("#{MAP} [data-capability-lane='3']", expect_selector: focused_card("Stakeholders"))
      assert_no_selector MAP, visible: true
    end
  end

  should "break the radar's web at an unrated capability, which its lane calls not rated" do
    open_map

    within(MAP) do
      assert_selector "[data-capability-lane='4']", text: "Not rated"
      assert_no_selector "svg polygon[data-radar-web]", visible: :all
      assert_selector "svg polyline[data-radar-web]", count: 1, visible: :all
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

  context "compared with the person's level" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        snapshot = LevelComparisonSnapshot.create!(tenant: @tenant, taken_on: Date.new(2026, 11, 1))
        { 10 => [ 5, 1.0 ], 20 => [ 6, 0.5 ] }.each do |ordinal, (size, median)|
          snapshot.groups.create!(tenant: @tenant, framework_id: @assignment.framework_id, role_id: @role_id,
                                  level_ordinal: ordinal, group_size: size,
                                  capability_medians: @stable_ids.values.index_with { median },
                                  category_medians: @categories.values.index_with { median })
        end
      end
    end

    [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
      should "compare the person's blades with their level's medians, and a level below, on #{label}" do
        page.driver.browser.manage.window.resize_to(*size)
        open_map
        wait_for_stimulus "capability-map"
        click_selector_with_js_fallback("#{MAP} [role='tab']:not([aria-selected='true'])", expect_selector: "#{MAP} [data-comparison-lane]")

        within(MAP) do
          assert_text "as of 1 Nov 2026"
          assert_selector "[data-comparison-lane='3'] [data-comparison-scores]", text: "You 100% · PM2s 50%"
          assert_selector "svg [data-blade-median]", count: 4, visible: :all
          assert_selector "[data-comparison-level='PM4'][disabled]", text: "fewer than 5"
        end
        assert_blades_above_lanes if label == "mobile"
        assert_no_sideways_overflow

        click_selector_with_js_fallback("#{MAP} [data-comparison-level='PM1']", expect_selector: "#{MAP} [data-level-comparison='PM1']")
        assert_selector "#{MAP} [data-comparison-lane='3'] [data-comparison-scores]", text: "PM1s 100%"
      end
    end

    [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
      should "keep the person's score on a capability the snapshot predates, with no group line, on #{label}" do
        ActsAsTenant.with_tenant(@tenant) do
          group = LevelComparisonGroup.find_by!(role_id: @role_id, level_ordinal: 20)
          group.update!(capability_medians: group.capability_medians.except(@stable_ids.fetch("Stakeholders")))
        end
        page.driver.browser.manage.window.resize_to(*size)
        open_map
        wait_for_stimulus "capability-map"
        click_selector_with_js_fallback("#{MAP} [role='tab']:not([aria-selected='true'])", expect_selector: "#{MAP} [data-comparison-lane]")

        within(MAP) do
          assert_selector "[data-comparison-lane='3'] [data-comparison-scores]", text: "You 100% · PM2s no score"
          assert_selector "svg [data-blade-median]", count: 3, visible: :all
        end
        assert_no_sideways_overflow
      end
    end

    should "name the person on every lane when their manager compares them" do
      manager_user = FactoryBot.create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        manager = FactoryBot.create(:person, tenant: @tenant, email: manager_user.email, name: "Morgan Manager")
        FactoryBot.create(:tenant_user, tenant: @tenant, user: manager_user, person: manager)
        @person.update!(manager:)
        CAPABILITIES.each do |name, (_, frequency)|
          next unless frequency

          PersonDevelopment::CommandHandler.new.rate_as_manager(
            @person.id, @assignment.framework_id, @stable_ids.fetch(name),
            level_ordinal: 20, frequency:, cycle_id: @cycle_id, rated_by_id: manager.id
          )
        end
      end
      Capybara.reset_sessions!
      sign_in_as(manager_user)

      open_map
      wait_for_stimulus "capability-map"
      click_selector_with_js_fallback("#{MAP} [role='tab']:not([aria-selected='true'])", expect_selector: "#{MAP} [data-comparison-lane]")

      assert_selector "#{MAP} [data-comparison-lane='3'] [data-comparison-scores]", text: "Robin Product 100% · PM2s 50%"
      assert_no_selector "#{MAP} [data-comparison-scores]", text: /\AYou /
      assert_selector "#{MAP} [role='tab'][aria-selected='true']", text: "Compared with their level"
      assert_selector "#{MAP} [data-comparison-level='PM2']", text: "PM2 (theirs)"
      clipped = page.evaluate_script(<<~JS)
        [...document.querySelectorAll("#{MAP} [data-comparison-scores]")].filter(e => e.scrollWidth > e.clientWidth).length
      JS
      assert_equal 0, clipped, "expected every lane's scores to fit beside the person's name"

      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      assert_selector "#{MAP} [data-comparison-lane='3']", text: "Stakeholders"
      squeezed = page.evaluate_script(<<~JS)
        [...document.querySelectorAll("#{MAP} [data-comparison-lane]")].filter(lane => {
          const name = lane.firstElementChild.getBoundingClientRect()
          return name.width < lane.getBoundingClientRect().width / 2
        }).length
      JS
      assert_equal 0, squeezed, "expected each capability's name to keep the lane's width on a phone, its scores below"
    end

    should "offer no comparison on a page read at another level" do
      ActsAsTenant.with_tenant(@tenant) do
        @stable_ids.each_value do |stable_id|
          PersonDevelopment::CommandHandler.new.rate_self(@person.id, @assignment.framework_id, stable_id,
                                                          level_ordinal: 10, frequency: "consistent", cycle_id: @cycle_id)
        end
      end
      visit assessment_path(@assignment, as_level: 10)
      assert_selector TRIGGER
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
      wait_for_stimulus "modal"
      click_selector_with_js_fallback(TRIGGER, expect_selector: "#{MAP} [data-capability-lane]")

      assert_no_selector "#{MAP} [role='tab']"
    end

    should "move between the tabs with the arrow keys" do
      open_map
      wait_for_stimulus "capability-map"
      page.execute_script("document.querySelector(\"#{MAP} [role='tab'][aria-selected='true']\").focus()")

      press_arrow("ArrowRight")
      assert_selector "#{MAP} [role='tab']:focus", text: "Compared with your level"
      press_arrow("ArrowLeft")
      assert_selector "#{MAP} [role='tab']:focus", text: "Capabilities"
    end

    should "reach the tab panel with Tab from the selected tab" do
      open_map
      wait_for_stimulus "capability-map"

      # A dispatched Tab performs no traversal, and the browser's own traversal is what's under test.
      find("#{MAP} [role='tab'][aria-selected='true']").send_keys(:tab) # rubocop:disable SystemTests/FlakeProneClick

      assert_selector "#{MAP} [role='tabpanel']:focus"
    end

    should "stay on the comparison, with the new score, when the person's own rating lands" do
      open_map
      wait_for_stimulus "capability-map"
      click_selector_with_js_fallback("#{MAP} [role='tab']:not([aria-selected='true'])", expect_selector: "#{MAP} [data-comparison-lane]")
      assert_selector "#{MAP} [data-comparison-lane='2'] [data-comparison-scores]", text: "You 67%"

      rate_behind_map("Prioritisation", "consistent")

      assert_selector "#{MAP} [data-comparison-lane='2'] [data-comparison-scores]", text: "You 100%"
      assert_selector "#{MAP} [role='tab'][aria-selected='true']", text: "Compared with your level"
    end

    # The first comparison is read before the rating lands and answers after it.
    should "end on the new score when the person's own rating lands while the comparison is still loading" do
      open_map
      wait_for_stimulus "capability-map"
      read = Operations::Assessments::LevelComparison.method(:call)
      first, computed, release = Queue.new, Queue.new, Queue.new
      first << true
      held_too_long = false
      held = lambda do |**args|
        result = read.call(**args)
        if first.pop(timeout: 0)
          computed << true
          held_too_long = release.pop(timeout: 15).nil?
        end
        result
      end

      Operations::Assessments::LevelComparison.stub(:call, held) do
        page.execute_script("document.querySelector(\"#{MAP} [role='tab']:not([aria-selected='true'])\").click()")
        assert computed.pop(timeout: 15), "expected the comparison to be read"
        rate_behind_map("Prioritisation", "consistent")
        assert_selector "#assessment-live-status", visible: :all, text: "Prioritisation"
        release << true

        assert_selector "#{MAP} [data-comparison-lane='2'] [data-comparison-scores]", text: "You 100%"
        assert_not held_too_long, "the first comparison answered before the rating landed, so the race never ran"
      ensure
        release << true
      end
    end
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

  should "zoom the radar and bars to a level picked above the lanes, keeping focus on its toggle" do
    open_map
    wait_for_stimulus "capability-map"
    within(MAP) do
      assert_selector "[data-radar-ring]", count: 2, visible: :all
      assert_no_selector "[data-radar-ring='PM5']", visible: :all
      assert_selector "#{zoom_toggle('PM2')}[aria-pressed='true']"
    end

    page.execute_script(%(document.querySelector("#{MAP} #{zoom_toggle('PM4')}").focus()))
    click_selector_with_js_fallback("#{MAP} #{zoom_toggle('PM4')}", expect_selector: "#{MAP} [data-radar-ring='PM5']")

    within(MAP) do
      assert_selector "#{zoom_toggle('PM4')}[aria-pressed='true']:focus"
      assert_no_selector "[data-radar-ring='PM2']", visible: :all
      assert_selector "[data-capability-lane='1'] span[style='width: 0.0%']", visible: :all
    end
  end

  should "keep a level's zoom when someone else's rating lands" do
    open_map
    assert_selector "turbo-cable-stream-source[connected]", visible: :all
    wait_for_stimulus "assessment-sync"
    wait_for_stimulus "capability-map"
    click_selector_with_js_fallback("#{MAP} #{zoom_toggle('PM4')}", expect_selector: "#{MAP} [data-radar-ring='PM5']")

    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.rate_self(
        @person.id, @assignment.framework_id, @stable_ids.fetch("Prioritisation"),
        level_ordinal: 20, frequency: "consistent", cycle_id: @cycle_id
      )
    end

    assert_selector "#{MAP} [data-capability-lane='2']", text: "PM2 met", visible: true
    assert_selector "#{MAP} #{zoom_toggle('PM4')}[aria-pressed='true']", visible: true
  end

  should "zoom out to every level from under the radar on a phone, and stay zoomed out when someone else's rating lands" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    open_map
    assert_selector "turbo-cable-stream-source[connected]", visible: :all
    wait_for_stimulus "assessment-sync"
    wait_for_stimulus "capability-map"
    assert_no_selector "#{MAP} #{zoom_toggle('PM2')}", visible: true

    click_selector_with_js_fallback("#{MAP} #{zoom_toggle('all')}", expect_selector: "#{MAP} [data-radar-ring='PM5']")
    assert_selector "#{MAP} #{zoom_toggle('all')}[aria-pressed='true']", visible: true

    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.rate_self(
        @person.id, @assignment.framework_id, @stable_ids.fetch("Prioritisation"),
        level_ordinal: 20, frequency: "consistent", cycle_id: @cycle_id
      )
    end

    assert_selector "#{MAP} [data-capability-lane='2']", text: "PM2 met", visible: true
    assert_selector "#{MAP} #{zoom_toggle('all')}[aria-pressed='true']", visible: true
    assert_selector "#{MAP} [data-radar-ring='PM5']", visible: :all

    click_selector_with_js_fallback("#{MAP} #{zoom_toggle('all')}[aria-pressed='true']",
                                    expect_selector: "#{MAP} #{zoom_toggle('all')}[aria-pressed='false']")
    assert_no_selector "#{MAP} [data-radar-ring='PM5']", visible: :all
  end

  private

  def zoom_toggle(key) = "[data-refresh-focus='zoom-#{key}']"

  # On a phone the blades stack above the lanes.
  def assert_blades_above_lanes
    stacked = page.evaluate_script(<<~JS)
      (() => {
        const blades = document.querySelector("#{MAP} [data-level-comparison] svg").getBoundingClientRect()
        const lane = document.querySelector("#{MAP} [data-comparison-lane]").getBoundingClientRect()
        return blades.bottom <= lane.top
      })()
    JS
    assert stacked, "expected the blades above the lanes"
  end

  # Dispatches the key from the focused tab, where a real keypress lands.
  def press_arrow(key)
    page.execute_script(<<~JS)
      document.activeElement.dispatchEvent(new KeyboardEvent("keydown", { key: "#{key}", bubbles: true, cancelable: true }))
    JS
  end

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
