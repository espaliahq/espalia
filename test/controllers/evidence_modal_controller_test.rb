# frozen_string_literal: true

require "test_helper"

class EvidenceModalControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @author_user = create(:user, password: "password123")
    @manager_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Mgr")
      @author = create(:person, tenant: @tenant, email: @author_user.email, name: "Author", manager: @manager)
      create(:tenant_user, tenant: @tenant, user: @author_user, person: @author, role: :member)
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding, capability_id: @cap.capability_id, role_id: role.role_id, weight: 1.0)
      exp = create(:framework_behavioural_expectation, capability_id: @cap.capability_id, level_ordinal: 2,
                   description: "Weighs options and explains reasoning")
      create(:framework_role_illustration, expectation_id: exp.expectation_id, role_id: role.role_id, ordinal: 1,
             description: "Wrote the migration RFC")

      handler = PersonDevelopment::CommandHandler.new
      handler.assign_to_framework(@author.id, @framework_id, role.role_id, level.level_id)
      @assignment = PersonFrameworkAssignment.find_by(person_id: @author.id, framework_id: @framework_id)
      @evidence_id = SecureRandom.uuid_v7
      handler.record_evidence(@author.id, @framework_id, @evidence_id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2, source: "self",
        evidence_type: "project_outcome", title: "RFC", content: "Original", author_id: @author.id, valence: "demonstrated")
    end
  end

  # An evidence request on @author's assessment.
  def make_request!(requested_by:, requestee:)
    id = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.request_evidence(@author.id, @framework_id, id,
        requested_by_id: requested_by.id, requestee_person_id: requestee.id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2)
    end
    id
  end

  context "GET /evidence_modal mode=give" do
    should "render the who-is-it-for step with the giver's org neighbours as suggestions" do
      sign_in @author_user
      get evidence_modal_path(mode: "give", return_to: "hub")
      assert_response :success
      assert_select "h2", text: "Give feedback"
      assert_select "input#give-feedback-search"
      # The author's manager holds no assignment, so nobody is suggested yet.
      assert_select "a[data-recipient-row]", count: 0

      ActsAsTenant.with_tenant(@tenant) do
        role = FrameworkState::Role.find_by(code: "E")
        PersonDevelopment::CommandHandler.new.assign_to_framework(@manager.id, @framework_id, role.role_id,
          FrameworkState::Level.find_by(role_id: role.role_id, ordinal: 2).level_id)
      end
      get evidence_modal_path(mode: "give", return_to: "hub")
      assert_select "a[data-recipient-row][data-person-id='#{@manager.id}']", text: /Mgr.*your manager/m
    end

    should "search the recipient directory for the typeahead frame" do
      sign_in @manager_user
      get recipients_evidence_modal_path(q: "Auth", return_to: "hub")
      assert_response :success
      assert_select "turbo-frame#evidence-recipients a[data-recipient-row][data-person-id='#{@author.id}']" do
        assert_select "a[href*='mode=new'][href*='assignment_id=#{@assignment.id}'][data-turbo-frame='evidence-modal']"
      end

      get recipients_evidence_modal_path(q: "zzz", return_to: "hub")
      assert_select "turbo-frame#evidence-recipients", text: /No one matching/
    end
  end

  context "GET /evidence_modal mode=new without a cell (volunteered)" do
    should "render no seed row, say who it is for and who will see it, and allow saving unplaced" do
      sign_in @manager_user
      get evidence_modal_path(mode: "new", assignment_id: @assignment.id, return_to: "hub")
      assert_response :success
      assert_select "h2", text: "Give feedback"
      assert_select "[data-link-row]", count: 0
      assert_select "input[name='evidence[primary_cell]']", count: 0
      assert_select "p", text: /For Author/
      assert_select "[data-testid='visibility-note']", text: /visible to Author, their managers/
      assert_select "[data-testid='unplaced-hint']", text: /Author or their manager can place it/
      assert_select "[data-controller='evidence-modal'][data-evidence-modal-allow-unplaced-value='true']"
      assert_select "form[action='/evidence_items']"
    end

    should "say nothing about visibility when the giver is the assessee" do
      sign_in @author_user
      get evidence_modal_path(mode: "new", assignment_id: @assignment.id, return_to: "hub")
      assert_select "[data-testid='visibility-note']", count: 0
      assert_select "p", text: /For Author/, count: 0
    end
  end

  context "GET /evidence_modal mode=new" do
    should "render the form with the primary-cell expectation + examples" do
      sign_in @author_user
      get evidence_modal_path(mode: "new", assignment_id: @assignment.id,
                              capability_stable_id: @cap.stable_id, level_ordinal: 2, return_to: "assessment:#{@assignment.id}")
      assert_response :success
      assert_match "Critical Thinking · Level 2", response.body
      assert_match "Weighs options and explains reasoning", response.body
      assert_match "Wrote the migration RFC", response.body
      assert_select "turbo-frame#evidence-modal"
      assert_select "select[name='evidence[evidence_type]']:not([disabled])"
      # No role/level chrome line when opened within an assessment.
      assert_no_match(/on Author/, response.body)
    end

    should "seed the Applies-to block with a fixed row carrying the required valence" do
      sign_in @author_user
      get evidence_modal_path(mode: "new", assignment_id: @assignment.id,
                              capability_stable_id: @cap.stable_id, level_ordinal: 2, return_to: "assessment:#{@assignment.id}")
      assert_response :success
      assert_select "input[name='evidence[primary_cell]'][value=?]", "#{@cap.stable_id}|2"
      assert_select "[data-link-row] input[name='evidence[desired_links][]'][value=?]", "#{@cap.stable_id}|2"
      assert_select "select#evm-valence[required]"
      # The seed row is the record's anchor — not removable.
      assert_select "button[aria-label='Remove link']", count: 0
    end
  end

  context "GET /evidence_modal mode=edit" do
    should "prefill content for the author (editable)" do
      sign_in @author_user
      get evidence_modal_path(mode: "edit", evidence_id: @evidence_id, return_to: "assessment:#{@assignment.id}")
      assert_response :success
      assert_match "Original", response.body
      assert_select "textarea[name='evidence[content]']:not([disabled])"
    end

    should "say where an imported item was given, with no reference fields to change it" do
      ActsAsTenant.with_tenant(@tenant) do
        EvidenceItem.find(@evidence_id).update_columns(external_reference: {
          system: "chip", url: "https://chip.example.com/f/1", metadata: { given_at: "2026-10-18T03:12:44Z" }
        })
      end
      sign_in @author_user
      get evidence_modal_path(mode: "edit", evidence_id: @evidence_id, return_to: "assessment:#{@assignment.id}")
      assert_select "#evm-origin a[data-origin='chip'][href='https://chip.example.com/f/1']", text: /via Chip/
      assert_select "#evm-sys", count: 0
      assert_select "#evm-url", count: 0
    end

    # Edit mode has no top context card — every active link (the origin
    # included) is a uniform "Applies to" row carrying its valence, and the
    # form submits no primary_cell (the server diffs desired vs current).
    should "render the origin as a uniform Applies-to row, no context card, no primary_cell" do
      sign_in @author_user
      get evidence_modal_path(mode: "edit", evidence_id: @evidence_id, return_to: "assessment:#{@assignment.id}")
      assert_response :success
      assert_no_match(/What good looks like/, response.body)
      assert_select "input[name='evidence[primary_cell]']", count: 0
      assert_select "input[name='evidence[desired_links][]'][value=?]", "#{@cap.stable_id}|2"
      assert_select "select[name=?] option[selected][value='demonstrated']",
                    "evidence[link_valences][#{@cap.stable_id}|2]"
      # The examples disclosure lives on the row now.
      assert_match "Wrote the migration RFC", response.body
      # The item's only link can't be removed — withdraw instead.
      assert_select "button[aria-label='Remove link'][disabled]"
    end

    should "sort and highlight the entry-point cell first" do
      other = ActsAsTenant.with_tenant(@tenant) do
        cap2 = create(:framework_capability, category_id: @cap.category_id, name: "Collaboration")
        role_id = FrameworkState::CapabilityRoleBinding.find_by(capability_id: @cap.capability_id).role_id
        create(:framework_capability_role_binding, capability_id: cap2.capability_id, role_id: role_id, weight: 1.0)
        create(:framework_behavioural_expectation, capability_id: cap2.capability_id, level_ordinal: 2, description: "Pairs well")
        PersonDevelopment::CommandHandler.new.add_evidence_link(@author.id, @framework_id, @evidence_id,
          capability_stable_id: cap2.stable_id, level_ordinal: 2, linked_by_id: @author.id, valence: "growth_area")
        cap2
      end

      sign_in @author_user
      get evidence_modal_path(mode: "edit", evidence_id: @evidence_id,
                              capability_stable_id: other.stable_id, level_ordinal: 2,
                              return_to: "assessment:#{@assignment.id}")
      assert_response :success
      rows = css_select("[data-link-row]")
      assert_equal 2, rows.size
      assert_match "Collaboration", rows.first.text
      assert_includes rows.first["class"], "ring-1"
      assert_equal "You opened this feedback from here", rows.first["title"]
      # With two rows, both are removable.
      assert_select "button[aria-label='Remove link'][disabled]", count: 0
    end

    should "disable content for a non-author who may only link (manager)" do
      sign_in @manager_user
      get evidence_modal_path(mode: "edit", evidence_id: @evidence_id, return_to: "assessment:#{@assignment.id}")
      assert_response :success
      assert_select "textarea[name='evidence[content]'][disabled]"
      assert_match(/only where it applies/i, response.body)
    end

    should "show the role/level line when opened from the hub" do
      sign_in @author_user
      get evidence_modal_path(mode: "edit", evidence_id: @evidence_id, return_to: "hub")
      assert_response :success
      assert_match(/on Author/, response.body)
    end
  end

  context "GET /evidence_modal mode=respond" do
    should "disclose who will see the response when responding about someone else" do
      request_id = make_request!(requested_by: @author, requestee: @manager)
      sign_in @manager_user
      get evidence_modal_path(mode: "respond", request_id: request_id, return_to: "hub")
      assert_response :success
      assert_match "visible to Author, their managers, and workspace admins", response.body
    end

    should "not disclose visibility when the requestee is the assessee" do
      request_id = make_request!(requested_by: @manager, requestee: @author)
      sign_in @author_user
      get evidence_modal_path(mode: "respond", request_id: request_id, return_to: "hub")
      assert_response :success
      assert_no_match(/workspace admins/, response.body)
    end
  end

  context "editing an unplaced item" do
    should "render an empty Applies-to block the recipient may fill, with the item still removable-free" do
      unplaced = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.record_evidence(@author.id, @framework_id, unplaced,
          source: "manager", evidence_type: "observation", content: "Calm under pressure", author_id: @manager.id)
      end
      sign_in @author_user
      get evidence_modal_path(mode: "edit", evidence_id: unplaced, return_to: "hub")
      assert_response :success
      assert_select "[data-link-row]", count: 0
      assert_select "[data-controller='evidence-modal'][data-evidence-modal-allow-unplaced-value='true']"
      assert_select "textarea#evm-content[disabled]"
    end
  end

  context "permissions" do
    should "forbid an unrelated user from editing" do
      other = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: other, person: create(:person, tenant: @tenant), role: :member) }
      sign_in other
      get evidence_modal_path(mode: "edit", evidence_id: @evidence_id, return_to: "hub")
      assert_response :forbidden
    end
  end
end
