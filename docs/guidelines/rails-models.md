# Rails Model Standards

## Requirements

- `# frozen_string_literal: true` at top of every file
- Define constants at the top of the file
- Use positional arguments in enums: `enum status: [:draft, :published]`
- Use `normalizes` for attribute normalization
- Use `attribute` declarations for strong typing with defaults
- Use `counter_cache` for belongs_to relationships that need counts
- Pass models to jobs, not IDs (serialized automatically)
- Add YARD documentation to all public methods
- Use concerns for shared functionality
- **Slugs must use dashes, not underscores**: `"climate-action"` not `"climate_action"`
- **UUID v7 primary keys** for all new models
- Use `has_prefix_id` for API-facing models

## UUID v7 Primary Keys

All new models MUST use UUID v7 (RFC 9562) — time-ordered, better index performance than v4. v7 IDs land mostly-sequentially in the B-tree index; v4 inserts hit random leaf pages and bloat the working set.

Use `id: :uuid, default: nil` on `create_table` — `default: nil` strips Rails' implicit `gen_random_uuid()` (v4) default. IDs are assigned in Ruby by an `ApplicationRecord` `before_create` callback that calls `SecureRandom.uuid_v7`. Render-managed Postgres 16 has neither the built-in `uuidv7()` (PG 17) nor the `pg_uuidv7` extension, so app-side generation is the portable choice.

```ruby
# Migration
class CreateWidgets < ActiveRecord::Migration[8.1]
  def change
    create_table :widgets, id: :uuid, default: nil do |t|
      t.references :user, type: :uuid, foreign_key: true
      t.string :status, null: false
      t.timestamps
    end
  end
end

# Model — no extra config needed; ApplicationRecord assigns the id
class Widget < ApplicationRecord
  has_prefix_id :wgt  # human-readable prefixed IDs for APIs
  belongs_to :user
  validates :status, presence: true
end
```

Generate manually when not using AR (raw SQL, `insert_all`, controller-side IDs for event payloads): `SecureRandom.uuid_v7`.

`insert_all`/`upsert_all` bypass callbacks — supply `id:` explicitly. With the v4 default stripped at the DB layer, an `insert_all` that omits `id` will raise instead of silently writing a v4 — that's the intent.

## JSONB Storage Patterns

| Pattern | Use When | Example |
|---------|----------|---------|
| `store_accessor` | Simple key-value, flat structure | Theme preference, flags |
| `json_translate` | User-facing text needing i18n | Names, titles, descriptions |
| `store_model` | Complex nested objects with validations | Address, configuration |

### store_accessor — simple key-value

```ruby
# Migration: t.jsonb :preferences, default: {}, null: false
store_accessor :preferences, :theme, :notifications_enabled
```

### json_translate — translatable user-facing text (NON-NEGOTIABLE)

Use for ANY text displayed to users that may need translation.

```ruby
# Migration: t.jsonb :name_translations, default: {}, null: false
translates :name, :description
validates :name, presence: true

# Usage:
record.name = "Hello"       # sets for current locale
record.name_en = "Hello"    # sets for English
record.name_he = "Shalom"   # sets for Hebrew
```

### store_model — complex structured objects

```ruby
# app/models/shipping_address.rb
class ShippingAddress
  include StoreModel::Model

  attribute :street, :string
  attribute :city, :string
  attribute :postal_code, :string

  validates :street, :city, presence: true

  def full_address
    [street, city, postal_code].compact.join(", ")
  end
end

# Parent model
class Order < ApplicationRecord
  attribute :shipping_address, ShippingAddress.to_type
  validates :shipping_address, store_model: true

  # For arrays:
  attribute :line_items, OrderLineItem.to_array_type
end
```

### When NOT to use store_model

- Simple key-value pairs → use `store_accessor`
- User-facing text needing i18n → use `json_translate` (NON-NEGOTIABLE)
- Data that could be normalized → create proper associations/tables
- Frequently queried fields → use regular columns with indexes

## Example

```ruby
# frozen_string_literal: true

class Plan < ApplicationRecord
  has_prefix_id :plan

  INTERVALS = [:month, :year].freeze

  store_accessor :details, :features

  attribute :currency, default: "usd"
  normalizes :currency, with: ->(c) { c.downcase }

  validates :name, :amount, :interval, presence: true
  validates :interval, inclusion: { in: INTERVALS }

  scope :visible, -> { where(hidden: [nil, false]) }
  scope :monthly, -> { where(interval: :month) }
  scope :sorted, -> { order(amount: :asc) }

  # Returns formatted features list
  # @return [Array<String>]
  def features
    Array.wrap(super)
  end
end
```

## Anti-patterns

```ruby
# Bad - no frozen_string_literal, hash enum, self.get_all, missing YARD docs
class Plan < ApplicationRecord
  enum status: { draft: 0, published: 1 }  # use positional: [:draft, :published]

  def self.get_all
    all
  end

  def has_trial?
    self.trial_period_days > 0  # avoid self. on instance methods
  end
end
```
