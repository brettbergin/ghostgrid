// Port of the PaneActivity parts of PaneInfoTests.
import { describe, expect, it } from "vitest";
import {
  activityEquals,
  activityFailed,
  activityLabel,
  forFinishedCommand,
  MINIMUM_SECONDS,
  type PaneActivity,
} from "../src/core/paneActivity";

const finished = (exitCode: number | null, seconds: number): PaneActivity => ({ kind: "finished", exitCode, seconds });
const bell: PaneActivity = { kind: "bell" };

describe("PaneActivity", () => {
  it("badges only long commands in unfocused panes", () => {
    expect(MINIMUM_SECONDS).toBe(5);
    expect(forFinishedCommand(0, 10, true)).toBeNull();
    expect(forFinishedCommand(0, 1, false)).toBeNull();
    expect(forFinishedCommand(0, 10, false)).toEqual(finished(0, 10));
    expect(forFinishedCommand(null, 5, false)).toEqual(finished(null, 5));
    expect(forFinishedCommand(1, 4.999, false)).toBeNull();
  });

  it("labels and failure", () => {
    expect(activityLabel(bell)).toBe("bell");
    expect(activityLabel(finished(0, 12.4))).toBe("12s");
    expect(activityLabel(finished(null, 65))).toBe("1m 05s");
    expect(activityLabel(finished(2, 30))).toBe("exit 2");
    expect(activityLabel(finished(0, 59.6))).toBe("1m 00s");
    expect(activityLabel(finished(0, 3725))).toBe("62m 05s");
    expect(activityFailed(finished(2, 30))).toBe(true);
    expect(activityFailed(finished(-1, 30))).toBe(true);
    expect(activityFailed(finished(0, 30))).toBe(false);
    expect(activityFailed(finished(null, 30))).toBe(false);
    expect(activityFailed(bell)).toBe(false);
  });

  it("compares by value", () => {
    expect(activityEquals(bell, { kind: "bell" })).toBe(true);
    expect(activityEquals(finished(1, 9), finished(1, 9))).toBe(true);
    expect(activityEquals(finished(1, 9), finished(1, 10))).toBe(false);
    expect(activityEquals(finished(0, 9), finished(null, 9))).toBe(false);
    expect(activityEquals(bell, finished(0, 9))).toBe(false);
    expect(activityEquals(null, null)).toBe(true);
    expect(activityEquals(bell, null)).toBe(false);
  });
});
