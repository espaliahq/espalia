# frozen_string_literal: true

# The session page's update toast: a persistent `role="status"` region that
# `calibration_freshness_controller` fills when a reload brought new numbers
# ("Updated just now · 3 ratings changed since 14:32 — Raj ×2, Sam ×1.
# Readiness 76% → 78%."), or with a standing notice while a reload is held
# for an open drawer — plus the `<template>`s each is cloned from.
#
# The region never leaves the DOM, so assistive tech announces each message
# without stealing focus — the explorer's WriteStatus rule. It sits in the
# flow under the header rather than floating: the comparison drawer owns the
# bottom of the viewport and the header's buttons the top right.
class Views::CalibrationSessions::FreshnessStatus < Views::Base
  REGION_ID = "calibration-freshness-status"

  def view_template
    div(
      id: REGION_ID,
      role: "status",
      aria_live: "polite",
      aria_atomic: "true",
      class: "empty:hidden mt-3",
      data: { calibration_freshness_target: "region" }
    )
    template(data: { calibration_freshness_target: "template" }) { toast }
    template(data: { calibration_freshness_target: "waitingTemplate" }) { waiting_notice }
  end

  private

  # Not a toast: it stays until the held reload lands and replaces it.
  def waiting_notice
    div(
      class: "flex max-w-2xl items-start gap-3 rounded-lg border border-amber-300 dark:border-amber-700 " \
             "bg-amber-50 dark:bg-amber-950 px-4 py-3 text-sm text-amber-900 dark:text-amber-100",
      data: { freshness_waiting: "" }
    ) do
      span(class: "mt-1.5 h-2 w-2 shrink-0 rounded-full bg-amber-500", aria: { hidden: "true" })
      span(class: "flex-1") { "Newer ratings are waiting — they load when the comparison drawer or dialog closes." }
    end
  end

  def toast
    div(
      class: "flex max-w-2xl items-start gap-3 rounded-lg border border-gray-200 dark:border-gray-700 " \
             "bg-white dark:bg-gray-800 px-4 py-3 text-sm text-gray-900 dark:text-white shadow-sm",
      data: { controller: "flash", flash_delay_value: 12_000 }
    ) do
      span(class: "mt-1.5 h-2 w-2 shrink-0 rounded-full bg-green-500", aria: { hidden: "true" })
      span(class: "flex-1", data: { message: "" })
      button(
        type: "button",
        class: "inline-flex h-6 w-6 shrink-0 items-center justify-center rounded text-gray-600 " \
               "dark:text-gray-300 hover:text-gray-900 dark:hover:text-white cursor-pointer",
        aria_label: "Dismiss update",
        data: { action: "flash#dismiss" }
      ) { "×" }
    end
  end
end
