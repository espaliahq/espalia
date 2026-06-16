# frozen_string_literal: true

require "test_helper"

class Frameworks::CategoriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @owner_person = create(:person, tenant: @tenant, email: @user.email)
      create(:tenant_user, tenant: @tenant, user: @user, role: :admin, person: @owner_person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "E1", "E1")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)
      handler.add_collaborator(@framework_id, @owner_person.id.to_s, "owner", added_by: @owner_person.id.to_s)
      handler.publish_version(@framework_id, "test")
    end
  end

  context "PATCH /frameworks/:framework_id/categories/:id" do
    should "submit a suggest_edit and return the re-rendered name frame" do
      sign_in @user
      patch framework_category_path(framework_id: @framework_id, id: @cat_id),
            params: { capability_category: { name: "Cognition & Thinking" } }

      assert_response :success
      assert_includes response.body, "category-name-#{@cat_id}"
      assert_includes response.body, "Cognition &amp; Thinking"
    end

    should "submit a description suggest_edit and return the re-rendered description frame" do
      sign_in @user
      patch framework_category_path(framework_id: @framework_id, id: @cat_id),
            params: { capability_category: { description: "How we reason and decide." } }

      assert_response :success
      assert_includes response.body, "category-description-#{@cat_id}"
      assert_includes response.body, "How we reason and decide."
    end

    should "amend the author's pending suggestion on a consecutive edit, not stack a new one" do
      sign_in @user
      cookies[:framework_edit_mode] = "suggesting"

      patch framework_category_path(framework_id: @framework_id, id: @cat_id),
            params: { capability_category: { name: "First proposal" } }
      patch framework_category_path(framework_id: @framework_id, id: @cat_id),
            params: { capability_category: { name: "Second proposal" } }

      ActsAsTenant.with_tenant(@tenant) do
        pending = FrameworkState::SuggestedEdit.where(
          framework_id: @framework_id, target_entity_type: "capability_category",
          target_entity_id: @cat_id, field: "name", status: "pending"
        )
        assert_equal 1, pending.count, "consecutive edits by the same author must amend, not stack"
        assert_equal "Second proposal", pending.first.suggested_value

        # The amend is recorded as a SuggestionAmended event (not a second EditSuggested).
        stream = Rails.configuration.event_store.read
          .stream(EventStreamNaming.framework_stream(@framework_id)).to_a
        assert_equal 1, stream.count { |e| e.is_a?(Frameworks::Events::EditSuggested) && e.data[:field] == "name" }
        assert_equal 1, stream.count { |e| e.is_a?(Frameworks::Events::SuggestionAmended) }
      end
    end

    should "not amend across different fields (name vs description are separate suggestions)" do
      sign_in @user
      cookies[:framework_edit_mode] = "suggesting"

      patch framework_category_path(framework_id: @framework_id, id: @cat_id),
            params: { capability_category: { name: "New name" } }
      patch framework_category_path(framework_id: @framework_id, id: @cat_id),
            params: { capability_category: { description: "New description" } }

      ActsAsTenant.with_tenant(@tenant) do
        scope = FrameworkState::SuggestedEdit.where(
          framework_id: @framework_id, target_entity_type: "capability_category",
          target_entity_id: @cat_id, status: "pending"
        )
        assert_equal 1, scope.where(field: "name").count
        assert_equal 1, scope.where(field: "description").count
      end
    end

    should "keep a description edit pending when the suggesting cookie is set" do
      sign_in @user
      cookies[:framework_edit_mode] = "suggesting"
      patch framework_category_path(framework_id: @framework_id, id: @cat_id),
            params: { capability_category: { description: "Proposed description" } }

      ActsAsTenant.with_tenant(@tenant) do
        suggestion = FrameworkState::SuggestedEdit.where(
          framework_id: @framework_id,
          target_entity_type: "capability_category",
          target_entity_id: @cat_id,
          field: "description"
        ).last
        assert_equal "pending", suggestion.status
        assert_equal "Proposed description", suggestion.suggested_value
      end
    end

    should "keep the edit pending when the suggesting cookie is set" do
      sign_in @user
      cookies[:framework_edit_mode] = "suggesting"
      patch framework_category_path(framework_id: @framework_id, id: @cat_id),
            params: { capability_category: { name: "Proposed Name" } }

      ActsAsTenant.with_tenant(@tenant) do
        suggestion = FrameworkState::SuggestedEdit.where(
          framework_id: @framework_id,
          target_entity_type: "capability_category",
          target_entity_id: @cat_id
        ).last
        assert_equal "pending", suggestion.status
      end
    end

    should "deny non-contributor viewers" do
      viewer = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: viewer, role: :member)
      end
      sign_in viewer

      patch framework_category_path(framework_id: @framework_id, id: @cat_id),
            params: { capability_category: { name: "blocked" } }

      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
    end

    should "404 when the category has been archived" do
      ActsAsTenant.with_tenant(@tenant) do
        FrameworkState::CapabilityCategory.find_by!(category_id: @cat_id).update!(status: "archived")
      end

      sign_in @user
      patch framework_category_path(framework_id: @framework_id, id: @cat_id),
            params: { capability_category: { name: "Cannot edit" } }

      assert_response :not_found
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
