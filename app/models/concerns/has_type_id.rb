# frozen_string_literal: true

# Gives a model a human-scannable TypeID (https://github.com/jetify-com/typeid)
# rendered from its UUID v7 primary key. The id column itself stays a UUID —
# the TypeID is a projection at the URL/route boundary.
#
# Format: "<prefix>_<crockford-base32-encoded-uuid>", e.g.
# "usr_01h4vjdvzefw18zfwz5dxw5y8g". The Base32 suffix preserves the
# timestamp ordering of UUID v7, so TypeIDs sort the same way the underlying
# ids do.
#
# Usage:
#
#   class User < ApplicationRecord
#     include HasTypeId
#     has_typeid :usr
#   end
#
#   user.to_param                                 # => "usr_01h4vjdvze..."
#   User.find("usr_01h4vjdvze...")                # decodes TypeID → UUID lookup
#   User.find("019e496b-c9c5-7631-ad67-...")      # raw UUID still works
#   User.find_by_typeid("usr_01h4vjdvze...")      # nil on miss instead of raising
#
# This avoids the prefixed_ids gem, which is Hashids-based and incompatible
# with non-integer (UUID) primary keys.
#
module HasTypeId
  extend ActiveSupport::Concern

  class_methods do
    # Declares the TypeID prefix for this model.
    #
    # @param prefix [String, Symbol]
    def has_typeid(prefix)
      @typeid_prefix = prefix.to_s
    end

    # @return [String, nil]
    def typeid_prefix
      @typeid_prefix
    end

    # Looks up a record by either a TypeID string or a raw UUID. Mixed-form
    # arrays (`find([a, b])`) and any other shape fall through to the
    # default ActiveRecord behaviour.
    #
    # A string that looks like a TypeID (correct prefix) but fails to decode
    # raises ActiveRecord::RecordNotFound, not TypeID::Error — callers using
    # a generic rescue get the same not-found signal as a missing row.
    def find(*args)
      if args.length == 1 && args[0].is_a?(String) && typeid_prefix &&
         args[0].start_with?("#{typeid_prefix}_")
        super(decode_typeid(args[0]))
      else
        super
      end
    rescue TypeID::Error
      raise ActiveRecord::RecordNotFound, "Couldn't find #{name} with 'id'=#{args[0]}"
    end

    # Non-raising counterpart to find. Returns nil when the TypeID is
    # malformed or no row matches.
    #
    # @param str [String]
    # @return [ActiveRecord::Base, nil]
    def find_by_typeid(str)
      uuid = decode_typeid(str)
      find_by(id: uuid)
    rescue TypeID::Error
      nil
    end

    private

    def decode_typeid(str)
      TypeID.from_string(str).uuid
    end
  end

  # @return [String, nil] TypeID string, or nil when the record has no id yet
  def to_param
    return nil unless id && self.class.typeid_prefix

    TypeID.from_uuid(self.class.typeid_prefix, id).to_s
  end
end
