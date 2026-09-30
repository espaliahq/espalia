# frozen_string_literal: true

# WCAG contrast measured as the browser paints it: tenant overrides, the
# colour scheme, translucent backgrounds and ancestor `opacity` all count,
# so an `opacity-70` or a `bg-*/10` regression shows up in the number.
module ContrastHelpers
  # Paints a colour onto a 1px canvas and returns its relative luminance.
  # Shared by both measurements so they can't disagree about the maths.
  CONTRAST_JS = <<~JS
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 1;
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    const paint = layers => {
      ctx.globalAlpha = 1;
      ctx.fillStyle = "#fff";
      ctx.fillRect(0, 0, 1, 1);
      for (const [css, alpha] of layers) {
        ctx.globalAlpha = alpha;
        ctx.fillStyle = css;
        ctx.fillRect(0, 0, 1, 1);
      }
      return [...ctx.getImageData(0, 0, 1, 1).data].slice(0, 3)
        .map(v => v / 255)
        .map(v => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4))
        .reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i], 0);
    };
    const ratio = (a, b) => {
      const [hi, lo] = [a, b].sort((x, y) => y - x);
      return Math.round(((hi + 0.05) / (lo + 0.05)) * 100) / 100;
    };
  JS

  # Contrast of the first element matching +css+ against everything painted
  # behind it: every ancestor background, outermost first.
  #
  # @param css [String]
  # @return [Float]
  def rendered_contrast(css)
    page.evaluate_script(<<~JS, css)
      (() => {
        #{CONTRAST_JS}
        const el = document.querySelector(arguments[0]);
        if (!el) throw new Error("rendered_contrast: nothing matches " + arguments[0]);
        const chain = [];
        let opacity = 1;
        for (let n = el; n; n = n.parentElement) {
          chain.unshift(getComputedStyle(n).backgroundColor);
          opacity *= parseFloat(getComputedStyle(n).opacity);
        }
        const backdrop = chain.map(c => [c, 1]);
        const bg = paint(backdrop);
        const fg = paint([...backdrop, [getComputedStyle(el).color, opacity]]);
        return ratio(fg, bg);
      })()
    JS
  end

  # Contrast of a probe span carrying +utility+ over a flat +background+.
  #
  # @param utility [String] e.g. "text-primary-ink"
  # @param background [String] any CSS colour
  # @return [Float]
  def utility_contrast(utility, background)
    page.evaluate_script(<<~JS, utility, background)
      (() => {
        #{CONTRAST_JS}
        const probe = document.createElement("span");
        probe.className = arguments[0];
        document.body.appendChild(probe);
        const fg = paint([[getComputedStyle(probe).color, 1]]);
        probe.remove();
        return ratio(fg, paint([[arguments[1], 1]]));
      })()
    JS
  end
end
