import { test, expect, describe } from "bun:test";
import { cn } from "../src/lib/utils.ts";

describe("cn", () => {
  test("merges class names correctly", () => {
    expect(cn("foo", "bar")).toBe("foo bar");
  });

  test("handles tailwind conflicts by keeping last", () => {
    expect(cn("p-4", "p-2")).toBe("p-2");
  });

  test("handles conditional classes", () => {
    expect(cn("base", false && "hidden", "visible")).toBe("base visible");
    expect(cn("base", true && "active")).toBe("base active");
  });

  test("handles undefined and null inputs", () => {
    expect(cn("foo", undefined, null, "bar")).toBe("foo bar");
  });

  test("handles empty string inputs", () => {
    expect(cn("", "foo", "")).toBe("foo");
  });

  test("merges complex tailwind classes", () => {
    expect(cn("text-red-500", "text-blue-500")).toBe("text-blue-500");
    expect(cn("mt-2 px-4", "mt-4")).toBe("px-4 mt-4");
  });

  test("handles array inputs", () => {
    expect(cn(["foo", "bar"], "baz")).toBe("foo bar baz");
  });
});
