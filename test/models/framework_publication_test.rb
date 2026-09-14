# frozen_string_literal: true

require "test_helper"

# The coordination record between a publish request and the job that runs it:
# one unfinished row per framework, and a stale row never holds that lock.
class FrameworkPublicationTest < ActiveSupport::TestCase
  subject { build(:framework_publication, tenant: @tenant, requested_by: @tenant_user) }

  setup do
    @tenant = create(:tenant)
    @framework_id = SecureRandom.uuid_v7
    @tenant_user = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant) }
  end

  should belong_to(:tenant)
  should belong_to(:requested_by).class_name("TenantUser")
  should validate_presence_of(:framework_id)
  should validate_presence_of(:draft_version)
  should define_enum_for(:status).with_values(%i[queued running succeeded failed])

  def publication(**attrs)
    ActsAsTenant.with_tenant(@tenant) do
      create(:framework_publication, tenant: @tenant, framework_id: @framework_id, requested_by: @tenant_user, **attrs)
    end
  end

  context "the in-flight lock" do
    should "allow only one unfinished publication per framework" do
      publication(status: :queued)

      assert_raises(ActiveRecord::RecordNotUnique) { publication(status: :running) }
    end

    should "release once a publication has finished, whatever its status" do
      publication(status: :failed, finished_at: 1.minute.ago)
      publication(status: :succeeded, finished_at: 1.minute.ago)

      assert_nothing_raised { publication(status: :queued) }
      assert FrameworkPublication.in_flight_for?(@framework_id)
      assert_not FrameworkPublication.in_flight_for?(SecureRandom.uuid_v7)
    end
  end

  context ".reap_stale!" do
    should "close an unfinished row older than the stale window and nothing else" do
      abandoned = publication(status: :running, created_at: 4.hours.ago,
        started_at: (FrameworkPublication::STALE_AFTER + 1.minute).ago)
      other = ActsAsTenant.with_tenant(@tenant) do
        create(:framework_publication, tenant: @tenant, requested_by: @tenant_user, status: :running,
          created_at: 3.hours.ago, started_at: 3.hours.ago)
      end

      assert_equal 1, FrameworkPublication.reap_stale!(@framework_id)

      assert abandoned.reload.failed?
      assert_not_nil abandoned.finished_at
      assert_match(/abandoned/, abandoned.error_message)
      assert other.reload.in_flight?, "another framework's row is untouched"
      assert_not FrameworkPublication.in_flight_for?(@framework_id)
    end

    should "leave a recent unfinished row alone" do
      recent = publication(status: :running, started_at: Time.current)

      assert_equal 0, FrameworkPublication.reap_stale!(@framework_id)
      assert recent.reload.in_flight?
    end

    should "measure a running row from when it was claimed, not when it was requested" do
      long_queued_then_claimed = publication(status: :running,
        created_at: (FrameworkPublication::STALE_AFTER + 1.hour).ago, started_at: 1.minute.ago)

      assert_equal 0, FrameworkPublication.reap_stale!(@framework_id)
      assert long_queued_then_claimed.reload.in_flight?
    end
  end

  context ".latest_for" do
    should "report the newest request for a draft" do
      publication(draft_version: 2, status: :failed, finished_at: 2.hours.ago, created_at: 2.hours.ago)
      newer = publication(draft_version: 2, status: :failed, finished_at: 1.hour.ago, created_at: 1.hour.ago)
      publication(draft_version: 3, status: :queued)

      assert_equal newer, FrameworkPublication.latest_for(@framework_id, 2)
    end
  end
end
