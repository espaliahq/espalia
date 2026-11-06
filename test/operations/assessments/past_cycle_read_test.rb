# frozen_string_literal: true

require "test_helper"

# `cycle_id` on the assessment read tools reads a past cycle as the web's
# read-only page does: that cycle's ratings and score at its own role and
# level, disclosed to the assessee only where alignment had started
# (https://github.com/mr-yum/growth-os/issues/669).
class Operations::Assessments::PastCycleReadTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @fx = build_role_lens_framework(tenant: @tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @manager_user = create(:user)
      @manager = create(:person, tenant: @tenant, email: @manager_user.email)
      @manager_tu = create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @user = create(:user)
      @person = create(:person, tenant: @tenant, email: @user.email, manager: @manager)
      @tu = create(:tenant_user, tenant: @tenant, user: @user, person: @person)
    end
    @assignment, @past_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    pd = PersonDevelopment::CommandHandler.new
    ActsAsTenant.with_tenant(@tenant) do
      [ @fx.shared, @fx.e_only ].each do |capability|
        [ 1, 2 ].each do |ordinal|
          pd.rate_self(@person.id, @fx.framework_id, capability.stable_id, level_ordinal: ordinal,
            frequency: "consistent", cycle_id: @past_id)
          pd.rate_as_manager(@person.id, @fx.framework_id, capability.stable_id, level_ordinal: ordinal,
            frequency: "some", cycle_id: @past_id, rated_by_id: @manager.id)
        end
      end
    end
  end

  def close_past_cycle
    @open_id = close_and_open_next_role_lens_cycle(@person, @fx, @past_id, tenant: @tenant)
  end

  def as_manager = AuthorizationContext.new(user: @manager_user, tenant_user: @manager_tu, person: @manager)
  def as_assessee = AuthorizationContext.new(user: @user, tenant_user: @tu, person: @person)

  def get(context: as_manager, **params)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::Get.call(context: context, params: { assignment_id: @assignment.id, **params })
    end
  end

  def capability_get(context: as_manager, **params)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::CapabilityGet.call(
        context: context, params: { assignment_id: @assignment.id, capability_id: @fx.shared.stable_id, **params }
      )
    end
  end

  context Operations::Assessments::Get do
    should "describe the open cycle's alignments in current_cycle, not the past one's" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.start_alignment(@person.id, @fx.framework_id, @past_id,
          started_by_id: @manager.id, role_id: @fx.pm.role_id, level_ordinal: 2)
      end
      close_past_cycle

      assert_empty get(cycle_id: @past_id)[:current_cycle][:alignments]
    end

    should "refuse a past cycle whose level is gone rather than read the open one" do
      close_past_cycle
      ActsAsTenant.with_tenant(@tenant) do
        AssessmentCycleEnrollment.find_by!(cycle_id: @past_id, person_id: @person.id).update!(level_id: SecureRandom.uuid_v7)
      end

      assert_raises(Operations::Base::ParameterError) { capability_get(cycle_id: @past_id) }
    end

    should "score the past cycle at its own level, as its page builds it" do
      close_past_cycle
      scoring = get(cycle_id: @past_id)[:scoring]

      assert_equal({ role_id: @fx.engineer.role_id, role_code: "E", level_ordinal: 2, home: true,
                     cycle_id: @past_id, past_cycle: true }, scoring[:lens])
      assert_equal "E2", scoring[:scale][:assessed_level]
      expected = ActsAsTenant.with_tenant(@tenant) do
        lens = Assessments::Lens.resolve(assignment: @assignment, cycle_id: @past_id)
        Assessments::ScoreSummary.new(assignment: @assignment, context: :manager, lens: lens).overall
      end
      assert_equal expected[:score], scoring[:score]
      assert scoring[:scored]
    end

    should "keep scoring the open cycle without a cycle_id" do
      close_past_cycle
      scoring = get[:scoring]

      assert_equal @open_id, scoring[:lens][:cycle_id]
      assert_not scoring[:lens][:past_cycle]
      assert_equal "E3", scoring[:scale][:assessed_level]
    end

    should "refuse a cycle the person never joined" do
      close_past_cycle
      other = ActsAsTenant.with_tenant(@tenant) do
        create(:assessment_cycle, tenant: @tenant, framework_id: @fx.framework_id, status: "closed")
      end
      assert_raises(Operations::Base::ParameterError) { get(cycle_id: other.cycle_id) }
    end
  end

  context Operations::Assessments::CapabilityGet do
    should "return the past cycle's ratings" do
      close_past_cycle
      payload = capability_get(cycle_id: @past_id)

      assert_equal @past_id, payload[:cycle_id]
      ratings = payload[:expectations].find { |e| e[:level_ordinal] == 2 }[:ratings]
      assert_equal "consistent", ratings[:self]
      assert_equal "some", ratings[:manager]
    end

    should "keep the manager's ratings from the assessee where alignment never started" do
      close_past_cycle
      ratings = capability_get(context: as_assessee, cycle_id: @past_id)[:expectations]
        .find { |e| e[:level_ordinal] == 2 }[:ratings]

      assert_equal "consistent", ratings[:self]
      assert_nil ratings[:manager]
    end
  end
end
