# frozen_string_literal: true

require "test_helper"

class PersonDevelopment::ForgottenSubjectWritesTest < ActiveSupport::TestCase
  EXCEPTIONS = {
    migrate_framework_version: :framework_migration,
    leave_cycle: :cycle_ending,
    conclude_cycle: :cycle_ending,
    offboard_from_framework: :offboarding
  }.freeze

  # Records how each command opens the stream, without opening it.
  class DoorSpy
    attr_reader :opened_with

    def with_person_development(_person_id, _framework_id, forgotten: nil)
      (@opened_with ||= []) << forgotten
    end

    def load(*) = nil
  end

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = PersonDevelopment::CommandHandler.new
    @framework_id = SecureRandom.uuid_v7
    @role_id = SecureRandom.uuid_v7
    @level_id = SecureRandom.uuid_v7
    @subject = create(:person, tenant: @tenant)
    @handler.assign_to_framework(@subject.id, @framework_id, @role_id, @level_id)
    @stream = EventStreamNaming.person_development_stream(@subject.id, @framework_id)
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  should "open the stream refusing a forgotten subject in every command but the named exceptions" do
    writes = PersonDevelopment::CommandHandler.public_instance_methods(false) - [ :load ]

    opened = writes.index_with do |command|
      spy = DoorSpy.new
      positional, keywords = placeholder_args(command)
      PersonDevelopment::CommandHandler.new(repository: spy).public_send(command, *positional, **keywords)
      spy.opened_with
    end

    writes.each do |command|
      assert_equal [ EXCEPTIONS[command] ], opened[command], "#{command} opens the stream with the wrong exception"
    end
  end

  should "name exactly three exceptions, used by four commands" do
    assert_equal %i[framework_migration cycle_ending offboarding], PersonDevelopment::Repository::FORGOTTEN_ALLOWED
    assert_equal 4, EXCEPTIONS.size
  end

  should "offboard a forgotten person from the framework, though an unassign is refused" do
    forget!(@subject)

    assert_raises(PersonDevelopment::ForgottenSubject::Forgotten) do
      @handler.unassign_from_framework(@subject.id, @framework_id, reason: "manual")
    end
    @handler.offboard_from_framework(@subject.id, @framework_id)

    event = Rails.configuration.event_store.read.stream(@stream).last
    assert_kind_of PersonDevelopment::Events::PersonUnassignedFromFramework, event
    assert_equal "left_company", event.data[:reason]
    assert_nil event.data[:unassigned_by]
  end

  should "refuse to leave a cycle with a reason off the fixed list" do
    assert_raises(ArgumentError) do
      @handler.leave_cycle(@subject.id, @framework_id, SecureRandom.uuid_v7, "she asked to leave")
    end
  end

  should "refuse a write to a forgotten subject's stream and store nothing" do
    forget!(@subject)
    before = event_count

    error = assert_raises(PersonDevelopment::ForgottenSubject::Forgotten) do
      @handler.change_person_level(@subject.id, @framework_id, SecureRandom.uuid_v7)
    end

    assert_equal "this person has been forgotten", error.message
    assert_equal before, event_count
  end

  should "let each named exception write to a forgotten subject's stream" do
    forget!(@subject)
    repository = PersonDevelopment::Repository.new

    PersonDevelopment::Repository::FORGOTTEN_ALLOWED.each do |reason|
      yielded = false
      repository.with_person_development(@subject.id, @framework_id, forgotten: reason) { yielded = true }
      assert yielded, "#{reason} was refused"
    end
  end

  should "reject an exception the repository doesn't name" do
    assert_raises(ArgumentError) do
      PersonDevelopment::Repository.new.with_person_development(@subject.id, @framework_id, forgotten: :erase) { }
    end
  end

  should "close a cycle cleanly around a forgotten member, and unenroll one" do
    cycles = AssessmentCycles::CommandHandler.new
    leaver = create(:person, tenant: @tenant)
    @handler.assign_to_framework(leaver.id, @framework_id, @role_id, @level_id)
    cycle_id = SecureRandom.uuid_v7
    cycles.define_cycle(cycle_id, @framework_id, "Q1", "regular", 1)
    cycles.enroll(cycle_id, @subject.id)
    cycles.enroll(cycle_id, leaver.id)
    forget!(@subject)
    forget!(leaver)

    cycles.unenroll(cycle_id, leaver.id, "left_company")
    cycles.close_cycle(cycle_id)

    leaver_stream = EventStreamNaming.person_development_stream(leaver.id, @framework_id)
    assert_kind_of PersonDevelopment::Events::LeftAssessmentCycle, Rails.configuration.event_store.read.stream(leaver_stream).last
    assert_kind_of PersonDevelopment::Events::AssessmentCycleConcluded, Rails.configuration.event_store.read.stream(@stream).last
  end

  should "refuse to enroll a forgotten person in a cycle" do
    cycles = AssessmentCycles::CommandHandler.new
    cycle_id = SecureRandom.uuid_v7
    cycles.define_cycle(cycle_id, @framework_id, "Q1", "regular", 1)
    forget!(@subject)

    assert_raises(PersonDevelopment::ForgottenSubject::Forgotten) { cycles.enroll(cycle_id, @subject.id) }
  end

  private

  def placeholder_args(command)
    params = PersonDevelopment::CommandHandler.instance_method(command).parameters
    value = ->(name) { name == :reason ? "manual" : "placeholder" }
    positional = params.filter_map { |type, name| value.(name) if type == :req }
    keywords = params.each_with_object({}) { |(type, name), acc| acc[name] = value.(name) if type == :keyreq }
    [ positional, keywords ]
  end

  def event_count
    Rails.configuration.event_store.read.stream(@stream).count
  end

  def forget!(person)
    person.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current)
  end
end
