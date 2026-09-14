# frozen_string_literal: true

require "test_helper"

class Frameworks::PublicationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      Frameworks::CommandHandler.new.create_framework(@framework_id, "Test Framework")
    end
  end

  def framework
    ActsAsTenant.with_tenant(@tenant) { FrameworkState::Framework.find_by!(framework_id: @framework_id) }
  end

  context "GET /frameworks/:framework_id/publication/new (review)" do
    should "render the review page for an admin with nothing retiring" do
      sign_in @admin_user
      get new_framework_publication_path(framework_id: @framework_id)

      assert_response :success
      assert_includes response.body, "Publish v1"
      assert_includes response.body, "No capabilities are being retired"
    end

    should "list a retiring capability that still needs a mapping" do
      cap_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        cat_id = SecureRandom.uuid_v7
        handler.add_capability_category(@framework_id, cat_id, "Thinking")
        handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Legacy Systems")
        handler.publish_version(@framework_id, "seed")            # v1, cap pre-draft
        handler.archive_capability(@framework_id, cap_id, reason: "x") # auto-opens v2, no mapping
      end

      sign_in @admin_user
      get new_framework_publication_path(framework_id: @framework_id)

      assert_response :success
      assert_includes response.body, "Legacy Systems"
      assert_includes response.body, "Needs a mapping"
    end

    should "redirect non-publisher members" do
      sign_in @member_user
      get new_framework_publication_path(framework_id: @framework_id)
      assert_redirected_to root_path
    end

    should "send an admin back to the framework when there is no draft" do
      ActsAsTenant.with_tenant(@tenant) { Frameworks::CommandHandler.new.publish_version(@framework_id, "seed") }

      sign_in @admin_user
      get new_framework_publication_path(framework_id: @framework_id)

      assert_redirected_to edit_framework_path(@framework_id)
      assert_equal "No draft in progress.", flash[:alert]
    end
  end

  context "POST /frameworks/:framework_id/publication" do
    should "record the request, enqueue the publish job and redirect with a notice" do
      sign_in @admin_user

      assert_enqueued_with(job: Frameworks::PublishVersionJob) do
        post framework_publication_path(framework_id: @framework_id)
      end

      assert_redirected_to edit_framework_path(@framework_id)
      assert_match(/Publishing v1 in the background/, flash[:notice])
      publication = ActsAsTenant.with_tenant(@tenant) { FrameworkPublication.find_by!(framework_id: @framework_id) }
      assert publication.queued?
      assert_equal 1, publication.draft_version
      assert_equal @admin_user, publication.requested_by.user
      assert framework.draft_in_progress, "nothing is published until the job runs"
    end

    should "publish once the job runs" do
      sign_in @admin_user
      perform_enqueued_jobs(only: Frameworks::PublishVersionJob) do
        post framework_publication_path(framework_id: @framework_id)
      end

      assert_equal 1, framework.current_published_version
      assert_not framework.draft_in_progress
    end

    should "refuse a second request while one is in flight" do
      sign_in @admin_user
      post framework_publication_path(framework_id: @framework_id)

      assert_no_enqueued_jobs(only: Frameworks::PublishVersionJob) do
        post framework_publication_path(framework_id: @framework_id)
      end
      assert_redirected_to edit_framework_path(@framework_id)
      assert_equal "v1 is already being published.", flash[:alert]
      assert_equal 1, ActsAsTenant.with_tenant(@tenant) { FrameworkPublication.where(framework_id: @framework_id).count }
    end

    should "refuse to enqueue while a retiring capability has no mapping" do
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        cat_id = SecureRandom.uuid_v7
        cap_id = SecureRandom.uuid_v7
        handler.add_capability_category(@framework_id, cat_id, "Thinking")
        handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Legacy Systems")
        handler.publish_version(@framework_id, "seed")
        handler.archive_capability(@framework_id, cap_id, reason: "x")
      end

      sign_in @admin_user
      assert_no_enqueued_jobs(only: Frameworks::PublishVersionJob) do
        post framework_publication_path(framework_id: @framework_id)
      end

      assert_redirected_to new_framework_publication_path(@framework_id)
      assert_match(/Add a migration mapping before publishing: Legacy Systems/, flash[:alert])
    end

    should "refuse immediately when there is no draft" do
      ActsAsTenant.with_tenant(@tenant) { Frameworks::CommandHandler.new.publish_version(@framework_id, "seed") }

      sign_in @admin_user
      assert_no_enqueued_jobs(only: Frameworks::PublishVersionJob) do
        post framework_publication_path(framework_id: @framework_id)
      end

      assert_redirected_to edit_framework_path(@framework_id)
      assert_equal "No draft in progress.", flash[:alert]
      assert_equal 0, ActsAsTenant.with_tenant(@tenant) { FrameworkPublication.where(framework_id: @framework_id).count }
    end

    should "redirect non-publisher members with an authorization alert" do
      sign_in @member_user
      post framework_publication_path(framework_id: @framework_id)

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
      assert framework.draft_in_progress
    end

    should "redirect unauthenticated users to sign in" do
      post framework_publication_path(framework_id: @framework_id)
      assert_redirected_to new_user_session_path
    end
  end

  context "GET review while a publish is in flight" do
    should "show the publishing state and disable the confirm button" do
      sign_in @admin_user
      post framework_publication_path(framework_id: @framework_id)

      get new_framework_publication_path(framework_id: @framework_id)

      assert_response :success
      assert_includes response.body, "Publishing v1…"
      assert_no_match(/Confirm &amp; publish v1/, response.body)
    end

    should "show why the last attempt failed" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:framework_publication, tenant: @tenant, framework_id: @framework_id, draft_version: 1,
          status: :failed, error_message: "Publish gate: capability needs a mapping.")
      end

      sign_in @admin_user
      get new_framework_publication_path(framework_id: @framework_id)

      assert_includes response.body, "The last publish attempt failed:"
      assert_includes response.body, "capability needs a mapping"
      assert_includes response.body, "Confirm &amp; publish v1"
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
