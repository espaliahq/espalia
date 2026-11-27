# frozen_string_literal: true

require "test_helper"

# "This person has been forgotten" tells the caller a fact about a person, so
# a caller with no right on the subject's assessment gets the ordinary
# refusal instead. Each write runs the real operation, policy and repository.
class ForgottenSubjectAuthorisationTest < ActiveSupport::TestCase
  ASSIGNMENT_WRITES = [
    Operations::Assessments::Align,
    Operations::Assessments::CloseExploration,
    Operations::Assessments::CompleteAlignment,
    Operations::Assessments::ConfirmCarriedRatings,
    Operations::Assessments::DelegateManagerRating,
    Operations::Assessments::PostComment,
    Operations::Assessments::RateAsManager,
    Operations::Assessments::RateSelf,
    Operations::Assessments::ReopenAlignment,
    Operations::Assessments::RequestEvidence,
    Operations::Assessments::RevokeManagerRatingDelegation,
    Operations::Assessments::StartAlignment,
    Operations::Assessments::StartExploration,
    Operations::Assessments::Unassign
  ].freeze

  EXTRA_PARAMS = { Operations::Assessments::StartExploration => { as_level_ordinal: 1 } }.freeze

  EVIDENCE_WRITES = [
    Operations::Assessments::UpdateEvidence,
    Operations::Assessments::WithdrawEvidence,
    Operations::Assessments::AddEvidenceLink,
    Operations::Assessments::RemoveEvidenceLink,
    Operations::Assessments::SetEvidenceLinkValence
  ].freeze

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @subject = create(:person, tenant: @tenant)
      @framework_id = SecureRandom.uuid_v7
      PersonDevelopment::CommandHandler.new.assign_to_framework(@subject.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
      @assignment = PersonFrameworkAssignment.for_person(@subject.id).first
      @evidence_id = SecureRandom.uuid_v7
      PersonDevelopment::CommandHandler.new.record_evidence(@subject.id, @framework_id, @evidence_id,
        source: "self", evidence_type: "observation", content: "Ran the retro.", author_id: @subject.id)
      @subject.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current)

      user = create(:user)
      stranger = create(:person, tenant: @tenant, email: user.email)
      tenant_user = create(:tenant_user, tenant: @tenant, user: user, person: stranger, role: :member)
      @stranger = AuthorizationContext.new(user: user, tenant_user: tenant_user, person: stranger)
    end
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  should "refuse a stranger every assessment write on a forgotten person as unauthorised" do
    ASSIGNMENT_WRITES.each do |operation|
      assert_unauthorised(operation, assignment_id: @assignment.id, **EXTRA_PARAMS.fetch(operation, {}))
    end
  end

  should "tell a member, who may give anyone feedback, that the person has been forgotten" do
    error = ActsAsTenant.with_tenant(@tenant) do
      assert_raises(Operations::Base::ParameterError) do
        Operations::Assessments::RecordEvidence.call(context: @stranger, params: {
          assignment_id: @assignment.id, evidence_type: "peer_feedback", content: "Calm on the call."
        })
      end
    end

    assert_equal "this person has been forgotten", error.message
  end

  should "refuse a stranger every write to a forgotten person's feedback as unauthorised" do
    EVIDENCE_WRITES.each do |operation|
      assert_unauthorised(operation, assignment_id: @assignment.id, evidence_id: @evidence_id)
    end
  end

  should "refuse a stranger a calibration revisit on a forgotten person as unauthorised" do
    session = ActsAsTenant.with_tenant(@tenant) { create(:calibration_session, :started, tenant: @tenant, framework_id: @framework_id) }

    assert_unauthorised(Operations::CalibrationSessions::RequestRatingRevisit, session_id: session.id, person_id: @subject.id)
  end

  private

  def assert_unauthorised(operation, **known)
    params = placeholder_params(operation).merge(known)
    ActsAsTenant.with_tenant(@tenant) do
      assert_raises(Pundit::NotAuthorizedError, "#{operation.name} answered a stranger with something else") do
        operation.call(context: @stranger, params: params)
      end
    end
  end

  def placeholder_params(operation)
    operation.parameters.values.select(&:required).to_h do |parameter|
      value = case parameter.type.to_s
      when ->(_) { parameter.allowed.present? } then Array(parameter.allowed).first
      when "Integer" then 1
      when "Array" then []
      else SecureRandom.uuid_v7
      end
      [ parameter.name, value ]
    end
  end
end
