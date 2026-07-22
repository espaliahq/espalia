# frozen_string_literal: true

require "test_helper"

class Assessments::EvidenceLinkThreadsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @assessee_user = create(:user, password: "password123")
    @manager_user = create(:user, password: "password123")
    @peer_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Mgr")
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)

      @assessee = create(:person, tenant: @tenant, email: @assessee_user.email, name: "Dev",
        manager: @manager)
      create(:tenant_user, tenant: @tenant, user: @assessee_user, person: @assessee)

      @peer = create(:person, tenant: @tenant, email: @peer_user.email, name: "Peer")
      create(:tenant_user, tenant: @tenant, user: @peer_user, person: @peer)

      framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: framework_id, name: "Engineering Growth")
      rf = create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      @role = create(:framework_role,
        role_family_id: rf.role_family_id, name: "Software Engineer", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")
      @cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: @cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding,
        capability_id: @cap.capability_id, role_id: @role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "Synthesises")

      handler = PersonDevelopment::CommandHandler.new
      handler.assign_to_framework(@assessee.id, framework_id, @role.role_id, @level.level_id)
      @assignment = PersonFrameworkAssignment.for_person(@assessee.id).first

      @evidence_id = SecureRandom.uuid_v7
      handler.record_evidence(
        @assessee.id, framework_id, @evidence_id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2,
        source: "manager", evidence_type: "observation",
        content: "Handled the incident well.", author_id: @manager.id,
        valence: "demonstrated",
        additional_links: [
          { capability_stable_id: @cap.stable_id, level_ordinal: 3, valence: "growth_area" }
        ]
      )
    end
  end

  def thread_path(level_ordinal: 2, evidence_id: @evidence_id)
    assessment_evidence_link_thread_path(
      @assignment, evidence_id,
      capability_stable_id: @cap.stable_id, level_ordinal: level_ordinal
    )
  end

  context "GET link_thread" do
    should "render the thread frame with the linked lifecycle row for the manager" do
      sign_in @manager_user
      get thread_path
      assert_response :success
      assert_match "evidence-link-thread-#{@evidence_id}-#{@cap.stable_id}-2", response.body
      assert_match "linked this feedback", response.body
      assert_match "Demonstrates", response.body
    end

    should "interleave comments and show the composer for the assessee" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.post_comment(
          @assessee.id, @assignment.framework_id, SecureRandom.uuid_v7,
          commentable_type: PersonDevelopmentComment::EVIDENCE_LINK,
          capability_stable_id: @cap.stable_id, level_ordinal: 2,
          evidence_id: @evidence_id,
          body: "Is this really a growth signal?", author_id: @manager.id
        )
      end

      sign_in @assessee_user
      get thread_path
      assert_response :success
      assert_match "Is this really a growth signal?", response.body
      assert_match "Discuss this feedback", response.body
    end

    should "show the removed-link notice but keep the composer" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.remove_evidence_link(
          @assessee.id, @assignment.framework_id, @evidence_id,
          capability_stable_id: @cap.stable_id, level_ordinal: 2,
          removed_by_id: @manager.id, reason: "Agreed it fits L3 better"
        )
      end

      sign_in @manager_user
      get thread_path
      assert_response :success
      assert_match "no longer linked to this behaviour", response.body
      assert_match "removed this feedback", response.body
      assert_match "Agreed it fits L3 better", response.body
      assert_match "Discuss this feedback", response.body
    end

    should "render read-only when the item is withdrawn" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.withdraw_evidence(
          @assessee.id, @assignment.framework_id, @evidence_id,
          withdrawn_by_id: @manager.id
        )
      end

      sign_in @assessee_user
      get thread_path
      assert_response :success
      assert_match "read-only", response.body
      assert_no_match(/Discuss this feedback/, response.body)
    end

    should "show the valence change as a lifecycle row" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.set_evidence_link_valence(
          @assessee.id, @assignment.framework_id, @evidence_id,
          capability_stable_id: @cap.stable_id, level_ordinal: 2,
          valence: "growth_area", changed_by_id: @manager.id
        )
      end

      sign_in @manager_user
      get thread_path
      assert_response :success
      assert_match "changed the valence to “Growth area”", response.body
      assert_match "was “Demonstrates”", response.body
    end

    should "deny a peer (no assessment view) with a redirect" do
      sign_in @peer_user
      get thread_path
      assert_response :redirect
    end

    should "404 an evidence id belonging to another person" do
      ActsAsTenant.with_tenant(@tenant) do
        other = create(:person, tenant: @tenant, name: "Other", manager: @manager)
        handler = PersonDevelopment::CommandHandler.new
        handler.assign_to_framework(other.id, @assignment.framework_id, @role.role_id, @level.level_id)
        @foreign_evidence_id = SecureRandom.uuid_v7
        handler.record_evidence(
          other.id, @assignment.framework_id, @foreign_evidence_id,
          capability_stable_id: @cap.stable_id, level_ordinal: 2,
          source: "self", evidence_type: "observation",
          content: "Someone else's.", author_id: other.id, valence: "demonstrated"
        )
      end

      sign_in @manager_user
      get thread_path(evidence_id: @foreign_evidence_id)
      assert_response :not_found
    end
  end

  context "POST comments with evidence_id (evidence-link thread)" do
    should "record an evidence_link comment and redirect back to the frame" do
      sign_in @manager_user
      post assessment_comments_path(@assignment), params: {
        comment: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          evidence_id: @evidence_id,
          body: "I read this as a growth signal."
        }
      }
      assert_redirected_to thread_path

      ActsAsTenant.with_tenant(@tenant) do
        c = PersonDevelopmentComment.order(:posted_at).last
        assert_equal PersonDevelopmentComment::EVIDENCE_LINK, c.commentable_type
        assert_equal @evidence_id, c.evidence_id
        assert_equal @cap.stable_id, c.capability_stable_id
        assert_equal 2, c.level_ordinal
      end
    end

    should "surface an aggregate rejection as the frame's error param" do
      sign_in @manager_user
      post assessment_comments_path(@assignment), params: {
        comment: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 7, # never linked at this level
          evidence_id: @evidence_id,
          body: "Won't land."
        }
      }
      assert_response :redirect
      assert_match(/error=/, response.location)

      follow_redirect!
      assert_match "never linked", response.body
    end

    should "route an edit of an evidence_link comment back to the frame" do
      comment_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.post_comment(
          @assessee.id, @assignment.framework_id, comment_id,
          commentable_type: PersonDevelopmentComment::EVIDENCE_LINK,
          capability_stable_id: @cap.stable_id, level_ordinal: 2,
          evidence_id: @evidence_id,
          body: "Original.", author_id: @manager.id
        )
      end

      sign_in @manager_user
      patch assessment_comment_path(@assignment, comment_id), params: {
        comment: { body: "Amended." }
      }
      assert_redirected_to thread_path

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "Amended.", PersonDevelopmentComment.find(comment_id).body
      end
    end
  end
end
