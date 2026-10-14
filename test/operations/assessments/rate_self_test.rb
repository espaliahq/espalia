# frozen_string_literal: true

require "test_helper"

# End-to-end check that the write Operation routes through to the real
# command handler: a SelfRated event lands on the person-development
# stream, the projection updates AssessmentLevelRating, and the toggle
# semantics (clear when re-submitting the same frequency, revise when
# different) match the web controller's behaviour.
#
# Also asserts AuditMetadata stamps `acting_via` onto the published
# event when an MCP context is seeded — proving the wrap_event_store
# path works end-to-end on a real domain event (vs the unit test which
# uses an injected event_store).
class Operations::Assessments::RateSelfTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Tester")
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @person, role: :member)

      framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      @role  = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")

      cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding,
        capability_id: @cap.capability_id, role_id: @role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "Synthesises")

      pd_handler = PersonDevelopment::CommandHandler.new
      cycles_handler = AssessmentCycles::CommandHandler.new
      pd_handler.assign_to_framework(@person.id, framework_id, @role.role_id, @level.level_id)

      @cycle_id = SecureRandom.uuid_v7
      cycles_handler.define_cycle(@cycle_id, framework_id, "Q1", "regular", 1, defined_by: @person.id)
      cycles_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)

      @framework_id = framework_id
      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end

    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def call_op(frequency:, comment: nil, clear: nil)
    ActsAsTenant.with_tenant(@tenant) do
      params = {
        assignment_id: @assignment.id,
        capability_stable_id: @cap.stable_id,
        level_ordinal: 2,
        frequency: frequency,
        comment: comment
      }
      params[:clear] = clear unless clear.nil?
      Operations::Assessments::RateSelf.call(context: @context, params: params)
    end
  end

  def seed_carried_rating(frequency)
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.rate_self(
        @person.id, @framework_id, @cap.stable_id,
        level_ordinal: 2, frequency: frequency, cycle_id: @cycle_id,
        comment: "Seeded from prior cycle", source: "seeded",
        seeded_from_cycle_id: SecureRandom.uuid_v7
      )
    end
  end

  def confirm_op(frequency)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::RateSelf.call(context: @context, params: {
        assignment_id: @assignment.id, capability_stable_id: @cap.stable_id, level_ordinal: 2,
        frequency: frequency, confirm: true
      })
    end
  end

  def reload_rating
    ActsAsTenant.with_tenant(@tenant) do
      AssessmentLevelRating.find_by(
        cycle_id: @cycle_id, person_id: @person.id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2
      )
    end
  end

  context "first rating" do
    should "publish SelfRated and persist the frequency on the projection" do
      result = call_op(frequency: "consistent", comment: "every sprint")

      assert_equal "consistent", reload_rating.self_rated_frequency
      assert_equal "consistent", result[:frequency]
      assert_equal @cycle_id,    result[:cycle_id]
    end
  end

  context "second rating with a different frequency" do
    should "revise the existing rating" do
      call_op(frequency: "some")
      call_op(frequency: "consistent")

      assert_equal "consistent", reload_rating.self_rated_frequency
    end
  end

  context "second rating with the SAME frequency" do
    should "clear the rating (toggle off)" do
      call_op(frequency: "consistent")
      result = call_op(frequency: "consistent")

      assert_nil reload_rating&.self_rated_frequency
      assert_nil result[:frequency]
    end
  end

  context "carried-forward (seeded) rating" do
    should "confirm on same-frequency instead of clearing — web parity" do
      seed_carried_rating("occasional")

      result = call_op(frequency: "occasional")

      rating = reload_rating
      assert_equal "occasional", rating.self_rated_frequency,
        "confirming a carried value must keep it, not clear it"
      assert_equal "human", rating.self_rating_source
      assert_equal "occasional", result[:frequency]
    end

    should "clear explicitly via clear: true" do
      seed_carried_rating("occasional")

      result = call_op(frequency: "occasional", clear: true)

      assert_nil reload_rating&.self_rated_frequency
      assert_nil result[:frequency]
    end

    should "no-op a clear when the rating is already empty" do
      result = call_op(frequency: "occasional", clear: true)

      assert_nil result[:frequency]
    end
  end

  # #480: Keep sends confirm, so a double-click or a stale tab can't untoggle
  # the rating the first click confirmed.
  context "explicit confirm" do
    should "confirm a carried value, then leave it alone when sent again" do
      seed_carried_rating("occasional")

      confirm_op("occasional")
      assert_equal "human", reload_rating.self_rating_source

      confirm_op("occasional")
      assert_equal "occasional", reload_rating.self_rated_frequency, "a repeated confirm must not clear the rating"
    end

    should "change nothing for a value that was never carried" do
      call_op(frequency: "some")

      confirm_op("some")

      assert_equal "some", reload_rating.self_rated_frequency
    end
  end

  context "audit metadata propagation" do
    should "stamp acting_via on the published SelfRated event" do
      event_store = Rails.configuration.event_store
      observed_metadata = nil
      subscriber = ->(event) { observed_metadata = event.metadata.to_h }

      event_store
        .within do
          AuditMetadata.with(acting_via: :mcp, client_application_id: "app-xyz") do
            call_op(frequency: "consistent")
          end
        end
        .subscribe(subscriber, to: [ PersonDevelopment::Events::SelfRated ])
        .call

      assert observed_metadata, "expected SelfRated event to be published"
      # acting_via is stringified at the event-store boundary because
      # ruby_event_store::Metadata rejects Symbol values.
      assert_equal "mcp",     observed_metadata[:acting_via]
      assert_equal "app-xyz", observed_metadata[:client_application_id]
    end
  end

  context "preconditions" do
    should "raise ParameterError when no open cycle exists" do
      ActsAsTenant.with_tenant(@tenant) do
        AssessmentCycles::CommandHandler.new.close_cycle(@cycle_id)
      end

      err = assert_raises(Operations::Base::ParameterError) do
        call_op(frequency: "consistent")
      end
      assert_match(/no open assessment cycle/, err.message)
    end

    should "reject unknown frequency values at the parameter layer" do
      assert_raises(Operations::Base::ParameterError) do
        Operations::Assessments::RateSelf.call(
          context: @context,
          params: {
            assignment_id: @assignment.id,
            capability_stable_id: @cap.stable_id,
            level_ordinal: 2,
            frequency: "always"
          }
        )
      end
    end
  end
end
