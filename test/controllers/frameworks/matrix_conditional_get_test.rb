# frozen_string_literal: true

require "test_helper"

# Conditional GET on the explorer's matrix and expanded-row endpoints (#383).
#
# Filtering is a round trip: users toggle a role off to look at something, then
# toggle it back. Without an ETag the second toggle re-downloads and re-parses
# the whole grid to render exactly the bytes the browser already holds.
#
# Uses the command handler rather than factories on purpose — the key is built
# from the persisted `FrameworkExplorerGraph` snapshot, which only the command
# path writes. A factory-built framework has no snapshot and deliberately gets
# no ETag at all (asserted below), because nothing about its freshness is
# captured.
class Frameworks::MatrixConditionalGetTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @user, role: :admin)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Conditional GET Framework")

      family_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      @other_role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, family_id, "Engineering", department: "Engineering")
      handler.add_role(@framework_id, @role_id, family_id, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @role_id, 1, "Engineer I", "E1", is_entry: true)
      handler.add_role(@framework_id, @other_role_id, family_id, "Engineering Manager", "EM", "management")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @other_role_id, 1, "EM I", "EM1", is_entry: true)

      @category_id = SecureRandom.uuid_v7
      @capability_id = SecureRandom.uuid_v7
      @second_capability_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, @category_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, @capability_id, SecureRandom.uuid_v7, @category_id,
                             "Strategic Thinking")
      handler.add_capability(@framework_id, @second_capability_id, SecureRandom.uuid_v7, @category_id,
                             "Systems Thinking")
      [ @capability_id, @second_capability_id ].each do |cap_id|
        handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, @role_id)
        handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, @other_role_id)
        handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                            cap_id, 1, "Weighs options and explains reasoning")
      end

      handler.publish_version(@framework_id, "test")
    end

    sign_in @user
  end

  context "GET /frameworks/:id/matrix" do
    should "answer 304 when the browser already holds the rendered grid" do
      get matrix_framework_path(@framework_id)
      assert_response :success
      etag = response.headers["ETag"]
      assert etag.present?, "expected an ETag on the matrix frame"
      assert response.body.present?

      get matrix_framework_path(@framework_id), headers: { "HTTP_IF_NONE_MATCH" => etag }
      assert_response :not_modified
      assert_predicate response.body, :empty?
    end

    should "re-render when the role filter moves, and 304 again on the way back" do
      get matrix_framework_path(@framework_id)
      all_roles_etag = response.headers["ETag"]

      get matrix_framework_path(@framework_id, roles: [ @role_id ]),
          headers: { "HTTP_IF_NONE_MATCH" => all_roles_etag }
      assert_response :success
      one_role_etag = response.headers["ETag"]
      assert_not_equal all_roles_etag, one_role_etag

      # The round trip users actually make: filter, look, unfilter.
      get matrix_framework_path(@framework_id), headers: { "HTTP_IF_NONE_MATCH" => all_roles_etag }
      assert_response :not_modified
    end

    should "re-render when the text query moves" do
      get matrix_framework_path(@framework_id)
      etag = response.headers["ETag"]

      get matrix_framework_path(@framework_id, q: "Systems"),
          headers: { "HTTP_IF_NONE_MATCH" => etag }
      assert_response :success
    end

    should "re-render when the framework itself changes" do
      get matrix_framework_path(@framework_id)
      etag = response.headers["ETag"]

      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::CommandHandler.new.update_capability(
          @framework_id, @capability_id, name: "Strategic Thinking (revised)"
        )
      end

      get matrix_framework_path(@framework_id), headers: { "HTTP_IF_NONE_MATCH" => etag }
      assert_response :success
      assert_includes response.body, "Strategic Thinking (revised)"
    end

    should "keep the response out of shared caches" do
      get matrix_framework_path(@framework_id)

      # The grid is viewer-scoped, so a shared cache must never hold it — which
      # is also why the ETag itself carries the viewer (below).
      assert_includes response.headers["Cache-Control"].to_s, "private"
    end

    should "never hand one viewer's grid to another" do
      get matrix_framework_path(@framework_id)
      admin_etag = response.headers["ETag"]

      sign_in plain_member

      get matrix_framework_path(@framework_id), headers: { "HTTP_IF_NONE_MATCH" => admin_etag }
      assert_response :success
      assert_not_equal admin_etag, response.headers["ETag"]
    end
  end

  context "GET /frameworks/:id/edit/matrix" do
    should "re-render when a pending suggestion lands" do
      get edit_matrix_framework_path(@framework_id)
      assert_response :success
      etag = response.headers["ETag"]

      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::CommandHandler.new.suggest_edit(
          @framework_id, SecureRandom.uuid_v7, "capability", @capability_id,
          "name", "Systemic Thinking", create(:person, tenant: @tenant).id, mode: :suggesting
        )
      end

      get edit_matrix_framework_path(@framework_id), headers: { "HTTP_IF_NONE_MATCH" => etag }
      assert_response :success
    end

    should "not hand one viewer's grid to another with different authority" do
      # Edit mode DOES differ per viewer — the approve/reject kebab items are
      # gated on the viewer's tier — so the key has to carry that authority or a
      # shared ETag would show a lead's affordances to a plain collaborator.
      get edit_matrix_framework_path(@framework_id)
      admin_etag = response.headers["ETag"]

      sign_in collaborator_member

      get edit_matrix_framework_path(@framework_id), headers: { "HTTP_IF_NONE_MATCH" => admin_etag }
      assert_response :success
      assert_not_equal admin_etag, response.headers["ETag"]
    end

    should "key edit mode separately from view mode" do
      get matrix_framework_path(@framework_id)
      view_etag = response.headers["ETag"]

      get edit_matrix_framework_path(@framework_id), headers: { "HTTP_IF_NONE_MATCH" => view_etag }
      assert_response :success
      assert_not_equal view_etag, response.headers["ETag"]
    end
  end

  context "GET /frameworks/:id/expanded_rows/:capability_id" do
    should "answer 304 for a row the browser already holds" do
      get expanded_row_framework_path(@framework_id, @capability_id)
      assert_response :success
      etag = response.headers["ETag"]

      get expanded_row_framework_path(@framework_id, @capability_id),
          headers: { "HTTP_IF_NONE_MATCH" => etag }
      assert_response :not_modified
    end

    should "serve a row the grid matched only through its category's proposed text" do
      # In edit mode the search haystack folds in the category's pending
      # name/description, so a capability can be visible in the grid purely
      # because of them. The row's own scoped suggestion read has to see the
      # category too, or expanding it 404s on a row the user is looking at.
      person = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant) }
      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::CommandHandler.new.suggest_edit(
          @framework_id, SecureRandom.uuid_v7, "capability_category", @category_id,
          "name", "Reasoning Under Uncertainty", person.id, mode: :suggesting
        )
      end

      get edit_matrix_framework_path(@framework_id, q: "Uncertainty")
      assert_response :success
      assert_includes response.body, "Strategic Thinking"

      get edit_expanded_row_framework_path(@framework_id, @capability_id, q: "Uncertainty")
      assert_response :success
    end

    should "not reuse one capability's row for another" do
      get expanded_row_framework_path(@framework_id, @capability_id)
      etag = response.headers["ETag"]

      get expanded_row_framework_path(@framework_id, @second_capability_id),
          headers: { "HTTP_IF_NONE_MATCH" => etag }
      assert_response :success
    end
  end

  context "a framework with no persisted graph snapshot" do
    # The graph is rebuilt on the fly from FrameworkState::* here, and the key
    # captures nothing about those tables' freshness — so the controller sets no
    # ETag of its own and an edit must still reach the viewer. (Rack::ETag may
    # still digest the body, which is safe by construction: it changes with the
    # bytes.)
    should "never answer a stale 304 after a change its key could not see" do
      ActsAsTenant.with_tenant(@tenant) do
        @ar_only = create(:framework_state, framework_id: SecureRandom.uuid_v7, name: "Factory Framework")
        rf = create(:framework_role_family, framework_id: @ar_only.framework_id, name: "Ops")
        role = create(:framework_role, role_family_id: rf.role_family_id, name: "Analyst", code: "A", track: "ic")
        create(:framework_level, role_id: role.role_id, ordinal: 1, title: "A1", code: "A1")
        cat = create(:framework_capability_category, framework_id: @ar_only.framework_id,
                     name: "Delivery", ordinal: 1)
        @ar_capability = create(:framework_capability, category_id: cat.category_id, name: "Original Name")
        create(:framework_capability_role_binding,
               capability_id: @ar_capability.capability_id, role_id: role.role_id)
        create(:framework_behavioural_expectation, capability_id: @ar_capability.capability_id,
               level_ordinal: 1, description: "Delivers")
      end

      get matrix_framework_path(@ar_only.framework_id)
      assert_response :success
      assert_includes response.body, "Original Name"
      etag = response.headers["ETag"]

      ActsAsTenant.with_tenant(@tenant) { @ar_capability.update!(name: "Renamed Outside The Graph") }

      get matrix_framework_path(@ar_only.framework_id), headers: { "HTTP_IF_NONE_MATCH" => etag }
      assert_response :success
      assert_includes response.body, "Renamed Outside The Graph"
    end
  end

  private

  # A tenant member with no framework role — sees the published grid only.
  def plain_member
    user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: user) }
    user
  end

  # A suggest-rights collaborator: reaches edit mode, approves nothing.
  def collaborator_member
    user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      person = create(:person, tenant: @tenant, email: user.email)
      create(:tenant_user, tenant: @tenant, user: user, person: person)
      create(:framework_collaborator, tenant: @tenant, framework_id: @framework_id,
             person_id: person.id, role: "collaborator")
    end
    user
  end

  # Signs in AND lands on the page the sign-in redirects to. The landing matters:
  # Rails mixes the flash into every ETag (ActionController::EtagWithFlash), so a
  # request still carrying the sign-in notice keys differently from the identical
  # one after it. Real frame fetches always follow a page load that consumed it.
  def sign_in(user)
    # Fresh session first: Devise refuses a second sign-in while one is active,
    # so signing in "as someone else" would silently keep the previous identity
    # and make a per-viewer assertion pass for the wrong reason.
    reset!
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
    follow_redirect!
  end
end
