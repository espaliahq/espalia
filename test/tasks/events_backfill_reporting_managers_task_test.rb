# frozen_string_literal: true

require "test_helper"
require "rake"

class EventsBackfillReportingManagersTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["events:backfill_reporting_managers"].reenable
    @tenant = create(:tenant)
    @framework_id = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      manager = create(:person, tenant: @tenant)
      @kept = create(:person, tenant: @tenant, manager: manager)
      @forgotten = create(:person, tenant: @tenant, manager: manager)
      handler = PersonDevelopment::CommandHandler.new
      [ @kept, @forgotten ].each do |person|
        handler.assign_to_framework(person.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
      end
      @forgotten.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current)
    end
  end

  should "record the manager of everyone still here and skip a forgotten person" do
    capture_io { Rake::Task["events:backfill_reporting_managers"].invoke(@tenant.id) }

    assert_kind_of PersonDevelopment::Events::ReportingManagerRecorded, last_event(@kept)
    assert_kind_of PersonDevelopment::Events::PersonAssignedToFramework, last_event(@forgotten)
  end

  context "a person forgotten after the query ran" do
    setup do
      @later = assign(create_person(@tenant))
      @other_tenant = create(:tenant)
      @elsewhere = ActsAsTenant.with_tenant(@other_tenant) { assign(create_person(@other_tenant)) }
    end

    should "be skipped and counted, while every later assignment in every tenant is still written" do
      output, = Person.stub(:forgotten, Person.none) { capture_io { run_backfill } }

      assert_kind_of PersonDevelopment::Events::PersonAssignedToFramework, last_event(@forgotten)
      assert_kind_of PersonDevelopment::Events::ReportingManagerRecorded, last_event(@later)
      assert_kind_of PersonDevelopment::Events::ReportingManagerRecorded, last_event(@elsewhere, tenant: @other_tenant)
      assert_includes output, "Skipped 1 assignment(s)"
      assert_no_match(/#{@forgotten.id}/, output)
    end

    should "still stop the task on any other error" do
      failing = PersonDevelopment::CommandHandler.new
      failing.define_singleton_method(:record_reporting_manager) { |*, **| raise "store down" }

      error = PersonDevelopment::CommandHandler.stub(:new, failing) do
        assert_raises(RuntimeError) { capture_io { run_backfill } }
      end

      assert_equal "store down", error.message
    end
  end

  private

  def run_backfill(*args) = Rake::Task["events:backfill_reporting_managers"].invoke(*args)

  def create_person(tenant)
    ActsAsTenant.with_tenant(tenant) { create(:person, tenant: tenant, manager: create(:person, tenant: tenant)) }
  end

  def assign(person)
    ActsAsTenant.with_tenant(person.tenant) do
      PersonDevelopment::CommandHandler.new.assign_to_framework(person.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
    end
    person
  end

  def last_event(person, tenant: @tenant)
    stream = EventStreamNaming.person_development_stream(person.id, @framework_id, tenant: tenant)
    Rails.configuration.event_store.read.stream(stream).last
  end
end
