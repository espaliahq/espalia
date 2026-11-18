# frozen_string_literal: true

require "test_helper"

class AssessmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Test User")
      create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      # Build framework via factories
      framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: framework_id, name: "Engineering Growth")

      rf = create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      @role = create(:framework_role,
        role_family_id: rf.role_family_id, name: "Software Engineer", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")
      create(:framework_level, role_id: @role.role_id, ordinal: 1, title: "Junior", code: "E1")

      cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding,
        capability_id: @cap.capability_id, role_id: @role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 1, description: "Asks good questions")
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "Synthesises information")

      # Create assignment + define cycle + enroll via event projection
      handler = PersonDevelopment::CommandHandler.new
      cycle_handler = AssessmentCycles::CommandHandler.new
      handler.assign_to_framework(@person.id, framework_id, @role.role_id, @level.level_id)

      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, framework_id, "Q1 2026", "regular", 1)
      cycle_handler.enroll(@cycle_id, @person.id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end
  end

  context "GET /assessments" do
    should "render index with framework assignments" do
      sign_in @user
      get assessments_path

      assert_response :success
      assert_includes response.body, "Engineering Growth"
      assert_includes response.body, "My Assessments"
      # Untouched enrollment → the CTA invites a start, agreeing with the
      # "Not started" Self chip (issue #332).
      assert_includes response.body, "Start self-assessment"
    end

    should "flip the own-card CTA to Continue once a self rating lands" do
      # A second current-level capability, so one rating leaves the
      # self-assessment unfinished.
      ActsAsTenant.with_tenant(@tenant) do
        other = create(:framework_capability, category_id: @cap.category_id, name: "Execution")
        create(:framework_capability_role_binding, capability_id: other.capability_id, role_id: @role.role_id)
        create(:framework_behavioural_expectation, capability_id: other.capability_id, level_ordinal: 2)
      end
      rate(@cap, "consistent")

      sign_in @user
      get assessments_path

      assert_response :success
      assert_includes response.body, "Continue self-assessment"
      assert_not_includes response.body, "Start self-assessment"
    end

    should "offer a review once the self-assessment is ready for alignment" do
      rate(@cap, "consistent")

      sign_in @user
      get assessments_path

      assert_response :success
      assert_includes response.body, "Ready for alignment"
      assert_includes response.body, "Review self-assessment"
      assert_not_includes response.body, "Continue self-assessment"
    end

    should "ignore ratings outside the assessed role" do
      ActsAsTenant.with_tenant(@tenant) do
        create_out_of_scope_rating(person_id: @person.id, cycle: AssessmentCycle.find_by!(cycle_id: @cycle_id),
          level_ordinal: 2)
      end

      sign_in @user
      get assessments_path

      assert_response :success
      assert_includes response.body, "Start self-assessment"
    end

    should "show the capability blades on the own card once it has a score" do
      rate(@cap, "consistent")

      sign_in @user
      get assessments_path

      assert_select "[data-capability-blades] svg[aria-label='1 of 1 capabilities met at E2']", count: 1
    end

    should "show nothing in the blades' place before the card has a score" do
      sign_in @user
      get assessments_path

      assert_response :success
      assert_select "[data-capability-blades]", count: 0
      assert_not_includes response.body, "met at E2"
    end

    should "draw no blades from ratings outside the assessed role" do
      ActsAsTenant.with_tenant(@tenant) do
        create_out_of_scope_rating(person_id: @person.id, cycle: AssessmentCycle.find_by!(cycle_id: @cycle_id),
          level_ordinal: 2)
      end

      sign_in @user
      get assessments_path

      assert_response :success
      assert_select "[data-capability-blades]", count: 0
    end

    should "redirect unauthenticated users to sign in" do
      get assessments_path
      assert_redirected_to new_user_session_path
    end

    should "issue a bounded number of cycle queries regardless of assignment count" do
      # Seed multiple direct reports assigned to the framework. Because an
      # open cycle already exists (from setup), the
      # AssessmentCycles::SyncHandlers::AutoEnrollNewAssignments handler
      # auto-enrolls each new assignment — no explicit cycle_handler.enroll
      # call is needed. The index should then render several assignment
      # cards, each with an open cycle. Without batch loading this would
      # trigger one cycle lookup per card (N+1).
      ActsAsTenant.with_tenant(@tenant) do
        manager = @person
        handler = PersonDevelopment::CommandHandler.new

        3.times do |i|
          report_user = create(:user, password: "password123")
          report = create(:person,
            tenant: @tenant, email: report_user.email, name: "Report #{i}", manager: manager)
          create(:tenant_user, tenant: @tenant, user: report_user, person: report)
          handler.assign_to_framework(
            report.id, @framework.framework_id, @role.role_id, @level.level_id
          )
        end
      end

      sign_in @user

      queries = []
      callback = ->(_n, _s, _f, _i, payload) do
        queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:sql] =~ /SAVEPOINT/
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        get assessments_path
      end
      assert_response :success

      # The old N+1 pattern issued one `SELECT ... FROM "assessment_cycles" ...`
      # per rendered assignment card (via PersonFrameworkAssignment#current_open_cycle).
      # The batch preload uses `FROM "assessment_cycle_enrollments" LEFT OUTER JOIN
      # "assessment_cycles"`, so queries with `FROM "assessment_cycles"` as the primary
      # table should be zero. Policy scalar queries join THROUGH assessment_cycles but
      # SELECT FROM person_framework_assignments, so they don't match either.
      primary_cycle_queries = queries.select { |q| q =~ /FROM "assessment_cycles"/ }
      assert_equal 0, primary_cycle_queries.size,
        "expected 0 per-assignment cycle queries, got #{primary_cycle_queries.size}: #{primary_cycle_queries.inspect}"
    end
  end

  context "GET /assessments/:id" do
    should "tell the assessee about feedback waiting to be placed, and say nothing when there is none" do
      sign_in @user
      get assessment_path(@assignment)
      assert_select "[data-testid='unplaced-feedback-notice']", count: 0

      ActsAsTenant.with_tenant(@tenant) do
        peer = create(:person, tenant: @tenant, name: "Peer")
        PersonDevelopment::CommandHandler.new.record_evidence(@person.id, @framework.framework_id, SecureRandom.uuid_v7,
          source: "peer", evidence_type: "peer_feedback", content: "Calm under pressure", author_id: peer.id)
      end
      get assessment_path(@assignment)
      assert_select "[data-testid='unplaced-feedback-notice']", text: /1 piece of feedback about you is waiting/ do
        assert_select "a[href='#{evidence_hub_path(anchor: "needs-you")}']", text: "Place it →"
      end
    end

    should "render assessment matrix for assigned framework" do
      sign_in @user
      get assessment_path(@assignment)

      assert_response :success
      assert_select "h1", text: "Mid"
      assert_select "span.font-mono", text: "E2"
      assert_includes response.body, "Critical Thinking"
      assert_includes response.body, "assessment-matrix"
      assert_includes response.body, "scoring-panel"
    end

    should "show frequency selectors" do
      sign_in @user
      get assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "Some"
      assert_includes response.body, "Most"
      assert_includes response.body, "Consistently"
    end

    should "render the activity pane open when the URL or the cookie chose it, and closed on a first visit" do
      sign_in @user
      get assessment_path(@assignment)
      assert_select "aside#assessment-activity-pane.hidden[data-pane-state='closed']"
      assert_select "button[aria-controls='assessment-activity-pane'][aria-expanded='false']"

      cookies[Views::Assessments::Activity::PaneToggle::COOKIE] = "open"
      get assessment_path(@assignment)
      assert_select "aside#assessment-activity-pane:not(.hidden)[data-pane-state='open']"
      assert_select "button[aria-controls='assessment-activity-pane'][aria-expanded='true']"

      get assessment_path(@assignment, activity: "closed")
      assert_select "aside#assessment-activity-pane.hidden[data-pane-state='closed']"
    end

    should "redirect if person not assigned to framework" do
      sign_in @user
      get assessment_path("nonexistent-id")

      assert_redirected_to assessments_path
    end

    should "redirect unauthenticated users to sign in" do
      get assessment_path(@assignment)
      assert_redirected_to new_user_session_path
    end
  end

  context "as manager" do
    setup do
      @manager_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Manager")
        create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
        @person.update!(manager: @manager)
      end
    end

    should "not show the notice to a tenant admin outside the chain, who cannot place" do
      admin_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        admin = create(:person, tenant: @tenant, email: admin_user.email, name: "Admin")
        create(:tenant_user, tenant: @tenant, user: admin_user, person: admin, role: :admin)
        PersonDevelopment::CommandHandler.new.record_evidence(@person.id, @framework.framework_id, SecureRandom.uuid_v7,
          source: "manager", evidence_type: "observation", content: "Calm under pressure", author_id: @manager.id)
      end
      sign_in admin_user
      get assessment_path(@assignment)
      assert_response :success
      assert_select "[data-testid='unplaced-feedback-notice']", count: 0
    end

    should "name the report in the unplaced-feedback notice" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.record_evidence(@person.id, @framework.framework_id, SecureRandom.uuid_v7,
          source: "manager", evidence_type: "observation", content: "Calm under pressure", author_id: @manager.id)
      end
      sign_in @manager_user
      get assessment_path(@assignment)
      assert_select "[data-testid='unplaced-feedback-notice']", text: /about Test User is waiting/
    end

    should "read each card's blades through the viewer's own ratings, as the hero does" do
      rate(@cap, "consistent")
      rate_as_manager(@person, @cap, "none")

      sign_in @manager_user
      get assessments_path
      assert_select "[data-capability-blades] svg[aria-label='0 of 1 capabilities met at E2']", count: 1

      delete destroy_user_session_path
      sign_in @user
      get assessments_path
      assert_select "[data-capability-blades] svg[aria-label='1 of 1 capabilities met at E2']", count: 1
    end

    should "show a skip-level card's blades through its manager's ratings" do
      rate(@cap, "consistent")
      rate_as_manager(@person, @cap, "none")
      skip_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        grand_manager = create(:person, tenant: @tenant, email: skip_user.email, name: "Grand Manager")
        create(:tenant_user, tenant: @tenant, user: skip_user, person: grand_manager)
        @manager.update!(manager: grand_manager)
      end

      sign_in skip_user
      get assessments_path

      assert_select "#skip-level-assessments [data-capability-blades] svg[aria-label='0 of 1 capabilities met at E2']",
                    count: 1
    end

    should "head Team Assessments with the team's blades once two reports have a score" do
      rate_as_manager(@person, @cap, "consistent")
      2.times { |i| rate_as_manager(add_report("Report #{i}"), @cap, "none") }
      sign_in @manager_user
      get assessments_path

      assert_select "#team-card", text: /3 direct reports · Software Engineer · manager ratings/
      assert_select "#team-card [data-team-blades][aria-label='0 of 1 capabilities met as a team']", count: 1
      assert_select "#team-card [data-team-gap]", text: "Critical Thinking · 2 of 3 short"
    end

    should "keep the page out of the browser's cache, since it shows the team's scores" do
      sign_in @manager_user
      get assessments_path

      assert_equal "no-store", response.headers["Cache-Control"]
    end

    should "offer a retry when the team map fails to load" do
      2.times { |i| rate_as_manager(add_report("Report #{i}"), @cap, "consistent") }
      sign_in @manager_user
      get assessments_path

      assert_select "#team-map-modal [data-controller~='frame-error']" do
        assert_select "turbo-frame#team-map[data-frame-error-target='frame']", count: 1
        assert_select "#team-map-error[hidden]", count: 1
      end
    end

    should "widen the team card to everyone below the manager" do
      rate_as_manager(@person, @cap, "consistent")
      ActsAsTenant.with_tenant(@tenant) { rate_as_manager(add_report("Report one").tap { |r| r.update!(manager: @person) }, @cap, "none") }
      sign_in @manager_user
      get assessments_path(team_people: "below")

      assert_select "#team-card", text: /2 people below you/
      assert_select "#team-card a[aria-current='page']", text: "Everyone below you"
    end

    should "show the team on the role picked from the role menu" do
      staff, staff_level = add_staff_role
      rate_as_manager(@person, @cap, "consistent")
      rate_as_manager(add_report("Staff one", role: staff, level: staff_level), @cap, "none")
      sign_in @manager_user
      get assessments_path(team_role: staff.role_id)

      assert_select "#team-card [data-team-roles] [aria-haspopup]", text: /Staff Engineer/
      assert_select "#team-card", text: /1 of 1 has one so far/
    end

    should "show a blank slate on the team card until two reports have a score" do
      rate_as_manager(@person, @cap, "consistent")
      add_report("Report one")
      sign_in @manager_user
      get assessments_path

      assert_select "#team-card [data-team-blank]", count: 1
      assert_select "#team-card", text: /1 of 2 has one so far/
      assert_select "#team-card [data-team-blades]", count: 0
    end

    should "leave out the team card for a rating delegate with no direct reports" do
      delegate_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        delegate = create(:person, tenant: @tenant, email: delegate_user.email, name: "Delegate")
        create(:tenant_user, tenant: @tenant, user: delegate_user, person: delegate)
        create(:manager_assessment_delegation, tenant: @tenant, person_id: @person.id,
                                               framework_id: @assignment.framework_id, delegate_person_id: delegate.id,
                                               granted_by_id: @manager.id)
      end

      sign_in delegate_user
      get assessments_path

      assert_includes response.body, "Team Assessments"
      assert_select "#team-card", count: 0
    end

    should "draw every card's blades in the same number of queries, however many cards" do
      rate_as_manager(@person, @cap, "consistent")
      sign_in @manager_user
      one_card = count_queries { get assessments_path }

      2.times { |i| rate_as_manager(add_report("Report #{i}"), @cap, "consistent") }
      three_cards = count_queries { get assessments_path }

      assert_select "[data-capability-blades]", count: 3
      assert_equal one_card, three_cards
    end

    should "draw every card's blades in the same number of queries, however many roles the cards span" do
      rate_as_manager(@person, @cap, "consistent")
      sign_in @manager_user
      one_card = count_queries { get assessments_path }

      staff, staff_level = add_staff_role
      2.times { |i| rate_as_manager(add_report("Staff #{i}", role: staff, level: staff_level), @cap, "consistent") }
      three_cards = count_queries { get assessments_path }

      assert_select "[data-capability-blades]", count: 3
      assert_equal one_card, three_cards
    end

    should "draw every card's blades in the same number of queries, however many alignments other roles hold" do
      staff, = add_staff_role
      rate_as_manager(@person, @cap, "consistent")
      start_lens_alignment(@person, staff)
      sign_in @manager_user
      one_card = count_queries { get assessments_path }

      2.times do |i|
        report = add_report("Report #{i}")
        rate_as_manager(report, @cap, "consistent")
        start_lens_alignment(report, staff)
      end
      three_cards = count_queries { get assessments_path }

      assert_select "[data-capability-blades]", count: 3
      assert_equal one_card, three_cards
    end

    should "render the capability map for the report, read through the manager's ratings" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.rate_as_manager(
          @person.id, @framework.framework_id, @cap.stable_id,
          level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id, rated_by_id: @manager.id
        )
      end
      sign_in @manager_user
      get capability_map_assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "Test User at E2"
      lane = Nokogiri::HTML5.fragment(response.body).at_css("[data-capability-lane='1']")
      assert_includes lane.text, "E2 met"
    end

    should "render the score explainer for the report, in the third person" do
      sign_in @manager_user
      get score_explainer_assessment_path(@assignment)

      assert_response :success
      assert_includes Nokogiri::HTML5.fragment(response.body).text, "Test User's score today"
    end

    should "render manager assessment view for direct report" do
      sign_in @manager_user
      get assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, @person.name
      assert_includes response.body, "assessment-matrix"
    end

    should "show team assessments section on index" do
      sign_in @manager_user
      get assessments_path

      assert_response :success
      assert_includes response.body, "Team Assessments"
      assert_includes response.body, @person.name
    end

    should "not show skip-level section to a manager with no skip-level reports" do
      sign_in @manager_user
      get assessments_path

      assert_response :success
      assert_not_includes response.body, "Skip-Level Assessments"
    end

    should "show skip-level assessments section to the manager's manager" do
      skip_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        grand_manager = create(:person, tenant: @tenant, email: skip_user.email, name: "Grand Manager")
        create(:tenant_user, tenant: @tenant, user: skip_user, person: grand_manager)
        @manager.update!(manager: grand_manager)
      end

      sign_in skip_user
      get assessments_path

      assert_response :success
      assert_includes response.body, "Skip-Level Assessments"
      assert_includes response.body, @person.name
      # The manager in between has no assignment, so only the team card can reach everyone below.
      assert_select "#team-card", text: /None of your reports is in an open assessment cycle yet/
      assert_select "#team-card a", text: "Everyone below you"
    end

    should "paginate the skip-level section beyond #{AssessmentsController::SKIP_LEVEL_PAGE_SIZE} assignments" do
      skip_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        grand_manager = create(:person, tenant: @tenant, email: skip_user.email, name: "Grand Manager")
        create(:tenant_user, tenant: @tenant, user: skip_user, person: grand_manager)
        @manager.update!(manager: grand_manager)

        handler = PersonDevelopment::CommandHandler.new
        AssessmentsController::SKIP_LEVEL_PAGE_SIZE.times do |i|
          extra = create(:person, tenant: @tenant, name: "Extra Skip #{i}", manager: @manager)
          handler.assign_to_framework(extra.id, @framework.framework_id, @role.role_id, @level.level_id)
        end
      end

      sign_in skip_user
      get assessments_path

      assert_response :success
      assert_includes response.body, "Page 1 of 2"
      # The pager's dead end is an inactive control, not plain text — that is
      # what exempts its muted colour from 1.4.3 (#323).
      assert_select "#skip-level-assessments a[role='link'][aria-disabled='true']:not([href])", text: /Prev/
      # 13 skip-level assignments, ordered by id (creation order): the last
      # one created falls on page 2.
      assert_not_includes response.body, "Extra Skip #{AssessmentsController::SKIP_LEVEL_PAGE_SIZE - 1}"

      get assessments_path(skip_page: 2)

      assert_response :success
      assert_includes response.body, "Page 2 of 2"
      assert_includes response.body, "Extra Skip #{AssessmentsController::SKIP_LEVEL_PAGE_SIZE - 1}"
      assert_not_includes response.body, "Extra Skip 0"
    end

    should "render read-only manager view for a skip-level manager" do
      skip_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        grand_manager = create(:person, tenant: @tenant, email: skip_user.email, name: "Grand Manager")
        create(:tenant_user, tenant: @tenant, user: skip_user, person: grand_manager)
        @manager.update!(manager: grand_manager)
      end

      sign_in skip_user
      get assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, @person.name
      # View-only: no interactive manager-rating form may render for a
      # chain ancestor who is not the recorded reporting manager.
      assert_not_includes response.body, assessment_manager_ratings_path(@assignment)
      # The priming hero renders passive copy — no "Rate …" imperative or
      # rate-next CTA for a viewer without rating authority.
      assert_includes response.body, "No score for #{@person.name.split.first} yet"
      assert_not_includes response.body, "Rate next capability"
    end

    context "with feedback waiting to be placed" do
      setup do
        @skip_user = create(:user, password: "password123")
        ActsAsTenant.with_tenant(@tenant) do
          grand_manager = create(:person, tenant: @tenant, email: @skip_user.email, name: "Grand Manager")
          create(:tenant_user, tenant: @tenant, user: @skip_user, person: grand_manager)
          @manager.update!(manager: grand_manager)
          peer = create(:person, tenant: @tenant, name: "Peer")
          PersonDevelopment::CommandHandler.new.record_evidence(@person.id, @framework.framework_id, SecureRandom.uuid_v7,
            source: "peer", evidence_type: "peer_feedback", content: "Calm under pressure", author_id: peer.id)
        end
      end

      should "point the direct manager's notice at the hub's default team view" do
        sign_in @manager_user
        get assessment_path(@assignment)
        assert_select "[data-testid='unplaced-feedback-notice'] a[href='#{evidence_hub_path(anchor: "needs-you")}']"
      end

      should "point a skip-level manager's notice at the hub's whole-org view, where the item is listed" do
        sign_in @skip_user
        get assessment_path(@assignment)
        assert_select "[data-testid='unplaced-feedback-notice'] " \
                      "a[href='#{evidence_hub_path(place: "org", anchor: "needs-you")}']", text: "Place it →"
      end
    end

    should "keep the imperative priming hero for the direct manager" do
      sign_in @manager_user
      get assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "Rate #{@person.name.split.first} to see their score"
      assert_includes response.body, "Rate next capability"
    end

    should "keep the manager-rating form interactive for the direct manager" do
      sign_in @manager_user
      get assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, assessment_manager_ratings_path(@assignment)
    end

    should "render the read-only manager view for a tenant admin outside the chain" do
      admin_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        admin = create(:person, tenant: @tenant, email: admin_user.email, name: "HR Admin")
        create(:tenant_user, tenant: @tenant, user: admin_user, person: admin, role: :admin)
      end

      sign_in admin_user
      get assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, @person.name
      # No manager-rating endpoint rendered — the admin views, never rates.
      assert_not_includes response.body, assessment_manager_ratings_path(@assignment)
    end

    should "redirect if not manager and not assignee" do
      other_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        other = create(:person, tenant: @tenant, email: other_user.email, name: "Other")
        create(:tenant_user, tenant: @tenant, user: other_user, person: other)
      end

      sign_in other_user
      get assessment_path(@assignment)

      assert_response :redirect
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  context "GET /assessments/:id/matrix" do
    should "render Turbo Frame without layout" do
      sign_in @user
      get matrix_assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "assessment-matrix"
      assert_not_includes response.body, "<html"
    end

    should "render all category sections in the matrix" do
      sign_in @user
      get matrix_assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "Thinking"
    end

    should "default to first category when no category param" do
      sign_in @user
      get matrix_assessment_path(@assignment)

      assert_response :success
      # Should show the capabilities from Thinking category
      assert_includes response.body, "Critical Thinking"
    end

    should "fall back to first category for invalid category param" do
      sign_in @user
      get matrix_assessment_path(@assignment, category: "nonexistent")

      assert_response :success
      assert_includes response.body, "Critical Thinking"
    end
  end

  def get_card(**params)
    get capability_card_assessment_path(@assignment, **params), headers: { "Accept" => "text/vnd.turbo-stream.html" }
  end

  context "GET /assessments/:id/capability_card" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @other_cap = create(:framework_capability, category_id: @cap.category_id, name: "Execution")
        create(:framework_capability_role_binding, capability_id: @other_cap.capability_id, role_id: @role.role_id)
        create(:framework_behavioural_expectation,
          capability_id: @other_cap.capability_id, level_ordinal: 2, description: "Ships reliably")
      end
    end

    should "replace just that card, at the level asked for" do
      sign_in @user
      get_card(capability: @cap.stable_id, level_ordinal: 1)

      assert_response :success
      assert_equal "text/vnd.turbo-stream.html", response.media_type
      assert_includes response.body, %(action="replace" target="capability-card-#{@cap.stable_id}")
      assert_includes response.body, "Asks good questions"
      assert_not_includes response.body, "Synthesises information"
      assert_not_includes response.body, "Execution", "no other card"
      assert_not_includes response.body, %(data-controller="matrix"), "no matrix wrapper"
      assert_not_includes response.body, "<section", "no category section around the card"
      assert_match(/<template>\s*<div[^>]*id="capability-card-#{@cap.stable_id}"/, response.body,
        "the stream's payload is the card itself, so each swap replaces a card with a card")
      assert_includes response.body, %(data-focused="false"), "the client places the focus ring"
    end

    should "default to the person's level" do
      sign_in @user
      get_card(capability: @cap.stable_id)

      assert_response :success
      assert_includes response.body, "Synthesises information"
    end

    should "404 for a capability the matrix doesn't show" do
      sign_in @user
      get_card(capability: SecureRandom.uuid_v7)

      assert_response :not_found
    end

    should "deny a viewer who may not see the assessment" do
      other_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        other = create(:person, tenant: @tenant, email: other_user.email, name: "Outsider")
        create(:tenant_user, tenant: @tenant, user: other_user, person: other)
      end
      sign_in other_user
      get_card(capability: @cap.stable_id)

      assert_response :redirect
      assert_not_includes response.body, "Asks good questions"
    end
  end

  # The capability map's comparison tab, at the level asked for.
  def compare(**params)
    get capability_map_assessment_path(@assignment, tab: "compare", **params)
    assert_response :success
    Nokogiri::HTML5.fragment(response.body)
  end

  context "GET /assessments/:id/capability_map" do
    should "render just the map's contents, as the frame the page reloads, read through the viewer's ratings" do
      rate(@cap, "consistent")
      sign_in @user
      get capability_map_assessment_path(@assignment)

      assert_response :success
      frame = Nokogiri::HTML5.fragment(response.body).at_css("turbo-frame##{Views::Assessments::CapabilityMapModal::CONTENT_ID}")
      assert frame, "expected the map's content frame"
      assert_includes frame.text, "You at E2"
      assert_includes frame.at_css("[data-capability-lane='1']").text, "E2 met"
      assert_not_includes response.body, %(id="#{Views::Assessments::CapabilityMapModal::ID}"), "no overlay around it"
    end

    context "compared with the person's level" do
      setup do
        ActsAsTenant.with_tenant(@tenant) do
          @snapshot = LevelComparisonSnapshot.create!(tenant: @tenant, taken_on: Date.new(2026, 11, 1))
          [ [ 1, 6, 1.0 ], [ 2, 7, 0.5 ] ].each do |level, size, median|
            @snapshot.groups.create!(tenant: @tenant, framework_id: @assignment.framework_id, role_id: @role.role_id,
                                     level_ordinal: level, group_size: size,
                                     capability_medians: { @cap.stable_id => median },
                                     category_medians: { @cap.category_id => median })
          end
        end
        rate(@cap, "consistent")
        sign_in @user
      end

      should "offer two tabs, opening on the capabilities, with the comparison one click away" do
        get capability_map_assessment_path(@assignment)
        tabs = Nokogiri::HTML5.fragment(response.body).css("[role='tab']")

        assert_equal [ [ "Capabilities", "true" ], [ "Compared with your level", "false" ] ],
                     tabs.map { |t| [ t.text.strip, t["aria-selected"] ] }
      end

      should "tie each tab to the panel it shows, with only the selected tab in the Tab order" do
        map = compare
        tabs = map.css("[role='tab']")
        panel = map.at_css("[role='tabpanel']")

        assert_equal [ [ "-1", "false" ], [ "0", "true" ] ], tabs.map { |t| [ t["tabindex"], t["aria-selected"] ] }
        assert_equal [ panel["id"] ], tabs.map { |t| t["aria-controls"] }.uniq
        assert_equal tabs.last["id"], panel["aria-labelledby"]
        assert_equal "0", panel["tabindex"], "expected the panel to take focus, as it opens on text"
        assert panel.at_css("[data-comparison-lane]"), "expected the comparison inside its panel"
      end

      should "show the person's blades beside the group's median at their level, and when it was taken" do
        map = compare

        assert_equal "Compared with your level", map.at_css("[role='tab'][aria-selected='true']").text.strip
        assert_includes map.text, "as of 1 Nov 2026"
        assert_includes map.text, "the median agreed score of the"
        assert_includes map.text, "E2s (median)"
        assert_equal "You 100% · E2s 50%", map.at_css("[data-comparison-lane='1'] [data-comparison-scores]").text.squish
        assert map.at_css("svg [data-blade-median='1']"), "expected the group's line across the blade"
      end

      should "keep the person's score, with no group line, on a capability the snapshot predates" do
        @snapshot.groups.find_by!(level_ordinal: 2).update!(capability_medians: {}, category_medians: {})
        map = compare

        assert_equal "You 100% · E2s no score", map.at_css("[data-comparison-lane='1'] [data-comparison-scores]").text.squish
        assert_empty map.css("[data-blade-median]")
      end

      should "switch to a level either side, read on that level's scale" do
        map = compare(compare_level: 1)

        assert_equal "You not rated · E1s 100%", map.at_css("[data-comparison-lane='1'] [data-comparison-scores]").text.squish,
                     "expected the person's score read at E1, where they haven't rated"
        assert_equal [ [ "E1", "true" ], [ "E2", "false" ] ],
                     map.css("[data-comparison-level]").map { |c| [ c["data-comparison-level"], c["aria-pressed"] ] }.first(2)
      end

      should "send no group scores for a level under the minimum, and say how many it needs" do
        @snapshot.groups.find_by!(level_ordinal: 2).update!(group_size: 3)
        map = compare

        assert_includes map.text, "Not enough E2s to compare with"
        assert_includes map.text, "Try E1."
        assert_empty map.css("[data-blade-median]")
        assert_empty map.css("[data-comparison-scores]")
        assert_includes map.css("[data-comparison-level]").map(&:text).join(" "), "fewer than 5"
      end

      should "fall back to the capabilities when the comparison can't be read" do
        Operations::Assessments::LevelComparison.stub(:call, ->(**) { raise Operations::Base::ParameterError, "gone" }) do
          get capability_map_assessment_path(@assignment, tab: "compare")
        end

        assert_response :success
        assert_includes response.body, "data-capability-lane"
      end

      should "name the person, not the viewer, on every lane their manager reads" do
        manager_user = create(:user, password: "password123")
        ActsAsTenant.with_tenant(@tenant) do
          manager = create(:person, tenant: @tenant, email: manager_user.email, name: "Manager")
          create(:tenant_user, tenant: @tenant, user: manager_user, person: manager)
          @person.update!(manager:)
        end
        delete destroy_user_session_path
        sign_in manager_user

        lanes = compare.css("[data-comparison-scores]").map { |lane| lane.text.squish }

        assert lanes.any?
        assert lanes.all? { |text| text.start_with?("Test User ") }, "expected every lane to name the person: #{lanes}"
      end

      should "offer no comparison on a page read at another level, which the comparison would not match" do
        get assessment_path(@assignment, as_level: 1)
        assert_response :success
        assert_empty Nokogiri::HTML5.fragment(response.body).css("##{Views::Assessments::CapabilityMapModal::ID} [role='tab']")

        get capability_map_assessment_path(@assignment, as_level: 1, tab: "compare")
        assert_empty Nokogiri::HTML5.fragment(response.body).css("[role='tab']")
        assert_includes response.body, "data-capability-lane"
      end

      should "show no tabs when the tenant has comparisons off" do
        @tenant.update!(comparison_config: ComparisonConfig.new(enabled: false))
        get capability_map_assessment_path(@assignment, tab: "compare")

        assert_empty Nokogiri::HTML5.fragment(response.body).css("[role='tab']")
        assert_includes response.body, "data-capability-lane"
      end
    end

    should "zoom to the level asked for, or out to the whole ladder, and to the assessed level otherwise" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:framework_level, role_id: @role.role_id, ordinal: 3, title: "Senior", code: "E3")
        create(:framework_level, role_id: @role.role_id, ordinal: 4, title: "Staff", code: "E4")
      end
      rate(@cap, "consistent")
      sign_in @user
      pressed = ->(zoom) {
        get capability_map_assessment_path(@assignment, zoom: zoom)
        assert_response :success
        Nokogiri::HTML5.fragment(response.body).css("[aria-pressed='true']").map { |t| t.text.strip }
      }

      assert_equal %w[E2], pressed.call(nil)
      assert_equal %w[E4], pressed.call("E4")
      assert_equal [ "All levels" ], pressed.call("all")
    end

    should "deny a viewer who may not see the assessment" do
      other_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        other = create(:person, tenant: @tenant, email: other_user.email, name: "Outsider")
        create(:tenant_user, tenant: @tenant, user: other_user, person: other)
      end
      rate(@cap, "consistent")
      sign_in other_user
      get capability_map_assessment_path(@assignment)

      assert_response :redirect
      assert_not_includes response.body, "data-capability-lane"
    end
  end

  context "GET /assessments/:id/score_explainer" do
    should "render just the drawer's contents, as the frame the page reloads, on the viewer's own numbers" do
      rate(@cap, "consistent")
      sign_in @user
      get score_explainer_assessment_path(@assignment)

      assert_response :success
      frame = Nokogiri::HTML5.fragment(response.body).at_css("turbo-frame##{Views::Assessments::ScoreExplainerModal::CONTENT_ID}")
      assert frame, "expected the drawer's content frame"
      assert_includes frame.text, "Your score today"
      assert_includes frame.text, "How it adds up"
      assert_not_includes response.body, %(id="#{Views::Assessments::ScoreExplainerModal::ID}"), "no overlay around it"
    end

    should "deny a viewer who may not see the assessment" do
      other_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        other = create(:person, tenant: @tenant, email: other_user.email, name: "Outsider")
        create(:tenant_user, tenant: @tenant, user: other_user, person: other)
      end
      rate(@cap, "consistent")
      sign_in other_user
      get score_explainer_assessment_path(@assignment)

      assert_response :redirect
      assert_not_includes response.body, "How it adds up"
    end
  end

  context "GET /assessments/:id/matrix — unauthorized" do
    setup do
      @other_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        other = create(:person, tenant: @tenant, email: @other_user.email, name: "Outsider")
        create(:tenant_user, tenant: @tenant, user: @other_user, person: other)
      end
    end

    # A Turbo Frame fetch can't follow a redirect — it must get the requested
    # frame back, or Turbo logs "did not contain the expected <turbo-frame>"
    # and the section breaks. Denied frame requests render a recovery frame.
    should "render the recovery frame (not redirect) for a Turbo Frame request" do
      sign_in @other_user
      get matrix_assessment_path(@assignment), headers: { "Turbo-Frame" => "assessment-matrix" }

      assert_response :success
      assert_includes response.body, "assessment-matrix"
      assert_includes response.body, "Reload"
      assert_not_includes response.body, "<html"
    end

    should "still redirect for a normal (non-frame) request" do
      sign_in @other_user
      get matrix_assessment_path(@assignment)

      assert_response :redirect
    end

    should "never link the recovery Reload to an off-site Referer" do
      sign_in @other_user
      get matrix_assessment_path(@assignment), headers: {
        "Turbo-Frame" => "assessment-matrix",
        "Referer" => "https://evil.example.com/phish"
      }

      assert_response :success
      assert_not_includes response.body, "evil.example.com"
      assert_includes response.body, %(href="#{root_path}")
    end
  end

  context "GET /assessments/:id/matrix with multiple categories" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        # Add a second category
        cat2 = create(:framework_capability_category,
          framework_id: @framework.framework_id, name: "Delivering", ordinal: 2)
        @cap2 = create(:framework_capability, category_id: cat2.category_id, name: "Execution")
        create(:framework_capability_role_binding,
          capability_id: @cap2.capability_id, role_id: @role.role_id, weight: 1.0)
        create(:framework_behavioural_expectation,
          capability_id: @cap2.capability_id, level_ordinal: 1, description: "Ships features reliably")
        @cat2_id = cat2.category_id
      end
    end

    should "render only the selected category" do
      sign_in @user
      get matrix_assessment_path(@assignment, category: @cat2_id)

      assert_response :success
      # Should show Execution from Delivering category
      assert_includes response.body, "Execution"
      # Should NOT show capabilities from the other category in the table body
      # (tabs will still mention both categories)
    end

    should "render category chips with aria-current on the show page" do
      sign_in @user
      get assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "category-tabs"
      assert_includes response.body, "Thinking"
    end

    should "omit archived categories from the rendered matrix" do
      ActsAsTenant.with_tenant(@tenant) do
        FrameworkState::CapabilityCategory.find_by!(category_id: @cat2_id).update!(status: "archived")
      end

      sign_in @user
      get matrix_assessment_path(@assignment)

      assert_response :success
      assert_not_includes response.body, "Delivering",
        "archived category name should not appear in the matrix"
    end
  end

  context "GET /assessments/:id/scoring — coverage gating" do
    setup do
      # Base setup has one current-level (E2) capability. Add two more so the
      # current-level denominator is 3 and the 50% unlock threshold lands at 2
      # rated — making the boundary non-degenerate.
      ActsAsTenant.with_tenant(@tenant) do
        cat = FrameworkState::CapabilityCategory.find_by!(framework_id: @framework.framework_id, name: "Thinking")
        @extra_caps = [ "Communication", "Ownership" ].map do |name|
          cap = create(:framework_capability, category_id: cat.category_id, name: name)
          create(:framework_capability_role_binding,
            capability_id: cap.capability_id, role_id: @role.role_id, weight: 1.0)
          create(:framework_behavioural_expectation,
            capability_id: cap.capability_id, level_ordinal: 1, description: "L1 #{name}")
          create(:framework_behavioural_expectation,
            capability_id: cap.capability_id, level_ordinal: 2, description: "L2 #{name}")
          cap
        end
      end
    end

    should "show the priming hero with no ratings" do
      sign_in @user
      get scoring_assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "Rate yourself to see your score"
      assert_includes response.body, "Score unlocks at 2"
      assert_not_includes response.body, "demonstrated"
    end

    should "stay primed below the 50% threshold (1 of 3 rated)" do
      rate(@cap, "consistent")

      sign_in @user
      get scoring_assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "Score unlocks at 2"
      assert_includes response.body, "1/3"
      assert_not_includes response.body, "demonstrated"
    end

    should "unlock scoring at the 50% threshold with a coverage chip (2 of 3 rated)" do
      rate(@cap, "consistent")
      rate(@extra_caps.first, "consistent")

      sign_in @user
      get scoring_assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "demonstrated"
      assert_includes response.body, "2 of 3 rated"
      assert_not_includes response.body, "Rate yourself to see your score"
    end

    should "drop the coverage chip once fully rated" do
      @extra_caps.each { |c| rate(c, "consistent") }
      rate(@cap, "consistent")

      sign_in @user
      get scoring_assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "demonstrated"
      assert_not_includes response.body, "of 3 rated"
    end
  end

  private

  def rate(capability, frequency)
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.rate_self(
        @person.id, @framework.framework_id, capability.stable_id,
        level_ordinal: 2, frequency: frequency, cycle_id: @cycle_id
      )
    end
  end

  def rate_as_manager(person, capability, frequency)
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.rate_as_manager(
        person.id, @framework.framework_id, capability.stable_id,
        level_ordinal: 2, frequency: frequency, cycle_id: @cycle_id, rated_by_id: @manager.id
      )
    end
  end

  # A direct report of the manager, assigned (at E2 by default) and enrolled in the open cycle.
  def add_report(name, role: @role, level: @level)
    ActsAsTenant.with_tenant(@tenant) do
      report = create(:person, tenant: @tenant, name: name, manager: @manager)
      PersonDevelopment::CommandHandler.new.assign_to_framework(
        report.id, @framework.framework_id, role.role_id, level.level_id
      )
      report
    end
  end

  # A second role on the ladder, binding the same capability.
  def add_staff_role
    ActsAsTenant.with_tenant(@tenant) do
      role = create(:framework_role, role_family_id: @role.role_family_id, name: "Staff Engineer", code: "S",
                                     track: "ic")
      create(:framework_capability_role_binding, capability_id: @cap.capability_id, role_id: role.role_id)
      [ role, create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Staff", code: "S2") ]
    end
  end

  # Alignment started against another role, as the per-role alignment records it.
  def start_lens_alignment(person, role)
    ActsAsTenant.with_tenant(@tenant) do
      AssessmentCycleRoleAlignment.create!(tenant: @tenant, cycle_id: @cycle_id, person_id: person.id,
                                           framework_id: @framework.framework_id, role_id: role.role_id,
                                           level_ordinal: 2, alignment_started_at: Time.current)
    end
  end

  def count_queries(&block)
    count = 0
    counter = ->(_n, _s, _f, _i, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:sql] =~ /SAVEPOINT/ }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    assert_response :success
    count
  end

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
