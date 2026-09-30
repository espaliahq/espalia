# frozen_string_literal: true

require "test_helper"

# Per-role disclosure and the cell-level freeze, end to end (ADR-22): a
# manager's rating on a cell reaches the assessee only once alignment has
# started against a role that reads it, and a started role freezes its cells
# on every page — with the reason on the pill.
class AssessmentsRoleAlignmentDisclosureTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @fx = build_role_lens_framework(tenant: @tenant)
    @user = create(:user, password: "password123")
    @manager_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Morgan Manager")
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Alex Assessee", manager: @manager)
      create(:tenant_user, tenant: @tenant, user: @user, person: @person)
    end
    @assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    @pm_lens = { as_role: @fx.pm.role_id, as_level: 2 }

    [ @fx.shared, @fx.e_only, @fx.pm_only ].each { |capability| manager_rate(capability) }
  end

  context "before alignment against PM2" do
    should "keep the manager's ratings on PM-only cells from the assessee" do
      sign_in @user
      get assessment_path(@assignment, @pm_lens)

      assert_equal :self, controller.send(:assessment_context)
      assert_nil cell(@fx.pm_only)[:manager_frequency]
      assert_not_includes manager_rated_cells, @fx.pm_only.stable_id
    end
  end

  should "hide a calibration revisit on a PM-only cell until PM2 alignment starts" do
    ActsAsTenant.with_tenant(@tenant) do
      session = create(:calibration_session, tenant: @tenant, cycle_id: @cycle_id, framework_id: @fx.framework_id)
      PersonDevelopment::CommandHandler.new.request_rating_revisit(
        @person.id, @fx.framework_id, capability_stable_id: @fx.pm_only.stable_id, level_ordinal: 2,
        calibration_session_id: session.id, rater_id: @manager.id, note: "Compare with peers",
        session_name: session.name, requested_by_id: @manager.id
      )
    end
    sign_in @user
    get assessment_activity_path(@assignment)
    assert_empty response.parsed_body.css("li[data-kind='rating_revisit_requested']")

    start_alignment(@fx.pm)
    get assessment_activity_path(@assignment)
    assert_equal 1, response.parsed_body.css("li[data-kind='rating_revisit_requested']").size
  end

  context "once the manager starts alignment against PM2" do
    setup { start_alignment(@fx.pm) }

    should "read the PM2 lens as the alignment conversation, every PM2 cell disclosed" do
      sign_in @user
      get assessment_path(@assignment, @pm_lens)

      assert_equal :alignment, controller.send(:assessment_context)
      assert_equal "some", cell(@fx.pm_only)[:manager_frequency]
      assert_equal "some", cell(@fx.shared)[:manager_frequency]
      assert_includes manager_rated_cells, @fx.pm_only.stable_id
    end

    should "leave the E2 page's own cells private and editable" do
      sign_in @user
      get assessment_path(@assignment)

      assert_equal :self, controller.send(:assessment_context)
      assert_nil cell(@fx.e_only)[:manager_frequency]
      assert response.parsed_body.at_css("#rating-#{@fx.e_only.stable_id}-2 button"), "E2-only cell stays editable"
      assert_not_includes manager_rated_cells, @fx.e_only.stable_id
    end

    should "freeze the cell E2 shares with PM2 on the E2 page, and say why" do
      sign_in @user
      get assessment_path(@assignment)

      assert_equal "some", cell(@fx.shared)[:manager_frequency], "the shared cell is disclosed"
      pill = response.parsed_body.at_css("#rating-#{@fx.shared.stable_id}-2")
      assert_nil pill.at_css("button")
      assert_equal "Frozen — alignment against PM2 has started", pill.at_css("span[title]")["title"]
    end

    should "name the role on the feed entry and link it to the lens" do
      sign_in @user
      get assessment_activity_path(@assignment)

      entry = response.parsed_body.css("li[data-kind='alignment_started']")
        .find { |li| li.text.include?("against Product Manager · PM2") }
      assert entry, "expected a role-named alignment entry"
      assert_includes entry["data-lens-href"], "as_role=#{@fx.pm.role_id}"
    end

    should "show the manager every cell" do
      sign_in @manager_user
      get assessment_path(@assignment)

      assert_equal "some", cell(@fx.e_only)[:manager_frequency]
    end
  end

  context "the page around a lens role's alignment" do
    should "tell the manager their ratings are private and offer the start" do
      sign_in @manager_user
      get assessment_path(@assignment, @pm_lens)

      page = response.parsed_body
      assert_includes page.at_css("#assessment-lens-alignment").text,
                      "Your ratings here are private until you start alignment against PM2"
      assert page.at_css("button[data-modal-target-id='start-lens-alignment-modal']")
      form = page.at_css("#start-lens-alignment-modal form")
      assert_equal assessment_alignment_start_path(@assignment), form["action"]
      assert_equal @fx.pm.role_id, form.at_css("input[name='as_role']")["value"]
    end

    should "tell a rating delegate whose start it is, and offer none" do
      delegate_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        delegate = create(:person, tenant: @tenant, email: delegate_user.email)
        create(:tenant_user, tenant: @tenant, user: delegate_user, person: delegate)
        create(:manager_assessment_delegation, tenant: @tenant, person_id: @person.id,
               framework_id: @fx.framework_id, delegate_person_id: delegate.id)
      end
      sign_in delegate_user
      get assessment_path(@assignment, @pm_lens)

      assert_includes response.parsed_body.at_css("#assessment-lens-alignment").text,
                      "Your ratings here are private until Alex's manager starts alignment against PM2"
      assert_nil response.parsed_body.at_css("button[data-modal-target-id='start-lens-alignment-modal']")
    end

    should "offer the assessee no start" do
      sign_in @user
      get assessment_path(@assignment, @pm_lens)

      assert_nil response.parsed_body.at_css("#assessment-lens-alignment")
      assert_nil response.parsed_body.at_css("#start-lens-alignment-modal")
    end

    context "once started" do
      setup { start_alignment(@fx.pm) }

      should "show the assessee Aligning · PM2 on the list and the home page, linking into the lens" do
        sign_in @user
        lens_href = assessment_path(@assignment, as_role: @fx.pm.role_id, as_level: 2)

        get assessments_path
        chip = response.parsed_body.at_css("a[data-lens-alignment='PM2']")
        assert_equal "Aligning · PM2", chip.text
        assert_equal lens_href, chip["href"]

        get assessment_path(@assignment)
        assert_equal lens_href, response.parsed_body.at_css("a[data-lens-alignment='PM2']")["href"]

        get home_card_path(card: "assessment_progress", key: @cycle_id)
        assert_equal lens_href, response.parsed_body.at_css("a[data-lens-alignment='PM2']")["href"],
          "the home page's assessment card shows it too"
      end

      should "name the conversation's level on another level of the same role" do
        sign_in @manager_user
        get assessment_path(@assignment, as_role: @fx.pm.role_id, as_level: 3)

        assert_includes response.parsed_body.at_css("#assessment-lens-alignment").text, "against PM2"
        assert_nil response.parsed_body.at_css("#alignment-completion-control"),
          "PM3 isn't the level the PM2 gate counts"
      end

      should "give the manager PM2's own completion control" do
        sign_in @manager_user
        get assessment_path(@assignment, @pm_lens)

        assert_includes response.parsed_body.at_css("#assessment-lens-alignment").text, "Aligning with Alex against PM2"
        control = response.parsed_body.at_css("#alignment-completion-control")
        assert control, "the lens role's alignment has its own completion control"
        assert_nil response.parsed_body.at_css("button[data-modal-target-id='start-lens-alignment-modal']")
      end
    end
  end

  private

  def manager_rate(capability)
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.rate_as_manager(
        @person.id, @fx.framework_id, capability.stable_id,
        level_ordinal: 2, frequency: "some", cycle_id: @cycle_id, rated_by_id: @manager.id
      )
    end
  end

  def start_alignment(role)
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.start_alignment(
        @person.id, @fx.framework_id, @cycle_id, started_by_id: @manager.id, role_id: role.role_id, level_ordinal: 2
      )
    end
  end

  def manager_rated_cells
    get assessment_activity_path(@assignment)
    response.parsed_body.css("li[data-kind='manager_rated']").map { |li| li["data-capability-stable-id"] }
  end

  def matrix_data
    controller.instance_variable_get(:@matrix_data)
  end

  def cell(capability, ordinal: 2)
    matrix_data[:categories].flat_map { |c| c[:capabilities] }
      .find { |cap| cap[:capability].capability_id == capability.capability_id }
      .fetch(:cells).fetch(ordinal)
  end

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
