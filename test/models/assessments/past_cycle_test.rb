# frozen_string_literal: true

require "test_helper"

# Reading a cycle other than the open one: its own ratings, at its own
# enrollment snapshot, read-only, and disclosed to the assessee exactly as
# they were when it closed (https://github.com/mr-yum/growth-os/issues/669).
class Assessments::PastCycleTest < ActiveSupport::TestCase
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
    @pd = PersonDevelopment::CommandHandler.new
    with_tenant do
      rate(@fx.shared, own: "consistent", manager: "some")
      rate(@fx.e_only, own: "some", manager: "occasional")
    end
  end

  def with_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def rate(capability, own:, manager:, cycle_id: @past_id)
    @pd.rate_self(@person.id, @fx.framework_id, capability.stable_id, level_ordinal: 2, frequency: own, cycle_id: cycle_id)
    @pd.rate_as_manager(@person.id, @fx.framework_id, capability.stable_id, level_ordinal: 2, frequency: manager,
      cycle_id: cycle_id, rated_by_id: @manager.id)
  end

  def open_next_cycle
    @open_id = close_and_open_next_role_lens_cycle(@person, @fx, @past_id, tenant: @tenant)
  end

  def as_assessee = AuthorizationContext.new(user: @user, tenant_user: @tu, person: @person)
  def as_manager = AuthorizationContext.new(user: @manager_user, tenant_user: @manager_tu, person: @manager)

  def past_lens = Assessments::Lens.resolve(assignment: @assignment, cycle_id: @past_id)

  def cell(matrix, capability) = cell_at(matrix, capability, 2)

  def cell_at(matrix, capability, ordinal)
    matrix[:categories].flat_map { |c| c[:capabilities] }
      .find { |cap| cap[:capability].stable_id == capability.stable_id }[:cells][ordinal]
  end

  context "a lens on a past cycle" do
    setup { open_next_cycle }

    should "read that cycle's snapshot as home, while the open cycle reads its own" do
      with_tenant do
        assert past_lens.past?
        assert_equal @past_id, past_lens.cycle.cycle_id
        assert_equal "E2", past_lens.home_code
        assert_equal({ cycle_id: @past_id }, past_lens.to_params)

        open = Assessments::Lens.resolve(assignment: @assignment)
        assert_not open.past?
        assert_equal @open_id, open.cycle.cycle_id
        assert_equal "E3", open.home_code
      end
    end

    should "read the open cycle when named by its own id" do
      with_tenant { assert_not Assessments::Lens.resolve(assignment: @assignment, cycle_id: @open_id).past? }
    end

    should "carry the cycle onto another lens's params" do
      with_tenant do
        assert_equal({ as_role: @fx.pm.role_id, as_level: 2, cycle_id: @past_id },
                     past_lens.params_for(role_id: @fx.pm.role_id, ordinal: 2))
      end
    end

    should "refuse a cycle the person never joined" do
      other = with_tenant { create(:assessment_cycle, tenant: @tenant, framework_id: @fx.framework_id, status: "closed") }
      assert_raises(Assessments::Lens::NotFound) do
        with_tenant { Assessments::Lens.resolve(assignment: @assignment, cycle_id: other.cycle_id) }
      end
    end

    should "build that cycle's ratings, frozen and locked" do
      with_tenant do
        rate(@fx.shared, own: "none", manager: "none", cycle_id: @open_id)
        matrix = Assessments::MatrixDataBuilder.for_lens(lens: past_lens, context: :manager)

        assert matrix[:past_cycle]
        assert matrix[:individual_ratings_frozen]
        assert matrix[:alignment_locked]
        assert_equal "consistent", cell(matrix, @fx.shared)[:current_frequency]
        assert_equal "some", cell(matrix, @fx.shared)[:manager_frequency]
      end
    end
  end

  context "disclosure to the assessee" do
    should "keep the manager's ratings private when alignment never started" do
      open_next_cycle
      with_tenant do
        context = Assessments::ViewerContext.for(assignment: @assignment, authorization: as_assessee, lens: past_lens)
        assert_equal :self, context

        matrix = Assessments::MatrixDataBuilder.for_lens(lens: past_lens, context: context)
        assert_nil cell(matrix, @fx.shared)[:manager_frequency]
        assert_nil matrix[:manager_scoring]
      end
    end

    should "show what alignment disclosed before the cycle closed" do
      with_tenant do
        @pd.start_alignment(@person.id, @fx.framework_id, @past_id, started_by_id: @manager.id)
        @pd.complete_alignment(@person.id, @fx.framework_id, @past_id, completed_by_id: @manager.id)
      end
      open_next_cycle
      with_tenant do
        context = Assessments::ViewerContext.for(assignment: @assignment, authorization: as_assessee, lens: past_lens)
        assert_equal :alignment, context

        matrix = Assessments::MatrixDataBuilder.for_lens(lens: past_lens, context: context)
        assert_equal "some", cell(matrix, @fx.shared)[:manager_frequency]
        assert_equal "aligned", matrix[:participant_status]
      end
    end

    should "read the manager as the manager on a past cycle" do
      open_next_cycle
      with_tenant do
        assert_equal :manager,
          Assessments::ViewerContext.for(assignment: @assignment, authorization: as_manager, lens: past_lens)
      end
    end
  end

  should "ask nothing to be confirmed on a past cycle" do
    with_tenant do
      @pd.rate_self(@person.id, @fx.framework_id, @fx.shared.stable_id, level_ordinal: 3, frequency: "consistent",
        cycle_id: @past_id, source: "seeded", seeded_from_cycle_id: SecureRandom.uuid_v7)
      open = Assessments::MatrixDataBuilder.for_lens(lens: Assessments::Lens.home(@assignment), context: :self)
      assert cell_at(open, @fx.shared, 3)[:current_frequency_carried]
    end
    open_next_cycle
    with_tenant do
      past = Assessments::MatrixDataBuilder.for_lens(lens: past_lens, context: :self)
      assert_not cell_at(past, @fx.shared, 3)[:current_frequency_carried]
    end
  end

  should "read a cycle the person withdrew from while it is still open" do
    with_tenant do
      AssessmentCycles::CommandHandler.new.unenroll(@past_id, @person.id, "left the team")
      lens = past_lens
      assert lens.past?
      assert Assessments::MatrixDataBuilder.for_lens(lens: lens, context: :manager)[:individual_ratings_frozen]
    end
  end
end
