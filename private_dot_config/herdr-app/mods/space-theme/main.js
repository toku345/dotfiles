// Switches the window theme to match the active space's color, so each
// space is recognizable at a glance. Themes live in themes/space-<color>.json.
import { View, div } from "gpui-kit";
import { spaces, shared, run, checking } from "herdr";

const THEMED = new Set(["ansi1", "ansi2", "ansi3", "ansi4", "ansi5", "ansi6"]);
// Picked hex colors have no theme of their own.
const FALLBACK = "moss";

export default class SpaceTheme extends View {
  render() {
    const id = spaces().find((s) => s.active)?.id;
    const color = (shared("space.colors") ?? {})[id] ?? "ansi6";
    const name = id != null && THEMED.has(color) ? `space-${color}` : FALLBACK;
    // Also on a move between two spaces of one color, so a theme picked by hand does not stick.
    const key = `${id}:${name}`;
    if (!checking() && key !== this.applied) {
      this.applied = key;
      run("app.theme", { name });
    }
    return div();
  }
}
