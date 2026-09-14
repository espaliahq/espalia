# frozen_string_literal: true

require "test_helper"

class Frameworks::PublishVersionJobTest < ActiveJob::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant)
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @person, role: :admin)

      @framework_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.publish_version(@framework_id, "seed")   # v1
      handler.start_draft(@framework_id, 2, "seed")    # draft v2
    end
  end

  def framework
    ActsAsTenant.with_tenant(@tenant) { FrameworkState::Framework.find_by!(framework_id: @framework_id) }
  end

  def request_publication(**attrs)
    ActsAsTenant.with_tenant(@tenant) do
      create(:framework_publication, tenant: @tenant, framework_id: @framework_id,
        draft_version: 2, requested_by: @tenant_user, **attrs)
    end
  end

  def latest_notification
    Noticed::Notification.where(recipient: @user).order(:created_at).last
  end

  context "a queued request" do
    should "publish the draft, record the outcome and notify the requester" do
      publication = request_publication

      Frameworks::PublishVersionJob.perform_now(publication)

      publication.reload
      assert publication.succeeded?
      assert_equal 2, publication.published_version
      assert_not_nil publication.finished_at
      assert_equal 2, framework.current_published_version
      assert_not framework.draft_in_progress
      assert_equal "Eng v2 is live", latest_notification.inbox_title
      assert_not FrameworkPublication.in_flight_for?(@framework_id)
    end

    should "record a domain refusal as failed and tell the requester why" do
      ActsAsTenant.with_tenant(@tenant) do
        # Retire a pre-draft capability without a mapping: the publish gate (ADR-17) refuses.
        handler = Frameworks::CommandHandler.new
        handler.publish_version(@framework_id, "seed") # close the empty draft (v2)
        cat_id = SecureRandom.uuid_v7
        cap_id = SecureRandom.uuid_v7
        handler.start_draft(@framework_id, 3, "seed")
        handler.add_capability_category(@framework_id, cat_id, "Thinking")
        handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Legacy")
        handler.publish_version(@framework_id, "seed") # v3 with the capability
        handler.archive_capability(@framework_id, cap_id, reason: "x") # auto-opens v4, unmapped
      end
      publication = request_publication(draft_version: 4)

      Frameworks::PublishVersionJob.perform_now(publication)

      publication.reload
      assert publication.failed?
      assert_not_nil publication.finished_at
      assert_match(/mapping/i, publication.error_message)
      assert framework.draft_in_progress, "nothing was published"
      assert_equal "Publishing Eng v4 failed", latest_notification.inbox_title
      assert_match(/mapping/i, latest_notification.inbox_body)
    end

    should "refuse, in plain words, a requester who has lost publish rights" do
      ActsAsTenant.with_tenant(@tenant) { @tenant_user.update!(role: :member) }
      publication = request_publication

      Frameworks::PublishVersionJob.perform_now(publication)

      publication.reload
      assert publication.failed?
      assert_equal "You no longer have permission to publish this framework.", publication.error_message
      assert framework.draft_in_progress
      assert_match(/no longer have permission/, latest_notification.inbox_body)
    end

    should "close the request, notify and re-raise on an unexpected error" do
      publication = request_publication
      Frameworks::CommandHandler.stub(:new, ->(*) { raise ActiveRecord::StatementInvalid, "PG::QueryCanceled" }) do
        assert_raises(ActiveRecord::StatementInvalid) { Frameworks::PublishVersionJob.perform_now(publication) }
      end

      publication.reload
      assert publication.failed?
      assert_not_nil publication.finished_at, "the lock must be released"
      assert_match(/has been logged/, publication.error_message)
      assert_not FrameworkPublication.in_flight_for?(@framework_id)
      assert_equal "Publishing Eng v2 failed", latest_notification.inbox_title
    end
  end

  context "a request that is no longer queued" do
    should "do nothing" do
      publication = request_publication(status: :running)

      Frameworks::PublishVersionJob.perform_now(publication)

      assert publication.reload.running?
      assert framework.draft_in_progress
      assert_nil latest_notification
    end
  end
end
