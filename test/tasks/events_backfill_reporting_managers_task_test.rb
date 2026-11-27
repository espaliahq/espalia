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

  private

  def last_event(person)
    stream = EventStreamNaming.person_development_stream(person.id, @framework_id, tenant: @tenant)
    Rails.configuration.event_store.read.stream(stream).last
  end
end
