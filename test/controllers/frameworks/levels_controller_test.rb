# frozen_string_literal: true

require "test_helper"

class Frameworks::LevelsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email)
      create(:tenant_user, tenant: @tenant, user: @user, role: :admin, person: @person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rf_id = SecureRandom.uuid_v7
      @role_id = role_id = SecureRandom.uuid_v7
      @level_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, role_id, rf_id, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, @level_id, role_id, 1, "Software Engineer I", "E1")
      @level2_id = SecureRandom.uuid_v7
      handler.add_level(@framework_id, @level2_id, role_id, 2, "Software Engineer II", "E2")
      handler.publish_version(@framework_id, "test")
    end
  end

  context "PATCH /frameworks/:framework_id/levels/:id" do
    should "rename the level title and return the re-rendered title frame" do
      sign_in @user
      patch framework_level_path(framework_id: @framework_id, id: @level_id),
            params: { level: { title: "Engineer I" } }

      assert_response :success
      assert_includes response.body, "level-title-#{@level_id}"
      assert_includes response.body, "Engineer I"

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "Engineer I", FrameworkState::Level.find_by(level_id: @level_id).title
      end
    end

    # A bodyless 422 inside a frame is invisible (Hard-Won Lesson 26).
    should "re-render the title frame at 422 with the error and the typed text" do
      sign_in @user
      patch framework_level_path(framework_id: @framework_id, id: @level_id),
            params: { level: { title: "   " } }

      assert_response :unprocessable_content
      assert_select "turbo-frame#level-title-#{@level_id}" do
        assert_select "[data-editor-error='the title can’t be blank'][data-editor-value='   ']"
        assert_select "[role=alert]", text: "Couldn’t save: the title can’t be blank"
      end
    end

    should "404 on an unknown level id (not a masked 422)" do
      sign_in @user
      patch framework_level_path(framework_id: @framework_id, id: SecureRandom.uuid_v7),
            params: { level: { title: "Whatever" } }

      assert_response :not_found
    end

    should "deny non-contributor viewers" do
      viewer = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: viewer, role: :member) }
      sign_in viewer

      patch framework_level_path(framework_id: @framework_id, id: @level_id),
            params: { level: { title: "blocked" } }

      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
    end
  end

  context "POST /frameworks/:framework_id/levels" do
    should "add the level into a draft and answer the toast + draft status" do
      sign_in @user
      post framework_levels_path(framework_id: @framework_id),
           params: { level: { role_id: @role_id, ordinal: "3", title: "Software Engineer III",
                              code: "E3", is_entry: "0" },
                     roles: [ @role_id ], track: "both" }

      # A level adds a COLUMN to every row, so the grid update stays the
      # documented matrix#refresh (dispatched client-side) — but the response
      # itself is a stream, so the page is never navigated away (#381).
      assert_write_toast(/Added level/)
      assert_no_navigation
      assert_turbo_stream_action("replace", "framework-draft-badge")

      ActsAsTenant.with_tenant(@tenant) do
        # Shape-changing: draft opened, level deferred from the published read model.
        assert FrameworkState::Framework.find_by(framework_id: @framework_id).draft_in_progress
        assert_nil FrameworkState::Level.find_by(role_id: @role_id, ordinal: 3)
      end
    end

    should "surface a duplicate ordinal in the toast, not a 500" do
      sign_in @user
      post framework_levels_path(framework_id: @framework_id),
           params: { level: { role_id: @role_id, ordinal: "1", title: "Dup", code: "D1" } }

      assert_write_toast(/already has a level at ordinal 1/, status: :unprocessable_content)
      assert_no_navigation
    end

    should "deny non-contributor viewers" do
      viewer = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: viewer, role: :member) }
      sign_in viewer

      post framework_levels_path(framework_id: @framework_id),
           params: { level: { role_id: @role_id, ordinal: "2", title: "Blocked", code: "B2" } }

      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
      ActsAsTenant.with_tenant(@tenant) do
        assert_not FrameworkState::Framework.find_by(framework_id: @framework_id).draft_in_progress
      end
    end
  end

  context "the levels editor (level-editor frame)" do
    should "render the role's levels for the index" do
      sign_in @user
      get framework_levels_path(framework_id: @framework_id), params: { role_id: @role_id }

      assert_response :success
      assert_includes response.body, "level-editor"
      assert_includes response.body, "Software Engineer I"
      assert_includes response.body, "Software Engineer II"
      assert_includes response.body, "Set as entry"
    end

    should "404 the index for a role outside this framework" do
      sign_in @user
      get framework_levels_path(framework_id: @framework_id), params: { role_id: SecureRandom.uuid_v7 }
      assert_response :not_found
    end

    should "save code + title from a row and re-render the frame" do
      sign_in @user
      patch framework_level_path(framework_id: @framework_id, id: @level_id),
            params: { level: { title: "Engineer I", code: "ENG1" } },
            headers: { "Turbo-Frame" => "level-editor" }

      assert_response :success
      assert_includes response.body, "level-editor"
      ActsAsTenant.with_tenant(@tenant) do
        level = FrameworkState::Level.find_by(level_id: @level_id)
        assert_equal "Engineer I", level.title
        assert_equal "ENG1", level.code
      end
    end

    should "move the entry flag with radio-with-clear semantics" do
      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::CommandHandler.new.update_level_details(@framework_id, @level_id, is_entry: true)
      end

      sign_in @user
      patch framework_level_path(framework_id: @framework_id, id: @level2_id),
            params: { level: { is_entry: "1" } },
            headers: { "Turbo-Frame" => "level-editor" }

      assert_response :success
      ActsAsTenant.with_tenant(@tenant) do
        assert FrameworkState::Level.find_by(level_id: @level2_id).is_entry
        assert_not FrameworkState::Level.find_by(level_id: @level_id).is_entry,
                   "previous entry level must lose the flag"
      end
    end

    should "add a level from the editor's add row and re-render the frame" do
      sign_in @user
      post framework_levels_path(framework_id: @framework_id),
           params: { level: { role_id: @role_id, ordinal: "3", title: "Engineer III", code: "E3" } },
           headers: { "Turbo-Frame" => "level-editor" }

      assert_response :success
      assert_includes response.body, "level-editor"
      # Draft-added → in the frame (graph-sourced) with the wiggle, not the read model.
      assert_includes response.body, "Engineer III"
      assert_includes response.body, "decoration-wavy"
      ActsAsTenant.with_tenant(@tenant) do
        assert_nil FrameworkState::Level.find_by(role_id: @role_id, ordinal: 3)
      end
    end

    should "surface a duplicate ordinal as an in-frame error, not a redirect" do
      sign_in @user
      post framework_levels_path(framework_id: @framework_id),
           params: { level: { role_id: @role_id, ordinal: "1", title: "Dup", code: "D1" } },
           headers: { "Turbo-Frame" => "level-editor" }

      assert_response :unprocessable_content
      assert_includes response.body, "level-editor"
      assert_includes response.body, "already has a level at ordinal 1"
    end

    should "deny non-contributor viewers the editor" do
      viewer = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: viewer, role: :member) }
      sign_in viewer

      get framework_levels_path(framework_id: @framework_id), params: { role_id: @role_id }
      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
