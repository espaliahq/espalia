# frozen_string_literal: true

require "test_helper"

# Exercises the diff-based unified-modal submit (EvidenceDiffSubmit) through the
# assessment #save endpoint: the minimal-command behaviour for new / edit /
# links-only / add+remove / respond / non-author-link.
class Assessments::EvidenceSaveTest < ActionDispatch::IntegrationTest
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

      framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: framework_id, name: "Eng")
      role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      @cap1 = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      @cap2 = create(:framework_capability, category_id: cat.category_id, name: "Collaboration")
      [ @cap1, @cap2 ].each do |cap|
        create(:framework_capability_role_binding, capability_id: cap.capability_id, role_id: role.role_id, weight: 1.0)
        create(:framework_behavioural_expectation, capability_id: cap.capability_id, level_ordinal: 2, description: "exp")
      end

      handler = PersonDevelopment::CommandHandler.new
      handler.assign_to_framework(@author.id, framework_id, role.role_id, level.level_id)
      @assignment = PersonFrameworkAssignment.find_by(person_id: @author.id, framework_id: framework_id)
      @framework_id = framework_id
    end
  end

  def cell(cap, level = 2) = "#{cap.stable_id}|#{level}"
  def save_path = "/assessments/#{@assignment.id}/evidence/save"

  def record!(content: "Original")
    id = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.record_evidence(@author.id, @framework_id, id,
        capability_stable_id: @cap1.stable_id, level_ordinal: 2, source: "self",
        evidence_type: "project_outcome", content: content, author_id: @author.id, valence: "demonstrated")
    end
    id
  end

  def links_for(id)
    ActsAsTenant.with_tenant(@tenant) { EvidenceLink.active.where(evidence_id: id).pluck(:capability_stable_id, :level_ordinal).to_set }
  end

  def valences_for(id)
    ActsAsTenant.with_tenant(@tenant) do
      EvidenceLink.active.where(evidence_id: id)
        .pluck(:capability_stable_id, :level_ordinal, :valence)
        .to_h { |cap, level, valence| [ [ cap, level ], valence ] }
    end
  end

  context "new" do
    should "record evidence linked to the primary + extra cell, each with its own valence" do
      sign_in @author_user
      post save_path, params: { return_to: "assessment:#{@assignment.id}", evidence: {
        assignment_id: @assignment.id, primary_cell: cell(@cap1),
        evidence_type: "project_outcome", content: "Fresh", desired_links: [ cell(@cap1), cell(@cap2) ],
        link_valences: { cell(@cap1) => "demonstrated", cell(@cap2) => "growth_area" }
      } }
      assert_response :success
      item = ActsAsTenant.with_tenant(@tenant) { EvidenceItem.active.find_by(content: "Fresh") }
      assert_equal Set[[ @cap1.stable_id, 2 ], [ @cap2.stable_id, 2 ]], links_for(item.id)
      assert_equal({ [ @cap1.stable_id, 2 ] => "demonstrated", [ @cap2.stable_id, 2 ] => "growth_area" },
        valences_for(item.id))
    end

    should "reject a new link without a valence" do
      sign_in @author_user
      post save_path, params: { return_to: "assessment:#{@assignment.id}", evidence: {
        assignment_id: @assignment.id, primary_cell: cell(@cap1),
        evidence_type: "project_outcome", content: "Fresh", desired_links: [ cell(@cap1) ]
      } }
      assert_response :see_other
      assert_equal "Select what the feedback says about each linked behaviour", flash[:alert]
      assert_nil ActsAsTenant.with_tenant(@tenant) { EvidenceItem.active.find_by(content: "Fresh") }
    end
  end

  context "edit" do
    should "update content when a content field changes (edited_at set)" do
      id = record!
      sign_in @author_user
      post save_path, params: { return_to: "assessment:#{@assignment.id}", evidence: {
        assignment_id: @assignment.id, evidence_id: id, primary_cell: cell(@cap1),
        evidence_type: "project_outcome", content: "Revised", desired_links: [ cell(@cap1) ]
      } }
      item = ActsAsTenant.with_tenant(@tenant) { EvidenceItem.find(id) }
      assert_equal "Revised", item.content
      assert_not_nil item.edited_at
    end

    should "NOT bump edited_at for a links-only change" do
      id = record!
      sign_in @author_user
      post save_path, params: { return_to: "assessment:#{@assignment.id}", evidence: {
        assignment_id: @assignment.id, evidence_id: id, primary_cell: cell(@cap1),
        evidence_type: "project_outcome", content: "Original", desired_links: [ cell(@cap1), cell(@cap2) ],
        link_valences: { cell(@cap2) => "demonstrated" }
      } }
      item = ActsAsTenant.with_tenant(@tenant) { EvidenceItem.find(id) }
      assert_nil item.edited_at, "links-only change must not emit update_evidence"
      assert_equal Set[[ @cap1.stable_id, 2 ], [ @cap2.stable_id, 2 ]], links_for(id)
    end

    should "reclassify a kept link's valence without bumping edited_at" do
      id = record!
      sign_in @author_user
      post save_path, params: { return_to: "assessment:#{@assignment.id}", evidence: {
        assignment_id: @assignment.id, evidence_id: id, primary_cell: cell(@cap1),
        evidence_type: "project_outcome", content: "Original", desired_links: [ cell(@cap1) ],
        link_valences: { cell(@cap1) => "growth_area" }
      } }
      item = ActsAsTenant.with_tenant(@tenant) { EvidenceItem.find(id) }
      assert_nil item.edited_at, "a valence reclassification is linkage metadata, not a content edit"
      assert_equal({ [ @cap1.stable_id, 2 ] => "growth_area" }, valences_for(id))
    end

    should "leave a kept link untouched when its submitted valence is unchanged" do
      id = record!
      sign_in @author_user
      before = ActsAsTenant.with_tenant(@tenant) do
        Rails.configuration.event_store.read.of_type([ PersonDevelopment::Events::EvidenceLinkRevalenced ]).count
      end
      post save_path, params: { return_to: "assessment:#{@assignment.id}", evidence: {
        assignment_id: @assignment.id, evidence_id: id, primary_cell: cell(@cap1),
        evidence_type: "project_outcome", content: "Original", desired_links: [ cell(@cap1) ],
        link_valences: { cell(@cap1) => "demonstrated" }
      } }
      after = ActsAsTenant.with_tenant(@tenant) do
        Rails.configuration.event_store.read.of_type([ PersonDevelopment::Events::EvidenceLinkRevalenced ]).count
      end
      assert_equal before, after, "resubmitting the same valence must not emit a revalence event"
    end

    should "add and remove links per the desired-set delta" do
      id = record!
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.add_evidence_link(@author.id, @framework_id, id,
          capability_stable_id: @cap2.stable_id, level_ordinal: 2, linked_by_id: @author.id, valence: "demonstrated")
      end
      sign_in @author_user
      # desired = origin only ⇒ drop the cap2 link.
      post save_path, params: { return_to: "assessment:#{@assignment.id}", evidence: {
        assignment_id: @assignment.id, evidence_id: id, primary_cell: cell(@cap1),
        evidence_type: "project_outcome", content: "Original", desired_links: [ cell(@cap1) ]
      } }
      assert_equal Set[[ @cap1.stable_id, 2 ]], links_for(id)
    end

    # The origin cell is a creation fact, not a protected link: the unified
    # "Applies to" block lets an editor remove it like any other row, as long
    # as another link remains. The edit form no longer submits primary_cell.
    should "remove the origin link when the desired set drops it" do
      id = record!
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.add_evidence_link(@author.id, @framework_id, id,
          capability_stable_id: @cap2.stable_id, level_ordinal: 2, linked_by_id: @author.id, valence: "growth_area")
      end
      sign_in @author_user
      post save_path, params: { return_to: "assessment:#{@assignment.id}", evidence: {
        assignment_id: @assignment.id, evidence_id: id,
        evidence_type: "project_outcome", content: "Original", desired_links: [ cell(@cap2) ]
      } }
      assert_equal Set[[ @cap2.stable_id, 2 ]], links_for(id)
      assert ActsAsTenant.with_tenant(@tenant) { EvidenceItem.active.exists?(id: id) },
        "the item survives on its remaining link"
    end
  end

  context "atomicity" do
    should "not apply ANY of an edit when one new link lacks a valence" do
      id = record!
      sign_in @author_user
      # Content change + one valence-less new link in a single submit: the
      # missing valence must reject the whole diff up front, not land the
      # content edit (or earlier links) before aborting.
      post save_path, params: { return_to: "assessment:#{@assignment.id}", evidence: {
        assignment_id: @assignment.id, evidence_id: id, primary_cell: cell(@cap1),
        evidence_type: "project_outcome", content: "Sneaky partial", desired_links: [ cell(@cap1), cell(@cap2) ]
      } }
      assert_response :see_other
      item = ActsAsTenant.with_tenant(@tenant) { EvidenceItem.find(id) }
      assert_equal "Original", item.content, "content update must not land when the link diff is invalid"
      assert_equal Set[[ @cap1.stable_id, 2 ]], links_for(id), "no link may be added"
    end
  end

  context "non-author link (manager)" do
    should "add a link without editing content (disabled fields not submitted)" do
      id = record!
      sign_in @manager_user
      # Manager's modal disables content ⇒ no content/type params; only links.
      post save_path, params: { return_to: "assessment:#{@assignment.id}", evidence: {
        assignment_id: @assignment.id, evidence_id: id, primary_cell: cell(@cap1),
        desired_links: [ cell(@cap1), cell(@cap2) ],
        link_valences: { cell(@cap2) => "demonstrated" }
      } }
      item = ActsAsTenant.with_tenant(@tenant) { EvidenceItem.find(id) }
      assert_nil item.edited_at
      assert_equal "Original", item.content
      assert_equal Set[[ @cap1.stable_id, 2 ], [ @cap2.stable_id, 2 ]], links_for(id)
    end
  end
end
