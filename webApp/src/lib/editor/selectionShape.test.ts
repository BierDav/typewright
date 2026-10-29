import { expect, test } from "bun:test";
import { selectionShape } from "./selectionShape";

test("joins neighboring selection rows before rounding", () => {
  const shape = selectionShape([{ x: 10, y: 0, width: 40, height: 20 }, { x: 20, y: 20, width: 20, height: 20 }]);
  expect(shape.match(/M/g)).toHaveLength(1);
  expect(shape.match(/Z/g)).toHaveLength(1);
  expect(shape).toContain("Q");
});
test("separate selections keep separate outlines", () => {
  const shape = selectionShape([{ x: 0, y: 0, width: 10, height: 20 }, { x: 30, y: 20, width: 10, height: 20 }]);
  expect(shape.match(/M/g)).toHaveLength(2);
  expect(selectionShape([])).toBe("");
});
