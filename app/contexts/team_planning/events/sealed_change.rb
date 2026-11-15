# frozen_string_literal: true

# What a change kind needs once its end state holds a sealed value: a
# `Shreddable::Value` raises when serialised, so end states compare by what
# they reveal, and a value whose key is gone equals nothing.
module TeamPlanning::Events::SealedChange
  # @param left [Hash, nil]
  # @param right [Hash, nil]
  # @return [Boolean]
  def same_end_state?(left, right)
    return left.nil? && right.nil? if left.nil? || right.nil?

    revealed(left) == revealed(right) && [ left, right ].none? { removed?(it) }
  end

  private

  # Lands a change on the person it names, or lists them unresolved when the
  # scenario's map doesn't hold them.
  def on_person(map, data)
    unless map.holds?(data[:subject_id])
      return map.with(unresolved: map.unresolved + [ TeamPlanning::Baseline::Unresolved.new(person_id: data[:subject_id], why: nil) ])
    end

    map.updating(data[:subject_id]) { yield(it) }
  end

  def revealed(end_state) = end_state.to_h.transform_keys(&:to_s).transform_values { it.is_a?(Shreddable::Value) ? it.reveal : it }

  def removed?(end_state) = end_state.to_h.values.any? { it.is_a?(Shreddable::Value) && it.removed? }
end
