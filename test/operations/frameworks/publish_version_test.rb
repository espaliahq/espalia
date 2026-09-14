# frozen_string_literal: true

require "test_helper"

# The PublishVersion Operation *requests* a publish: it checks the gate up
# front, records a FrameworkPublication and enqueues the job. The publish
# itself is covered by Frameworks::PublishVersionJobTest.
class Operations::Frameworks::PublishVersionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      Frameworks::CommandHandler.new.create_framework(@framework_id, "Eng Framework")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  def request_publish(ctx = @admin_ctx)
    Operations::Frameworks::PublishVersion.call(context: ctx, params: { framework_id: @framework_id })
  end

  context "as a tenant admin" do
    should "record the request and enqueue the job without publishing yet" do
      ActsAsTenant.with_tenant(@tenant) do
        result = nil
        assert_enqueued_with(job: Frameworks::PublishVersionJob) { result = request_publish }

        assert_equal "queued", result[:status]
        assert_equal 1, result[:draft_version]
        publication = FrameworkPublication.find(result[:publication_id])
        assert publication.queued?
        assert_equal @admin_tu, publication.requested_by
        assert framework.draft_in_progress, "publishing happens in the job"
      end
    end

    should "refuse while a request is already in flight" do
      ActsAsTenant.with_tenant(@tenant) do
        request_publish
        error = assert_raises(RuntimeError) { request_publish }
        assert_equal "v1 is already being published.", error.message
        assert_equal 1, FrameworkPublication.where(framework_id: @framework_id).count
      end
    end

    should "reap an abandoned request and accept a new one" do
      ActsAsTenant.with_tenant(@tenant) do
        stale = create(:framework_publication, tenant: @tenant, framework_id: @framework_id, draft_version: 1,
          requested_by: @admin_tu, status: :running, created_at: 3.hours.ago)

        result = request_publish

        assert stale.reload.failed?
        assert_not_nil stale.finished_at
        assert_match(/abandoned/, stale.error_message)
        assert FrameworkPublication.find(result[:publication_id]).queued?
      end
    end

    should "raise when there is no draft in progress" do
      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::CommandHandler.new.publish_version(@framework_id, "seed")

        error = assert_raises(RuntimeError) { request_publish }
        assert_match(/no draft/i, error.message)
        assert_no_enqueued_jobs(only: Frameworks::PublishVersionJob)
      end
    end

    should "refuse while an archived capability lacks a migration mapping" do
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        cat_id = SecureRandom.uuid_v7
        cap_id = SecureRandom.uuid_v7
        handler.add_capability_category(@framework_id, cat_id, "Thinking")
        handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Legacy")
        handler.publish_version(@framework_id, "seed")                 # v1; cap pre-draft
        handler.archive_capability(@framework_id, cap_id, reason: "x") # auto-opens v2, no mapping

        error = assert_raises(RuntimeError) { request_publish }
        assert_equal "Add a migration mapping before publishing: Legacy.", error.message
        assert_empty FrameworkPublication.where(framework_id: @framework_id)
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) { request_publish(@member_ctx) }
      end
    end
  end
end
