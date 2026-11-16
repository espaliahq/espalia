# frozen_string_literal: true

# Undo and Redo post the change their page named. The operation would act on
# any undoable change by id, so a page left open while someone else, or another
# tab, moved on could undo something its button never named.
module Plans::UndoOffer
  extend ActiveSupport::Concern

  STALE = "The page was out of date, so nothing changed. Here it is as it stands now."

  private

  # @param key [Symbol] :undo or :redo
  # @param event_id [String] what the button named
  def still_offered?(key, event_id)
    step = Operations::TeamPlanning::UndoStep.call(context: pundit_user, params: { plan_id:, scenario_id: })
    step.dig(key, :event_id) == event_id
  end
end
