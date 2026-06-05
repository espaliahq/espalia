# frozen_string_literal: true

require "test_helper"

class PersonDevelopment::Projections::AssessmentAuthorityTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @projection = PersonDevelopment::Projections::AssessmentAuthority.new
    @person_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @manager_id = SecureRandom.uuid_v7
    @delegate_id = SecureRandom.uuid_v7
  end

  context "ReportingManagerRecorded" do
    should "upsert a RecordedReportingManager row" do
      emit(PersonDevelopment::Events::ReportingManagerRecorded,
        manager_id: @manager_id, previous_manager_id: nil, source: "hris")

      ActsAsTenant.with_tenant(@tenant) do
        row = RecordedReportingManager.find_by(person_id: @person_id, framework_id: @framework_id)
        assert_equal @manager_id, row.manager_id
        assert_equal "hris", row.source
      end
    end

    should "overwrite the manager on a later recording" do
      emit(PersonDevelopment::Events::ReportingManagerRecorded, manager_id: @manager_id, source: "hris")
      new_manager = SecureRandom.uuid_v7
      emit(PersonDevelopment::Events::ReportingManagerRecorded,
        manager_id: new_manager, previous_manager_id: @manager_id, source: "hris")

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal new_manager,
          RecordedReportingManager.manager_id_for(@person_id, @framework_id)
        assert_equal 1, RecordedReportingManager.where(person_id: @person_id).count
      end
    end
  end

  context "delegation lifecycle" do
    should "create an active delegation, then mark it revoked" do
      emit(PersonDevelopment::Events::ManagerRatingDelegated,
        delegate_person_id: @delegate_id, granted_by_id: @manager_id,
        expires_at: nil, reason: "seconded")

      ActsAsTenant.with_tenant(@tenant) do
        assert ManagerAssessmentDelegation.active_delegate?(
          person_id: @person_id, framework_id: @framework_id, delegate_person_id: @delegate_id
        )
      end

      revoker = SecureRandom.uuid_v7
      emit(PersonDevelopment::Events::ManagerRatingDelegationRevoked,
        delegate_person_id: @delegate_id, revoked_by_id: revoker)

      ActsAsTenant.with_tenant(@tenant) do
        row = ManagerAssessmentDelegation.find_by(person_id: @person_id,
          framework_id: @framework_id, delegate_person_id: @delegate_id)
        assert_equal "revoked", row.status
        assert_equal revoker, row.revoked_by_id
        assert_not_nil row.revoked_at
        assert_not ManagerAssessmentDelegation.active_delegate?(
          person_id: @person_id, framework_id: @framework_id, delegate_person_id: @delegate_id
        )
      end
    end

    should "reactivate when re-granted after revoke" do
      emit(PersonDevelopment::Events::ManagerRatingDelegated,
        delegate_person_id: @delegate_id, granted_by_id: @manager_id)
      emit(PersonDevelopment::Events::ManagerRatingDelegationRevoked,
        delegate_person_id: @delegate_id, revoked_by_id: @manager_id)
      emit(PersonDevelopment::Events::ManagerRatingDelegated,
        delegate_person_id: @delegate_id, granted_by_id: @manager_id)

      ActsAsTenant.with_tenant(@tenant) do
        row = ManagerAssessmentDelegation.find_by(delegate_person_id: @delegate_id)
        assert_equal "active", row.status
        assert_nil row.revoked_at
      end
    end
  end

  context "reset!" do
    should "truncate both owned tables for the tenant" do
      emit(PersonDevelopment::Events::ReportingManagerRecorded, manager_id: @manager_id, source: "hris")
      emit(PersonDevelopment::Events::ManagerRatingDelegated,
        delegate_person_id: @delegate_id, granted_by_id: @manager_id)

      PersonDevelopment::Projections::AssessmentAuthority.reset!(tenant: @tenant)

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal 0, RecordedReportingManager.where(tenant_id: @tenant.id).count
        assert_equal 0, ManagerAssessmentDelegation.where(tenant_id: @tenant.id).count
      end
    end
  end

  private

  def emit(event_class, **data)
    event = event_class.new(
      data: data,
      metadata: { tenant_id: @tenant.id, person_id: @person_id, framework_id: @framework_id }
    )
    @projection.call(event)
  end
end
