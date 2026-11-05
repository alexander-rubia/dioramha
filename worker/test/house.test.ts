import assert from "node:assert/strict";
import { test } from "node:test";
import { assemble, checkLayout, devicesFor, type Answers, type Inventory, type Layout } from "../src/house.ts";

const answers: Answers = { levels: [0, 1], partyWalls: ["right"], pool: true, terrace: true, solar: true, width: 10, depth: 8 };
const inventory: Inventory = {
  areas: [
    { id: "lounge", name: "Lounge", entities: [{ id: "light.lounge", name: "Lamp" }] },
    { id: "gate", name: "Front", entities: [{ id: "switch.gate", name: "Lamp" }] },
  ],
};
const layout: Layout = {
  rooms: [
    { name: "Lounge", kind: "living", level: 0, x: 0, y: 0, width: 10, depth: 8, areaId: "lounge" },
    { name: "Landing", kind: "other", level: 1, x: 0, y: 0, width: 10, depth: 8, areaId: null },
  ],
  outdoor: { entranceAreaId: "gate" },
};

test("rejects long, narrow rooms and rooms too small for their furniture", () => {
  const house = { ...answers, levels: [0] };
  const bad: Layout = { rooms: [
    { name: "Corridor bedroom", kind: "bedroom", level: 0, x: 0, y: 0, width: 2.9, depth: 8 },
    { name: "Tiny study", kind: "study", level: 0, x: 3, y: 0, width: 1, depth: 2 },
    { name: "Hall", kind: "other", level: 0, x: 4, y: 0, width: 6, depth: 8 },
  ] };
  const text = checkLayout(bad, house, inventory).join(" ");
  assert.ok(text.includes("too long and narrow"));
  assert.ok(text.includes("needs at least"));
});

test("rejects a floor left mostly empty", () => {
  const bad: Layout = { rooms: [{ name: "Lounge", kind: "living", level: 0, x: 0, y: 0, width: 4, depth: 4 }] };
  assert.ok(checkLayout(bad, { ...answers, levels: [0] }, inventory).join(" ").includes("filled"));
});

test("accepts a layout that fits", () => assert.deepEqual(checkLayout(layout, answers, inventory), []));

test("reports rooms outside the house, overlaps and invented areas", () => {
  const bad: Layout = {
    rooms: [
      { name: "A", kind: "living", level: 0, x: 8, y: 0, width: 5, depth: 8, areaId: "ghost" },
      { name: "B", kind: "kitchen", level: 0, x: 8, y: 0, width: 2, depth: 2 },
      { name: "C", kind: "other", level: 9, x: 0, y: 0, width: 1, depth: 1 },
    ],
  };
  const text = checkLayout(bad, answers, inventory).join(" ");
  for (const word of ["outside", "overlap", "ghost", "level 9"]) assert.ok(text.includes(word), word);
});

test("every switch asks for confirmation, whatever its name says", () => {
  const [device] = devicesFor({ id: "a", name: "A", entities: [{ id: "switch.x", name: "Harmless lamp" }] }, []) as any[];
  assert.equal(device.confirm, true);
});

test("a cover that may be a door is left out and reported", () => {
  const warnings: string[] = [];
  const devices = devicesFor({ id: "a", name: "A", entities: [
    { id: "cover.garage", name: "Garage", deviceClass: "garage" },
    { id: "cover.unknown", name: "Unknown" },
    { id: "cover.bedroom", name: "Blind", deviceClass: "blind" },
  ] }, warnings) as any[];
  assert.deepEqual(devices.map((d) => d.entity), ["cover.bedroom"]);
  assert.equal(warnings.length, 2);
});

test("locks, alarms and cameras never become controls", () => {
  const devices = devicesFor({ id: "a", name: "A", entities: [
    { id: "lock.front", name: "Door" }, { id: "alarm_control_panel.home", name: "Alarm" }, { id: "camera.front", name: "Cam" },
  ] }, []);
  assert.equal(devices.length, 0);
});

test("builds a version 2 file with centered coordinates", () => {
  const { house } = assemble(layout, answers, inventory);
  assert.equal(house.version, 2);
  const lounge = house.rooms.find((r: any) => r.name === "Lounge") as any;
  assert.deepEqual(lounge.frame, { x: -5, z: -4, width: 10, depth: 8 });
  assert.ok(house.rooms.some((r: any) => r.id === "pool"));
  assert.ok(house.rooms.some((r: any) => r.id === "terrace"));
  const pool = house.rooms.find((r: any) => r.id === "pool") as any;
  assert.ok(pool.frame.x + pool.frame.width <= -5, "the pool is on the free side");
  assert.equal(house.extras.length, 1);
});

test("the garden moves to the right when the party wall is on the left", () => {
  const { house } = assemble(layout, { ...answers, partyWalls: ["left"] }, inventory);
  const pool = house.rooms.find((r: any) => r.id === "pool") as any;
  assert.ok(pool.frame.x >= 5);
});

test("no free side means no pool, and says so", () => {
  const { house, warnings } = assemble(layout, { ...answers, partyWalls: ["left", "right"] }, inventory);
  assert.ok(!house.rooms.some((r: any) => r.id === "pool"));
  assert.equal(warnings.length, 1);
});

test("steps stay in front of the house", () => {
  const garaged: Layout = { rooms: [{ name: "Garage", kind: "garage", level: -1, x: 4, y: 0, width: 6, depth: 6, areaId: "gate" }] };
  const { house } = assemble(garaged, { ...answers, levels: [-1, 0] }, inventory);
  const x = (house.site as any).steps.x;
  assert.ok(x - 0.9 >= -5 && x + 0.9 <= 5, `steps at ${x}`);
});

test("a terrace behind an upper floor gets a bigger gap", () => {
  const { house } = assemble(layout, answers, inventory);
  assert.ok((house.building as any).levelGap > 8.6);
  const { house: flat } = assemble(layout, { ...answers, terrace: false }, inventory);
  assert.equal((flat.building as any).levelGap, undefined);
});
