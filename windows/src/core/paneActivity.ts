// Something that happened in a pane while you were not looking at it. A
// port of PaneActivity from GhostGridCore's PaneInfo.swift.

/// A bell, or a command that finished (with its exit code when the shell
/// reported one).
export type PaneActivity = { kind: "bell" } | { kind: "finished"; exitCode: number | null; seconds: number };

/// A command that exited non-zero. No exit code counts as success: shells
/// that do not report one should not paint every badge red.
export function activityFailed(activity: PaneActivity): boolean {
  return activity.kind === "finished" && (activity.exitCode ?? 0) !== 0;
}

/// Commands shorter than this do not badge: quick commands finish before
/// you would have looked away.
export const MINIMUM_SECONDS = 5;

/// The badge for a finished command, or null when it should not show: the
/// pane is focused, or the command was quick.
export function forFinishedCommand(exitCode: number | null, seconds: number, paneFocused: boolean): PaneActivity | null {
  if (paneFocused || !(seconds >= MINIMUM_SECONDS)) return null;
  return { kind: "finished", exitCode, seconds };
}

/// Short text for the badge: "bell", "12s", "1m 05s", "exit 2".
export function activityLabel(activity: PaneActivity): string {
  if (activity.kind === "bell") return "bell";
  const code = activity.exitCode;
  if (code !== null && code !== 0) return `exit ${code}`;
  // Swift's rounded(): halves away from zero.
  const total = Math.sign(activity.seconds) * Math.round(Math.abs(activity.seconds));
  if (total < 60) return `${total}s`;
  return `${Math.floor(total / 60)}m ${String(total % 60).padStart(2, "0")}s`;
}

/// Value equality (the Swift enum is Equatable); null equals null.
export function activityEquals(a: PaneActivity | null, b: PaneActivity | null): boolean {
  if (a === null || b === null) return a === b;
  if (a.kind === "bell" || b.kind === "bell") return a.kind === b.kind;
  return a.exitCode === b.exitCode && a.seconds === b.seconds;
}
