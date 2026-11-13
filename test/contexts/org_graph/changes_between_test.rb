# frozen_string_literal: true

require "test_helper"

class OrgGraph::ChangesBetweenTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  START = Time.zone.parse("2026-02-01 09:00")

  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::CommandHandler.new(actor: SYSTEM)
    @structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    @departments, @squads = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    @engineering, @payments, @platform, @billing = Array.new(4) { SecureRandom.uuid_v7 }

    travel_to START
    as_tenant do
      @ada, @grace, @linus = create_list(:person, 3, tenant: @tenant)
      @structure.define_taxonomy([ { level_id: @departments, name: "Department" }, { level_id: @squads, name: "Squad" } ],
        effective_on: "2026-01-01")
      @structure.create_unit(@engineering, "Engineering", level_id: @departments, effective_on: "2026-01-01")
      @structure.create_unit(@payments, "Payments", level_id: @squads, parent_id: @engineering, effective_on: "2026-01-01")
      @structure.create_unit(@platform, "Platform", level_id: @squads, parent_id: @engineering, effective_on: "2026-01-01")
      [ @ada, @grace ].each do |person|
        @handler.record_person(person.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", title: "Engineer")
        @handler.set_membership(person.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
      end

      user = create(:user)
      @context = AuthorizationContext.new(user:, tenant_user: create(:tenant_user, user:, tenant: @tenant), person: nil)
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def changes(from, to, **options)
    as_tenant { OrgGraph::ChangesBetween.new(context: @context, from: Date.iso8601(from), to: Date.iso8601(to), **options).call }
  end

  def as_of(date) = as_tenant { OrgGraph::AsOf.new(context: @context, date: Date.iso8601(date)).call }

  def kinds(result) = result.changes.map(&:kind)

  def one(result, kind) = result.changes.select { it.kind == kind }.sole

  # A month of changes across every kind, all dated in March.
  def reorganise
    as_tenant do
      @handler.record_person(@linus.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "pending", title: "Designer")
      @handler.join(@linus.id, **ESPALIA, effective_on: "2026-03-02")
      @handler.set_membership(@linus.id, @platform, **ESPALIA, effective_on: "2026-03-02", allocation: 0.5)
      @handler.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-03")
      @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-03-04")
      @handler.leave(@grace.id, **ESPALIA, effective_on: "2026-03-05")
      @structure.create_unit(@billing, "Billing", level_id: @squads, parent_id: @engineering, effective_on: "2026-03-06")
      @structure.rename_unit(@platform, "Core Platform", effective_on: "2026-03-07")
      @structure.add_unit_owner(@platform, @ada.id, effective_on: "2026-03-08")
      @structure.apply_succession(SecureRandom.uuid_v7, predecessor_ids: [ @payments ], successor_ids: [ @billing ],
                                  effective_on: "2026-03-09")
    end
  end

  should "list each kind of change that took effect in the window, in date order" do
    reorganise
    result = changes("2026-03-01", "2026-03-31")

    assert_equal %i[joined membership_started fact_changed moved left membership_ended unit_created
                    unit_renamed owner_added unit_succeeded unit_retired],
                 kinds(result)
    assert_equal [ :effective, nil ], [ result.by, result.known_on ]

    assert_equal [ @linus.id, Date.new(2026, 3, 2) ], one(result, :joined).to_h.values_at(:person_id, :effective_on)
    assert_equal({ "employment_status" => "employed", "title" => "Designer" }, one(result, :joined).after)
    left = one(result, :left)
    assert_equal [ @grace.id, Date.new(2026, 3, 6) ], left.to_h.values_at(:person_id, :effective_on)

    title = result.changes.find { it.kind == :fact_changed && it.person_id == @ada.id }
    assert_equal [ "title", { "title" => "Engineer" }, { "title" => "Senior Engineer" }, "espalia" ],
                 title.to_h.values_at(:fact, :before, :after, :provider)

    moved = one(result, :moved)
    assert_equal [ @ada.id, @payments, @platform ], moved.to_h.values_at(:person_id, :from_unit_id, :unit_id)
    assert_equal [ @grace.id, @payments ], one(result, :membership_ended).to_h.values_at(:person_id, :unit_id)
    assert_equal({ "allocation" => 0.5, "role" => nil }, one(result, :membership_started).after)

    assert_equal({ "name" => "Billing", "parent_id" => @engineering, "level_id" => @squads }, one(result, :unit_created).after)
    assert_equal [ { "name" => "Platform" }, { "name" => "Core Platform" } ], one(result, :unit_renamed).to_h.values_at(:before, :after)
    assert_equal [ @platform, @ada.id ], one(result, :owner_added).to_h.values_at(:unit_id, :person_id)
    assert_equal [ @billing ], one(result, :unit_retired).after.fetch("successor_ids")
    assert_equal({ "predecessor_ids" => [ @payments ], "successor_ids" => [ @billing ] }, one(result, :unit_succeeded).after)
  end

  should "tell a membership's new terms, a unit's new parent and an owner's removal apart" do
    as_tenant do
      @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-02", allocation: 0.5, role: "Lead")
      @structure.move_unit(@platform, nil, effective_on: "2026-03-03")
      @structure.add_unit_owner(@payments, @grace.id, effective_on: "2026-02-01")
      @structure.remove_unit_owner(@payments, @grace.id, effective_on: "2026-03-03")
    end
    result = changes("2026-03-01", "2026-03-31")

    assert_equal %i[membership_changed unit_moved owner_removed], kinds(result)
    assert_equal [ { "allocation" => 1.0, "role" => nil }, { "allocation" => 0.5, "role" => "Lead" } ],
                 one(result, :membership_changed).to_h.values_at(:before, :after)
    assert_equal [ { "parent_id" => @engineering }, { "parent_id" => nil } ], one(result, :unit_moved).to_h.values_at(:before, :after)
    assert_equal [ @payments, @grace.id, Date.new(2026, 3, 4) ], one(result, :owner_removed).to_h.values_at(:unit_id, :person_id, :effective_on)
  end

  should "leave out what took effect on the window's first day or after its last" do
    reorganise

    assert_equal %i[fact_changed moved], kinds(changes("2026-03-02", "2026-03-04"))
  end

  should "account for every difference between the two days' snapshots" do
    reorganise
    as_tenant do
      @structure.move_unit(@billing, nil, effective_on: "2026-03-10")
      @structure.remove_unit_owner(@platform, @ada.id, effective_on: "2026-03-11")
      @handler.set_membership(@linus.id, @platform, **ESPALIA, effective_on: "2026-03-12", allocation: 1.0)
    end

    from, to = as_of("2026-02-28"), as_of("2026-03-31")
    applied = apply(snapshot_shape(from), changes("2026-02-28", "2026-03-31").changes)
    assert_equal snapshot_shape(to), applied
  end

  should "read what was known on an earlier day, leaving out a correction learned since" do
    reorganise
    travel 10.days
    as_tenant { @handler.change_title(@ada.id, "Staff Engineer", **ESPALIA, effective_on: "2026-03-03") }

    now = changes("2026-03-01", "2026-03-31").changes.find { it.kind == :fact_changed && it.person_id == @ada.id }
    assert_equal({ "title" => "Staff Engineer" }, now.after)

    known = changes("2026-03-01", "2026-03-31", known_on: Date.new(2026, 2, 5))
    assert_equal({ "title" => "Senior Engineer" }, known.changes.find { it.kind == :fact_changed && it.person_id == @ada.id }.after)
    assert_equal Date.new(2026, 2, 5), known.known_on
  end

  should "tell when a change was learned, though a later change rewrites its row" do
    as_tenant { @handler.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-03") }
    travel 10.days
    as_tenant { @handler.change_title(@ada.id, "Staff Engineer", **ESPALIA, effective_on: "2026-03-20") }

    senior = changes("2026-03-01", "2026-03-31").changes.find { it.after == { "title" => "Senior Engineer" } }
    assert_equal START, senior.learned_at
  end

  should "include the changes already recorded for a later day" do
    as_tenant do
      @handler.record_person(@linus.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "pending")
      @handler.join(@linus.id, **ESPALIA, effective_on: "2026-09-01")
      @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-09-01")
    end

    assert_equal %i[joined moved], kinds(changes("2026-08-31", "2026-09-30"))
    assert_empty changes("2026-02-02", "2026-08-31").changes
  end

  should "show nothing for a change withdrawn on its own day" do
    as_tenant do
      @structure.rename_unit(@platform, "Core", effective_on: "2026-03-07")
      OrgGraph::ChangeBackHandler.new(actor: SYSTEM).change_back(OrgUnitActivity.for_unit(@platform).first)
    end

    assert_empty changes("2026-03-01", "2026-03-31").changes
  end

  context "by learned date" do
    should "list what was learned in the window, with the day each took effect" do
      travel_to Time.zone.parse("2026-04-10 09:00")
      as_tenant { @handler.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-02-15") }

      result = changes("2026-04-09", "2026-04-10", by: :learned)
      title = result.changes.sole
      assert_equal [ :fact_changed, Date.new(2026, 2, 15), { "title" => "Senior Engineer" }, false ],
                   title.to_h.values_at(:kind, :effective_on, :after, :withdrawn)
      assert_equal Time.zone.parse("2026-04-10 09:00"), title.learned_at
      assert_equal :learned, result.by
    end

    should "leave out a change learned before the window, though it takes effect inside it" do
      as_tenant { @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-04-10") }
      travel_to Time.zone.parse("2026-04-10 09:00")

      assert_empty changes("2026-04-01", "2026-04-30", by: :learned).changes
      assert_includes kinds(changes("2026-01-31", "2026-02-01", by: :learned)), :moved
    end

    should "show a change withdrawn on its own day as withdrawn" do
      as_tenant { @structure.rename_unit(@platform, "Core", effective_on: "2026-03-07") }
      travel_to Time.zone.parse("2026-04-10 09:00")
      as_tenant { OrgGraph::ChangeBackHandler.new(actor: SYSTEM).change_back(OrgUnitActivity.for_unit(@platform).first) }

      renamed = changes("2026-04-09", "2026-04-10", by: :learned).changes.sole
      assert_equal [ :unit_renamed, Date.new(2026, 3, 7), { "name" => "Core" }, true ],
                   renamed.to_h.values_at(:kind, :effective_on, :after, :withdrawn)
      assert_equal Time.zone.parse("2026-04-10 09:00"), renamed.learned_at
    end

    should "leave a later change alone when a correction rewrites the value before it" do
      as_tenant { @handler.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-01") }
      travel_to Time.zone.parse("2026-04-10 09:00")
      as_tenant { @handler.change_title(@ada.id, "Lead Engineer", **ESPALIA, effective_on: "2026-02-01") }

      result = changes("2026-04-09", "2026-04-10", by: :learned)
      assert_equal [ [ Date.new(2026, 2, 1), { "title" => "Lead Engineer" }, false ],
                     [ Date.new(2026, 2, 1), { "title" => "Engineer" }, true ] ],
                   result.changes.map { it.to_h.values_at(:effective_on, :after, :withdrawn) }
    end

    should "withdraw a later change that a correction makes no change at all, as of the correction" do
      as_tenant do
        @handler.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-01")
        @handler.change_title(@ada.id, "Staff Engineer", **ESPALIA, effective_on: "2026-05-01")
      end
      travel_to Time.zone.parse("2026-04-10 09:00")
      as_tenant { @handler.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-02-01") }

      march = changes("2026-04-09", "2026-04-10", by: :learned).changes.find { it.effective_on == Date.new(2026, 3, 1) }
      assert_equal [ { "title" => "Senior Engineer" }, true, Time.zone.parse("2026-04-10 09:00") ],
                   march.to_h.values_at(:after, :withdrawn, :learned_at)
    end

    should "refuse known_on" do
      assert_raises(ArgumentError) { changes("2026-04-01", "2026-04-30", by: :learned, known_on: Date.new(2026, 4, 1)) }
    end
  end

  should "name people by id only" do
    reorganise

    assert_not_includes changes("2026-03-01", "2026-03-31").to_h.to_s, @ada.name
  end

  should "refuse a window that ends before it starts, or an unknown reading" do
    assert_raises(ArgumentError) { changes("2026-03-31", "2026-03-01") }
    assert_raises(ArgumentError) { changes("2026-03-01", "2026-03-31", by: :whenever) }
  end

  should "refuse someone outside the tenant" do
    @context = AuthorizationContext.new(user: create(:user), tenant_user: nil, person: nil)

    assert_raises(Pundit::NotAuthorizedError) { changes("2026-03-01", "2026-03-31") }
  end

  private

  def snapshot_shape(snapshot)
    {
      people: snapshot.people.map(&:id).to_set,
      titles: snapshot.people.to_h { [ it.id, it.title ] },
      placements: snapshot.memberships.to_h { [ [ it.person_id, it.unit_id ], it.allocation ] },
      units: snapshot.units.to_h { [ it.id, [ it.name, it.parent_id ] ] },
      owners: snapshot.units.flat_map { |unit| unit.owner_ids.map { [ unit.id, it ] } }.sort
    }
  end

  # Steps the earlier snapshot through the changes, keeping memberships and
  # owners only where both ends survive, as as_of does.
  def apply(shape, changes)
    people, titles, placements, units = shape[:people].dup, shape[:titles].dup, shape[:placements].dup, shape[:units].dup
    owners = shape[:owners].to_set
    changes.each do |change|
      case change.kind
      when :joined
        people << change.person_id
        titles[change.person_id] = change.after["title"]
      when :left then people.delete(change.person_id)
      when :fact_changed then titles[change.person_id] = change.after&.fetch("title") if change.fact == "title" && titles.key?(change.person_id)
      when :membership_started, :membership_changed then placements[[ change.person_id, change.unit_id ]] = change.after["allocation"]
      when :membership_ended then placements.delete([ change.person_id, change.unit_id ])
      when :moved
        placements.delete([ change.person_id, change.from_unit_id ])
        placements[[ change.person_id, change.unit_id ]] = change.after["allocation"]
      when :unit_created then units[change.unit_id] = change.after.values_at("name", "parent_id")
      when :unit_renamed then units[change.unit_id] = [ change.after["name"], units[change.unit_id][1] ]
      when :unit_moved then units[change.unit_id] = [ units[change.unit_id][0], change.after["parent_id"] ]
      when :unit_retired then units.delete(change.unit_id)
      when :owner_added then owners << [ change.unit_id, change.person_id ]
      when :owner_removed then owners.delete([ change.unit_id, change.person_id ])
      end
    end
    {
      people:,
      titles: titles.slice(*people),
      placements: placements.select { |(person, unit), _| people.include?(person) && units.key?(unit) },
      units:,
      owners: owners.select { |unit, person| units.key?(unit) && people.include?(person) }.sort
    }
  end
end
