# frozen_string_literal: true

require "test_helper"

class Assessments::EvidenceControllerTest < ActionDispatch::IntegrationTest
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

      PersonDevelopment::CommandHandler.new.assign_to_framework(
        @assessee.id, framework_id, @role.role_id, @level.level_id
      )

      @assignment = PersonFrameworkAssignment.for_person(@assessee.id).first
    end
  end

  context "POST /assessments/:assessment_id/evidence" do
    should "let the assessee record self evidence" do
      sign_in @assessee_user
      post assessment_evidence_index_path(@assignment), params: {
        evidence: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          evidence_type: "project_outcome",
          title: "Launched the migration",
          content: "Shipped on time."
        }
      }
      follow_redirect!
      assert_response :success

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.last
        assert_not_nil item
        assert_equal "self", item.source
        assert_equal "project_outcome", item.evidence_type
        assert_equal "Launched the migration", item.title
        assert_equal @assessee.id, item.author_id
      end
    end

    should "redirect with both capability and category so the matrix lands on the right tab" do
      sign_in @assessee_user
      post assessment_evidence_index_path(@assignment), params: {
        evidence: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          evidence_type: "project_outcome",
          content: "Done."
        }
      }
      assert_response :redirect
      assert_match "capability=#{@cap.stable_id}", response.location
      assert_match "category=#{@cat.category_id}", response.location
    end

    should "render the new evidence count in the matrix on the post-redirect page" do
      sign_in @assessee_user
      post assessment_evidence_index_path(@assignment), params: {
        evidence: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          evidence_type: "project_outcome",
          content: "Done."
        }
      }
      follow_redirect!
      # The redirect lands with ?capability=&level_ordinal= so the
      # expansion panel renders the evidence content inline.
      assert_match "Done.", response.body
    end

    should "render the new entry in the inline activity feed on the post-redirect page" do
      sign_in @assessee_user
      post assessment_evidence_index_path(@assignment), params: {
        evidence: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          evidence_type: "project_outcome",
          title: "Cookie monster",
          content: "Done."
        }
      }
      follow_redirect!
      # The Feed body is rendered inline inside the activity Turbo Frame
      # on every page render — even when the pane is closed — so the new
      # entry is server-side-present from the moment the redirect lands.
      assert_match "Cookie monster", response.body
    end

    should "reject empty capability_stable_id" do
      sign_in @assessee_user
      post assessment_evidence_index_path(@assignment), params: {
        evidence: {
          capability_stable_id: "",
          level_ordinal: 2,
          evidence_type: "project_outcome",
          content: "x"
        }
      }
      assert_response :unprocessable_content
    end

    should "infer source as 'manager' when manager records on a direct report" do
      sign_in @manager_user
      post assessment_evidence_index_path(@assignment), params: {
        evidence: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          evidence_type: "code_review",
          content: "Strong refactor instinct."
        }
      }
      follow_redirect!

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.last
        assert_equal "manager", item.source
        assert_equal @manager.id, item.author_id
      end
    end

    should "render the new evidence in the assessee's matrix when manager submits" do
      sign_in @manager_user
      post assessment_evidence_index_path(@assignment), params: {
        evidence: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          evidence_type: "code_review",
          title: "Code review note",
          content: "Strong refactor."
        }
      }
      assert_response :redirect
      assert_match "capability=#{@cap.stable_id}", response.location
      assert_match "category=#{@cat.category_id}", response.location

      follow_redirect!
      assert_response :success
      assert_match "Strong refactor.", response.body
      assert_match "Code review note", response.body
    end

    should "accept submission with an empty external_reference hash" do
      sign_in @manager_user
      post assessment_evidence_index_path(@assignment), params: {
        evidence: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          evidence_type: "code_review",
          content: "x",
          external_reference: { system: "", url: "" }
        }
      }
      assert_response :redirect

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.last
        assert_not_nil item
      end
    end

    should "infer source as 'peer' for an unrelated tenant member" do
      sign_in @peer_user
      post assessment_evidence_index_path(@assignment), params: {
        evidence: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          evidence_type: "peer_feedback",
          content: "Strong collaborator."
        }
      }
      follow_redirect!

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.last
        assert_equal "peer", item.source
        assert_equal @peer.id, item.author_id
      end
    end

    should "reject an out-of-range level_ordinal" do
      sign_in @assessee_user
      post assessment_evidence_index_path(@assignment), params: {
        evidence: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 99,
          evidence_type: "project_outcome",
          content: "Ship it."
        }
      }
      assert_response :unprocessable_content
    end

    should "round-trip an external_reference" do
      sign_in @assessee_user
      post assessment_evidence_index_path(@assignment), params: {
        evidence: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          evidence_type: "code_review",
          content: "Reviewed PR.",
          external_reference: { system: "github", url: "https://github.com/o/r/pull/3" }
        }
      }
      follow_redirect!

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.last
        assert_equal "github", item.external_reference.system
        assert_equal "https://github.com/o/r/pull/3", item.external_reference.url
      end
    end

    should "deny an unauthenticated request" do
      post assessment_evidence_index_path(@assignment), params: {
        evidence: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          evidence_type: "project_outcome",
          content: "x"
        }
      }
      assert_redirected_to new_user_session_path
    end
  end

  context "POST /assessments/:assessment_id/evidence/:id/relink" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @new_cap = create(:framework_capability, category_id: @cat.category_id, name: "New Capability")
        create(:framework_capability_role_binding,
          capability_id: @new_cap.capability_id, role_id: @role.role_id, weight: 1.0)
        create(:framework_behavioural_expectation,
          capability_id: @new_cap.capability_id, level_ordinal: 2, description: "New L2")

        @evidence_id = SecureRandom.uuid_v7
        PersonDevelopment::CommandHandler.new.record_evidence(
          @assessee.id, @assignment.framework_id, @evidence_id,
          capability_stable_id: @cap.stable_id, level_ordinal: 2,
          source: "manager", evidence_type: "code_review",
          content: "Original.", author_id: @manager.id
        )
        @item = EvidenceItem.find(@evidence_id)
      end
    end

    should "let the original author relink their own evidence" do
      sign_in @manager_user
      post relink_assessment_evidence_path(@assignment, @item.id), params: {
        evidence: {
          new_capability_stable_id: @new_cap.stable_id,
          new_level_ordinal: 2,
          rationale: "Better fit"
        }
      }
      assert_response :redirect
      assert_match "capability=#{@new_cap.stable_id}", response.location

      ActsAsTenant.with_tenant(@tenant) do
        @item.reload
        assert_equal @new_cap.stable_id, @item.capability_stable_id
        assert_equal 2, @item.level_ordinal
      end
    end

    should "let the assessee relink evidence they didn't author" do
      sign_in @assessee_user
      post relink_assessment_evidence_path(@assignment, @item.id), params: {
        evidence: {
          new_capability_stable_id: @new_cap.stable_id,
          new_level_ordinal: 2
        }
      }
      assert_response :redirect

      ActsAsTenant.with_tenant(@tenant) do
        @item.reload
        assert_equal @new_cap.stable_id, @item.capability_stable_id
      end
    end

    should "deny an unrelated peer" do
      sign_in @peer_user
      post relink_assessment_evidence_path(@assignment, @item.id), params: {
        evidence: {
          new_capability_stable_id: @new_cap.stable_id,
          new_level_ordinal: 2
        }
      }
      assert_response :redirect
      ActsAsTenant.with_tenant(@tenant) do
        @item.reload
        assert_equal @cap.stable_id, @item.capability_stable_id, "evidence should be unchanged"
      end
    end

    should "reject an invalid level_ordinal" do
      sign_in @manager_user
      post relink_assessment_evidence_path(@assignment, @item.id), params: {
        evidence: {
          new_capability_stable_id: @new_cap.stable_id,
          new_level_ordinal: 99
        }
      }
      assert_response :unprocessable_content
    end
  end

  context "PATCH /assessments/:assessment_id/evidence/:id" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @evidence_id = SecureRandom.uuid_v7
        PersonDevelopment::CommandHandler.new.record_evidence(
          @assessee.id, @assignment.framework_id, @evidence_id,
          capability_stable_id: @cap.stable_id, level_ordinal: 2,
          source: "manager", evidence_type: "code_review",
          content: "Original content.", title: "Original title",
          author_id: @manager.id
        )
        @item = EvidenceItem.find(@evidence_id)
      end
    end

    should "let the author edit their own evidence" do
      sign_in @manager_user
      patch assessment_evidence_path(@assignment, @item.id), params: {
        evidence: {
          evidence_type: "code_review",
          title: "Updated title",
          content: "Revised content."
        }
      }
      assert_response :redirect
      assert_match "capability=#{@cap.stable_id}", response.location
      assert_match "category=#{@cat.category_id}", response.location
      # Cell focus must be preserved across the PATCH so the user lands
      # back in the focused state they triggered the edit from — without
      # level_ordinal the cell unfocuses and the evidence list disappears.
      assert_match "level_ordinal=2", response.location

      ActsAsTenant.with_tenant(@tenant) do
        @item.reload
        assert_equal "Updated title", @item.title
        assert_equal "Revised content.", @item.content
        assert_equal @manager.id, @item.edited_by_id
        assert_not_nil @item.edited_at
      end
    end

    should "round-trip an updated external_reference" do
      sign_in @manager_user
      patch assessment_evidence_path(@assignment, @item.id), params: {
        evidence: {
          evidence_type: "code_review",
          content: "x",
          external_reference: { system: "github", url: "https://github.com/o/r/pull/9" }
        }
      }
      assert_response :redirect

      ActsAsTenant.with_tenant(@tenant) do
        @item.reload
        assert_equal "github", @item.external_reference.system
        assert_equal "https://github.com/o/r/pull/9", @item.external_reference.url
      end
    end

    should "reject a malicious external_reference URL upfront" do
      sign_in @manager_user
      patch assessment_evidence_path(@assignment, @item.id), params: {
        evidence: {
          evidence_type: "code_review",
          content: "x",
          external_reference: { system: "github", url: "javascript:alert(1)" }
        }
      }
      assert_response :unprocessable_content

      ActsAsTenant.with_tenant(@tenant) do
        @item.reload
        assert_equal "Original content.", @item.content
      end
    end

    should "deny a non-author (assessee)" do
      sign_in @assessee_user
      patch assessment_evidence_path(@assignment, @item.id), params: {
        evidence: {
          evidence_type: "code_review",
          content: "Hijacked content."
        }
      }
      assert_response :redirect
      ActsAsTenant.with_tenant(@tenant) do
        @item.reload
        assert_equal "Original content.", @item.content
      end
    end

    should "deny an unrelated peer" do
      sign_in @peer_user
      patch assessment_evidence_path(@assignment, @item.id), params: {
        evidence: {
          evidence_type: "code_review",
          content: "Hijacked."
        }
      }
      assert_response :redirect
      ActsAsTenant.with_tenant(@tenant) do
        @item.reload
        assert_equal "Original content.", @item.content
      end
    end
  end

  context "DELETE /assessments/:assessment_id/evidence/:id" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @evidence_id = SecureRandom.uuid_v7
        PersonDevelopment::CommandHandler.new.record_evidence(
          @assessee.id, @assignment.framework_id, @evidence_id,
          capability_stable_id: @cap.stable_id, level_ordinal: 2,
          source: "manager", evidence_type: "code_review",
          content: "Reviewed PR.", author_id: @manager.id
        )
        @item = EvidenceItem.find(@evidence_id)
      end
    end

    should "let the author withdraw their own evidence" do
      sign_in @manager_user
      delete assessment_evidence_path(@assignment, @item.id)
      follow_redirect!

      ActsAsTenant.with_tenant(@tenant) do
        @item.reload
        assert_equal "withdrawn", @item.link_status
        assert_equal @manager.id, @item.withdrawn_by_id
      end
    end

    should "deny non-author non-admin viewers" do
      sign_in @peer_user
      delete assessment_evidence_path(@assignment, @item.id)
      assert_response :redirect
      ActsAsTenant.with_tenant(@tenant) do
        @item.reload
        assert_equal "active", @item.link_status
      end
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
