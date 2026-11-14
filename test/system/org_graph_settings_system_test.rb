# frozen_string_literal: true

require "application_system_test_case"

# The Org Graph settings screen (#126), a panel at a time, at both widths.
class OrgGraphSettingsSystemTest < ApplicationSystemTestCase
  CENTRE = Hris::Field.new(id: "work.customColumns.column_centre", name: "Cost centre code", kind: :text)

  # Answers as a connected HiBob would, so nothing here reaches a real HRIS.
  FakeAdapter = Struct.new(:values) do
    def provider_name = "hibob"
    def catalogue_id(field_id) = field_id
    def field_catalogue = [ CENTRE ]
    def read_field(_field_id, kind:, alongside: nil) = values
  end

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      admin = FactoryBot.create(:person, tenant: @tenant, name: "Ada Admin")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, person: admin, role: :admin)
      @member = FactoryBot.create(:person, tenant: @tenant, name: "Mo Member")
      FactoryBot.create(:tenant_user, tenant: @tenant, person: @member, role: :member)
    end
  end

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |viewport, size|
    context "at #{viewport}" do
      setup do
        page.driver.browser.manage.window.resize_to(*size)
        sign_in_as(@admin_user)
      end

      should "reach the settings from the Units view" do
        visit tenant_org_graph_path
        assert_text "Units and who is in each"
        click_link_with_js_fallback("Settings", expect_text: "Org Graph settings")
        assert_no_sideways_overflow
      end

      should "add an editor and remove them again" do
        visit tenant_org_graph_settings_path
        within("#org-graph-editors") { assert_text "None yet." }

        select "Mo Member", from: "Person to make an editor"
        click_button_with_js_fallback("Add an editor", expect_text: "Mo Member may now edit the Org Graph.")
        within("#org-graph-editors") { assert_selector "li", text: "Mo Member" }
        assert_no_sideways_overflow
        screenshot("editors_#{viewport}")

        click_button_with_js_fallback("remove-editor-#{@member.id}", expect_text: "Mo Member may no longer edit the Org Graph.")
        within("#org-graph-editors") { assert_text "None yet." }
      end

      should "count the stale facts and change when a fact goes stale" do
        ActsAsTenant.with_tenant(@tenant) do
          OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
            .record_person(@member.id, provider: "espalia", effective_on: Date.current, employment_status: "employed",
                                       title: "Engineer")
          OrgFactAge.where(person_id: @member.id).update_all(checked_at: 45.days.ago)
        end

        visit tenant_org_graph_settings_path
        within("#org-graph-freshness") { assert_text "No fact is stale." }

        select "30 days", from: "Stale after"
        click_button_with_js_fallback("org-graph-freshness-save", expect_text: "A fact now counts as stale after 30 days.")
        within("#org-graph-freshness") do
          assert_text "1 fact is stale:"
          assert_text "Title: 1"
          assert_select "Stale after", selected: "30 days"
        end
        assert_no_sideways_overflow
        screenshot("freshness_#{viewport}")
      end

      should "set the retention period, count who is due, and turn the schedule on and off" do
        ActsAsTenant.with_tenant(@tenant) do
          leaver = FactoryBot.create(:person, tenant: @tenant, name: "Lee Leaver")
          handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
          handler.sync_person(leaver.id, provider: "espalia", effective_on: "2020-01-01", employment_status: "employed")
          handler.sync_person(leaver.id, provider: "espalia", effective_on: "2020-01-01", employment_status: "left",
                                         left_on: 2.years.ago.to_date)
        end

        visit tenant_org_graph_settings_path
        within("#org-graph-forgetting") { assert_text "Nobody reaches their date today." }

        select "1 year", from: "Forget leavers after"
        click_button_with_js_fallback("org-graph-retention-save",
                                      expect_text: "Leavers are now forgotten 1 year after they leave.")
        assert_selector "turbo-frame#org-graph-forgetting-due[complete]", visible: :all
        within("#org-graph-forgetting") { assert_text "1 person reaches their date today" }
        assert_no_sideways_overflow
        screenshot("forgetting_due_#{viewport}")

        click_button_with_js_fallback("org-graph-forgetting-on", expect_text: "Scheduled forgetting is on.")
        within("#org-graph-forgetting") { assert_text "Each leaver is forgotten once their date comes." }

        click_button_with_js_fallback("org-graph-forgetting-off", expect_text: "Scheduled forgetting is off.")
        assert_selector "turbo-frame#org-graph-forgetting-due[complete]", visible: :all
      end

      should "move a fact to the HRIS, preview a field and read it from there" do
        connect_hibob
        adapter = FakeAdapter.new({ "hb-1" => Hris::FieldValue.new(state: :value, id: nil, label: "CC-7") })

        Hris::BaseAdapter.stub(:for, adapter) do
          visit tenant_org_graph_settings_path
          within("#org-graph-fact-cost_centre") { assert_text "From Espalia" }

          select "HiBob", from: "Source of cost centre"
          click_button_with_js_fallback("org-graph-fact-save-cost_centre", expect_text: "Cost centre now comes from HiBob.")
          assert_selector "turbo-frame#org-graph-field-cost_centre[complete]", visible: :all

          select "Cost centre code", from: "HRIS field for the cost centre"
          click_button_with_js_fallback("org-graph-field-preview-cost_centre", expect_text: "Cost centre code as the cost centre")
          assert_no_sideways_overflow
          screenshot("fact_field_preview_#{viewport}")

          click_button_with_js_fallback("org-graph-field-use-cost_centre", expect_text: "the HiBob field you chose")
          assert_selector "turbo-frame#org-graph-field-cost_centre[complete]", visible: :all
          within("#org-graph-fact-cost_centre") { assert_select "HRIS field for the cost centre", selected: "Cost centre code (in use)" }
        end
      end

      should "read an empty level from an HRIS field and hold it in Espalia again" do
        connect_hibob
        tribe_id = SecureRandom.uuid_v7
        ActsAsTenant.with_tenant(@tenant) do
          OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
            .define_taxonomy([ { level_id: tribe_id, name: "Tribe" } ], effective_on: Date.current)
        end
        adapter = FakeAdapter.new({ "hb-1" => Hris::FieldValue.new(state: :value, id: "7", label: "Payments") })

        Hris::BaseAdapter.stub(:for, adapter) do
          visit tenant_org_graph_settings_path
          assert_selector "turbo-frame#org-graph-field-level-#{tribe_id}[complete]", visible: :all

          select "Cost centre code", from: "HRIS field for Tribe"
          click_button_with_js_fallback("org-graph-field-preview-level-#{tribe_id}", expect_text: "Cost centre code as the level")
          within("#org-graph-level-#{tribe_id}") { assert_text(/Payments\s*1 person/) }
          assert_no_sideways_overflow
          screenshot("level_field_preview_#{viewport}")

          click_button_with_js_fallback("org-graph-field-use-level-#{tribe_id}", expect_text: "Tribe is now read from the HiBob field you chose.")
          within("#org-graph-level-#{tribe_id}") { assert_text "From HiBob · 0 units" }

          click_button_with_js_fallback("org-graph-level-espalia-#{tribe_id}", expect_text: "Tribe now comes from Espalia.")
          within("#org-graph-level-#{tribe_id}") { assert_text "From Espalia · 0 units" }
        end
      end

      should "compare a level with units against an HRIS field, hand it over, and hand it back" do
        connect_hibob
        squad_id = SecureRandom.uuid_v7
        payments = SecureRandom.uuid_v7
        legacy = SecureRandom.uuid_v7
        ActsAsTenant.with_tenant(@tenant) do
          structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
          structure.claim_facts(OrgGraph::StructureAggregate::FACTS, "hibob", effective_on: "2026-01-01")
          structure.define_taxonomy([ { level_id: squad_id, name: "Squad" } ], effective_on: "2026-01-01")
          structure.create_unit(payments, "Payments", level_id: squad_id, effective_on: "2026-01-01")
          structure.create_unit(legacy, "Legacy", level_id: squad_id, effective_on: "2026-01-01")
          people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
          people.record_person(@member.id, provider: "hibob", effective_on: "2026-11-01", employment_status: "employed")
          people.set_membership(@member.id, payments, provider: "espalia", effective_on: "2026-11-01")
        end
        adapter = FakeAdapter.new({ "hb-1" => Hris::FieldValue.new(state: :value, id: nil, label: "Payments") })

        Hris::BaseAdapter.stub(:for, adapter) do
          visit tenant_org_graph_settings_path
          assert_selector "turbo-frame#org-graph-handover-frame-#{squad_id}[complete]", visible: :all

          within("#org-graph-handover") { select "Cost centre code", from: "HRIS field to hand Squad to" }
          click_button_with_js_fallback("org-graph-handover-compare-#{squad_id}", expect_text: "Call for Payments")
          assert_select "Call for Payments", selected: "Payments · 1 person"

          select "Retire it", from: "Call for Legacy"
          click_button_with_js_fallback("org-graph-handover-compare-#{squad_id}", expect_text: "With these calls")
          assert_no_sideways_overflow
          scroll_to find("#org-graph-handover-summary-#{squad_id}")
          screenshot("handover_compared_#{viewport}")

          click_button_with_js_fallback("org-graph-hand-over-#{squad_id}",
                                        expect_text: "Squad now comes from HiBob, and its memberships follow the HRIS.")
          assert_selector "turbo-frame#org-graph-handover-frame-#{squad_id}[complete]", visible: :all
          within("#org-graph-handover") { assert_text "HiBob supplies Squad: 1 unit and 1 membership." }
          scroll_to find("#org-graph-handover")
          screenshot("handback_#{viewport}")

          click_button_with_js_fallback("org-graph-hand-back-#{squad_id}",
                                        expect_text: "Squad now comes from Espalia. Its units and memberships stay as they are.")
        end
      end

      should "add a level and move it into place" do
        squad_id = SecureRandom.uuid_v7
        ActsAsTenant.with_tenant(@tenant) do
          structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
          structure.define_taxonomy([ { level_id: squad_id, name: "Squad" } ], effective_on: "2026-01-01")
          structure.create_unit(SecureRandom.uuid_v7, "Payments", level_id: squad_id, effective_on: "2026-01-01")
        end
        visit tenant_org_graph_settings_path

        js_fill_in "Name of the new level", with: "Guild"
        click_button_with_js_fallback("Add a level", expect_text: "Guild is now the bottom level.")
        assert_equal %w[Squad Guild], level_names
        guild_id = ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.find_by!(name: "Guild").id }
        assert_no_sideways_overflow
        screenshot("levels_added_#{viewport}")

        click_button_with_js_fallback("org-graph-level-up-#{guild_id}", expect_text: "Guild moved up.")
        assert_equal %w[Guild Squad], level_names
        within("#org-graph-level-#{guild_id}") { assert_no_button "Move Guild up" }
        assert_no_stolen_taps
        screenshot("levels_moved_#{viewport}")
      end

      should "remove a level no unit has ever held, after asking" do
        squad_id = SecureRandom.uuid_v7
        guild_id = SecureRandom.uuid_v7
        ActsAsTenant.with_tenant(@tenant) do
          structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
          structure.define_taxonomy([ { level_id: squad_id, name: "Squad" }, { level_id: guild_id, name: "Guild" } ],
                                    effective_on: "2026-01-01")
          structure.create_unit(SecureRandom.uuid_v7, "Payments", level_id: squad_id, effective_on: "2026-01-01")
        end
        visit tenant_org_graph_settings_path

        assert_no_selector "#org-graph-level-menu-#{squad_id}"
        click_button_with_js_fallback("org-graph-level-menu-#{guild_id}", expect_selector: "#org-graph-level-remove-#{guild_id}")
        click_button_with_js_fallback("org-graph-level-remove-#{guild_id}",
                                      expect_text: "No unit has ever sat at this level, so nothing else changes.")
        within("#org-graph-remove-level-#{guild_id}") do
          assert_text "No unit has ever sat at this level, so nothing else changes."
          screenshot("level_remove_asked_#{viewport}")
        end
        click_button_with_js_fallback("org-graph-level-remove-confirm-#{guild_id}", expect_text: "Guild is no longer a level.")
        assert_equal %w[Squad], level_names
        assert_no_sideways_overflow
        screenshot("level_removed_#{viewport}")
      end

      should "say plainly when forgetting has no key" do
        OrgGraph::Forgetting.stub(:key, nil) do
          visit tenant_org_graph_settings_path
          within("#org-graph-forgetting") do
            assert_text "Forgetting isn't set up"
            assert_no_button "Turn on scheduled forgetting"
          end
          screenshot("forgetting_no_key_#{viewport}")
        end
      end
    end
  end

  context "a level's menu at mobile" do
    setup do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      sign_in_as(@admin_user)
      @guild_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
          .define_taxonomy([ { level_id: SecureRandom.uuid_v7, name: "Squad" }, { level_id: @guild_id, name: "Guild" } ],
                           effective_on: "2026-01-01")
      end
      visit tenant_org_graph_settings_path
      assert_selector "#org-graph-level-#{@guild_id} [data-controller~='dropdown'][data-connected]", visible: :all
    end

    # A scroll's event fires on the next frame, so a tap that scrolls the
    # kebab into view can open the menu before that scroll is reported (#199).
    should "stay open when a scroll made before it opened is reported after" do
      page.execute_script(<<~JS, "org-graph-level-menu-#{@guild_id}")
        window.scrollTo(0, 0);
        window.scrollBy(0, 40);
        document.getElementById(arguments[0]).click();
      JS
      assert_operator page.evaluate_script("window.scrollY"), :>, 0, "the page must scroll for this to test anything"

      assert_selector "#org-graph-level-remove-#{@guild_id}", visible: true
      page.evaluate_async_script("requestAnimationFrame(() => requestAnimationFrame(arguments[0]))")
      assert_selector "#org-graph-level-remove-#{@guild_id}", visible: true, wait: 0
    end

    should "close when the page scrolls after it opens" do
      click_button_with_js_fallback("org-graph-level-menu-#{@guild_id}", expect_selector: "#org-graph-level-remove-#{@guild_id}")
      before = page.evaluate_script("window.scrollY")
      page.execute_script("window.scrollTo(0, window.scrollY > 20 ? 0 : 40)")
      assert_not_equal before, page.evaluate_script("window.scrollY"), "the page must scroll for this to test anything"

      assert_no_selector "#org-graph-level-remove-#{@guild_id}", visible: true
    end
  end

  private

  def level_names = all("#org-graph-levels li[id^='org-graph-level-'] p.font-medium").map(&:text)

  def connect_hibob
    hibob = FactoryBot.build(:tenant, :with_hibob_config)
    @tenant.update!(hris_config: hibob.hris_config, hris_credentials: hibob.hris_credentials)
    ActsAsTenant.with_tenant(@tenant) { @member.update!(hris_source: "hibob", external_id: "hb-1") }
  end
end
