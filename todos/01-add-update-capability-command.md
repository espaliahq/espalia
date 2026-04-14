# Add `update_capability` Command - Done

## Context

The Frameworks aggregate has no `update_capability` command. To rename a capability or revise its description, the only path today is `archive_capability` + `add_capability` — which loses the stable_id continuity and requires a draft cycle for what is conceptually an editorial change.

This is both a functional gap and a blocker for [`todos/02-suggestion-tier-2-3-implementation.md`](02-suggestion-tier-2-3-implementation.md): tier-2 suggestions on capabilities (name/description wording) cannot be approved without a content-change command to dispatch.

Capability name/description changes are **shape-preserving** (stable_id unchanged, grid unchanged), so the command should be editorial and apply live — matching the `update_capability_category`, `update_role`, `update_role_family` pattern.

## What needs to change

### New event

Create [`app/contexts/frameworks/events/capability_updated.rb`](../app/contexts/frameworks/events/capability_updated.rb):

```ruby
# frozen_string_literal: true

class Frameworks::Events::CapabilityUpdated < RubyEventStore::Event
end
```

Event data: `{ framework_id, capability_id, name?, description? }`.

### Aggregate command

Add `update_capability` to [`app/contexts/frameworks/aggregate.rb`](../app/contexts/frameworks/aggregate.rb) next to `add_capability` / `archive_capability`:

```ruby
def update_capability(framework_id, capability_id, name: nil, description: nil)
  ensure_created!
  raise "Capability #{capability_id} not found" unless @capabilities.key?(capability_id)

  apply(Frameworks::Events::CapabilityUpdated.new(data: {
    framework_id: framework_id,
    capability_id: capability_id,
    name: name,
    description: description
  }.compact))
end
```

Add an on-handler:

```ruby
on Frameworks::Events::CapabilityUpdated do |event|
  cap = @capabilities[event.data[:capability_id]]
  cap[:name] = event.data[:name] if event.data.key?(:name)
  # (description is not tracked in aggregate state today, same as categories)
end
```

### Command handler delegation

Add to [`app/contexts/frameworks/command_handler.rb`](../app/contexts/frameworks/command_handler.rb):

```ruby
def update_capability(framework_id, capability_id, name: nil, description: nil)
  @repository.with_framework(framework_id) do |framework|
    framework.update_capability(framework_id, capability_id, name: name, description: description)
  end
end
```

### Projection handler

Add to [`app/contexts/frameworks/projections/published_state.rb`](../app/contexts/frameworks/projections/published_state.rb):

1. Add `Frameworks::Events::CapabilityUpdated` to `handled_events`.
2. Route to `handle_capability_updated` in the editorial (live) branch of the `handle` switch.
3. Implement the handler as a dependent-editorial lookup (tolerates missing parent):

```ruby
def handle_capability_updated(event)
  record = FrameworkState::Capability.find_by(capability_id: event.data[:capability_id])
  return unless record

  attrs = event.data.slice(:name, :description).compact
  record.update!(attrs) if attrs.any?
end
```

### Tests

Add a context to [`test/contexts/frameworks/aggregate_test.rb`](../test/contexts/frameworks/aggregate_test.rb):

```ruby
context "#update_capability" do
  setup do
    @cat_id = SecureRandom.uuid_v7
    @cap_id = SecureRandom.uuid_v7
    @aggregate.add_capability_category(@framework_id, @cat_id, "Thinking")
    @aggregate.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Original Name")
  end

  should "apply CapabilityUpdated event" do
    @aggregate.update_capability(@framework_id, @cap_id, name: "Renamed", description: "New desc")
    event = @aggregate.unpublished_events.to_a.last
    assert_kind_of Frameworks::Events::CapabilityUpdated, event
    assert_equal "Renamed", event.data[:name]
    assert_equal "New desc", event.data[:description]
  end

  should "raise if capability not found" do
    assert_raises(RuntimeError, /not found/) do
      @aggregate.update_capability(@framework_id, "nonexistent", name: "X")
    end
  end

  should "succeed outside a draft (editorial)" do
    fresh = Frameworks::Aggregate.new
    fresh.create(@framework_id, "Test")
    cat = SecureRandom.uuid_v7
    cap = SecureRandom.uuid_v7
    fresh.add_capability_category(@framework_id, cat, "C")
    fresh.add_capability(@framework_id, cap, SecureRandom.uuid_v7, cat, "Old")
    fresh.publish_version(@framework_id, "user-1")

    assert_nothing_raised do
      fresh.update_capability(@framework_id, cap, name: "New")
    end
  end
end
```

Add a projection test that verifies the read-model update and the dependent-editorial skip when the capability row doesn't exist yet.

## Verification

```bash
bin/rails test test/contexts/frameworks/aggregate_test.rb
bin/rails test test/contexts/frameworks/projections/published_state_test.rb
bin/rails development:precommit
```

## Out of scope

- Suggestion-path integration — covered by [`todos/02-suggestion-tier-2-3-implementation.md`](02-suggestion-tier-2-3-implementation.md) which depends on this.
- UI for editing capability name/description — depends on the suggestion review UI.
