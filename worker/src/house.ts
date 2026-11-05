// Turns a proposed layout into a house file the app can load.
// Everything that affects safety is decided here, in plain code, and never by the model.

export type Side = "left" | "right" | "back";
export type RoomKind =
  | "living" | "kitchen" | "bedroom" | "bathroom" | "study" | "laundry" | "garage" | "other";

export interface Entity {
  id: string;
  name: string;
  deviceClass?: string;
  hvacModes?: string[];
}

export interface Area {
  id: string;
  name: string;
  entities: Entity[];
}

export interface Answers {
  levels: number[];
  partyWalls: Side[];
  pool: boolean;
  terrace: boolean;
  solar: boolean;
  width: number;
  depth: number;
  notes?: string;
}

export interface Inventory {
  areas: Area[];
  sensors?: Partial<Record<"alarm" | "weather" | "sun" | "solarPeak" | "solarEnergy" | "battery", string>> & {
    solar?: string[];
  };
}

export interface ProposedRoom {
  name: string;
  kind: RoomKind;
  level: number;
  x: number;
  y: number;
  width: number;
  depth: number;
  areaId?: string | null;
}

export interface Layout {
  rooms: ProposedRoom[];
  outdoor?: { terraceAreaId?: string | null; poolAreaId?: string | null; entranceAreaId?: string | null };
}

const SCALE = 1.35;
const TOLERANCE = 0.02;
const MAX_DEVICES_PER_ROOM = 8;
const OPENABLE_COVERS = new Set(["blind", "shutter", "awning", "curtain", "shade"]);
const PAINTS: Record<RoomKind, string[]> = {
  living: ["C2D3A6"],
  kitchen: ["EBB8A0"],
  bedroom: ["E9C6BC", "A8D0E6", "CDBFE8", "F1D9A7"],
  bathroom: ["92D5D8"],
  study: ["B3C4DA"],
  laundry: ["B9DFCB"],
  garage: ["D3D4D8"],
  other: ["D7D3CA"],
};
const SYMBOLS: Record<RoomKind, string> = {
  living: "sofa.fill",
  kitchen: "cooktop.fill",
  bedroom: "bed.double.fill",
  bathroom: "shower.fill",
  study: "desktopcomputer",
  laundry: "washer.fill",
  garage: "car.side.fill",
  other: "square.split.bottomrightquarter",
};

/** Smallest sensible [short side, long side] in meters: below this the furniture does not fit. */
const MIN_SIZE: Record<RoomKind, [number, number]> = {
  living: [3, 4],
  kitchen: [2.4, 3],
  bedroom: [2.8, 3.2],
  bathroom: [1.6, 2],
  study: [2.4, 2.8],
  laundry: [1.6, 2],
  garage: [3, 5],
  other: [0.8, 0.8],
};
const MAX_PROPORTION = 2.2;
const MIN_COVERAGE = 0.85;

const round = (value: number) => Math.round(value * 10000) / 10000;

/** Everything wrong with a proposal, in words the model can use to fix it. An empty list means valid. */
export function checkLayout(layout: Layout, answers: Answers, inventory: Inventory): string[] {
  const problems: string[] = [];
  if (!Array.isArray(layout?.rooms) || layout.rooms.length === 0) return ["The layout has no rooms."];
  const areaIDs = new Set(inventory.areas.map((a) => a.id));
  const used = new Map<string, string>();
  const claim = (id: string | null | undefined, owner: string) => {
    if (!id) return;
    if (!areaIDs.has(id)) problems.push(`${owner} uses unknown area "${id}".`);
    else if (used.has(id)) problems.push(`Area "${id}" is used by both ${used.get(id)} and ${owner}.`);
    else used.set(id, owner);
  };
  for (const room of layout.rooms) {
    const label = `Room "${room.name}"`;
    if (![room.x, room.y, room.width, room.depth].every(Number.isFinite)) {
      problems.push(`${label} has invalid measurements.`);
      continue;
    }
    if (!answers.levels.includes(room.level)) problems.push(`${label} is on level ${room.level}, which does not exist.`);
    if (!(room.kind in PAINTS)) problems.push(`${label} has unknown kind "${room.kind}".`);
    if (room.width <= 0 || room.depth <= 0) problems.push(`${label} must have a positive size.`);
    if (room.x < -TOLERANCE || room.y < -TOLERANCE || room.x + room.width > answers.width + TOLERANCE
      || room.y + room.depth > answers.depth + TOLERANCE) {
      problems.push(`${label} goes outside the house, which is ${answers.width} m wide and ${answers.depth} m deep.`);
    }
    claim(room.areaId, label);
    const short = Math.min(room.width, room.depth);
    const long = Math.max(room.width, room.depth);
    const [minShort, minLong] = MIN_SIZE[room.kind] ?? [0, 0];
    if (short < minShort - TOLERANCE || long < minLong - TOLERANCE) {
      problems.push(`${label} is ${room.width} x ${room.depth} m; a ${room.kind} needs at least ${minShort} x ${minLong} m.`);
    }
    if (room.kind !== "other" && long / short > MAX_PROPORTION) {
      problems.push(`${label} is ${room.width} x ${room.depth} m, too long and narrow. Make it closer to a square.`);
    }
  }
  for (const level of answers.levels) {
    const area = layout.rooms.filter((r) => r.level === level).reduce((sum, r) => sum + r.width * r.depth, 0);
    const total = answers.width * answers.depth;
    if (area / total < MIN_COVERAGE) {
      problems.push(`Level ${level} is only ${Math.round((area / total) * 100)}% filled. Fill it, using kind "other" for halls and storage.`);
    }
  }
  layout.rooms.forEach((a, i) => {
    for (const b of layout.rooms.slice(i + 1)) {
      if (a.level !== b.level) continue;
      const overlapX = Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
      const overlapY = Math.min(a.y + a.depth, b.y + b.depth) - Math.max(a.y, b.y);
      if (overlapX > TOLERANCE && overlapY > TOLERANCE) problems.push(`Rooms "${a.name}" and "${b.name}" overlap.`);
    }
  });
  claim(layout.outdoor?.terraceAreaId, "the terrace");
  claim(layout.outdoor?.poolAreaId, "the pool");
  claim(layout.outdoor?.entranceAreaId, "the entrance");
  return problems;
}

/** Devices the app can control safely. Anything else is left out and reported. */
export function devicesFor(area: Area | undefined, warnings: string[]): unknown[] {
  if (!area) return [];
  const devices: Record<string, unknown>[] = [];
  for (const entity of area.entities) {
    const domain = entity.id.split(".")[0];
    switch (domain) {
      case "light":
        devices.push({ entity: entity.id, name: entity.name, kind: "light" });
        break;
      case "switch":
        // A switch can open a door or start an appliance, and its name cannot be trusted to say so.
        devices.push({ entity: entity.id, name: entity.name, kind: "power", symbol: "power", confirm: true });
        break;
      case "fan":
        devices.push({ entity: entity.id, name: entity.name, kind: "power", symbol: "fan.fill" });
        break;
      case "cover":
        // Garage doors and gates are covers too, and the blind card opens them with no confirmation.
        if (OPENABLE_COVERS.has(entity.deviceClass ?? "")) {
          devices.push({ entity: entity.id, name: entity.name, kind: "blind" });
        } else {
          warnings.push(`${entity.name} was left out: it may be a door or gate, which covers do not support yet.`);
        }
        break;
      case "climate":
        devices.push({
          entity: entity.id, name: entity.name, kind: "climate",
          modes: (entity.hvacModes?.length ? entity.hvacModes : ["off", "heat"]).slice(0, 3),
        });
        break;
      case "vacuum":
        devices.push({ entity: entity.id, name: entity.name, kind: "vacuum" });
        break;
    }
  }
  if (devices.length > MAX_DEVICES_PER_ROOM) {
    warnings.push(`${area.name} had ${devices.length} devices; only the first ${MAX_DEVICES_PER_ROOM} were kept.`);
  }
  return devices.slice(0, MAX_DEVICES_PER_ROOM);
}

function furnitureFor(kind: RoomKind, w: number, d: number, seen: number): unknown[] {
  const back = -d / SCALE / 2 + 0.06; // In catalog units, as the app draws furniture.
  const wall = back * SCALE;
  const item = (type: string, x: number, z: number, extra: Record<string, unknown> = {}) =>
    ({ type, x: round(x), z: round(z), ...extra });
  switch (kind) {
    case "living":
      return [item("rug", 0, wall + 2.3), item("coffee_table", 0, wall + 2.4), item("sofa", 0, wall)];
    case "kitchen":
      return [
        item("counter", -0.28 * SCALE, (back + 0.28) * SCALE, { width: round(w - 0.6 * SCALE) }),
        item("fridge", (w / SCALE / 2 - 0.3) * SCALE, (back + 0.28) * SCALE),
      ];
    case "bedroom":
      if (seen === 0) return [item("double_bed", 0, wall)];
      return [
        item("kid_bed", (-w / SCALE / 2 + 0.55) * SCALE, wall, { color: "2F6DB5", accent: "B5834F" }),
        item("cabinet", (w / SCALE / 2 - 0.28) * SCALE, (back + 0.22) * SCALE, { color: "E3B23C" }),
      ];
    case "bathroom":
      return [item("bathtub", 0, (back + 0.36) * SCALE, { width: round(w - 0.2 * SCALE) })];
    case "study":
      return [item("desk", 0, wall)];
    case "laundry":
      return [item("washer", 0, wall, { color: "7B8FA8" })];
    case "garage":
      return [item("car", 0, 0.2 * SCALE, { rotation: 90 })];
    default:
      return [];
  }
}

/** Outdoor steps go beside the garage ramp, always in front of the house. */
function stepsX(garage: ProposedRoom | undefined, hw: number): number {
  if (!garage) return 0;
  const right = garage.x + garage.width - hw + 1;
  const x = right + 0.9 <= hw ? right : garage.x - hw - 1;
  return round(Math.min(Math.max(x, -hw + 0.9), hw - 0.9));
}

const slug = (text: string, taken: Set<string>) => {
  const base = text.toLowerCase().normalize("NFD").replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "") || "room";
  let id = base;
  for (let n = 2; taken.has(id); n++) id = `${base}_${n}`;
  taken.add(id);
  return id;
};

/** Builds a complete house file, version 2, from a layout that passed `checkLayout`. */
export function assemble(layout: Layout, answers: Answers, inventory: Inventory) {
  const warnings: string[] = [];
  const hw = answers.width / 2;
  const hd = answers.depth / 2;
  const levels = [...answers.levels].sort((a, b) => a - b);
  const lowest = levels[0];
  const areas = new Map(inventory.areas.map((a) => [a.id, a]));
  const taken = new Set(["terrace", "pool", "solar", "entrance"]);
  const seen: Partial<Record<RoomKind, number>> = {};

  // The model works from the front-left corner; the house file from the center of the house.
  const frameOf = (r: ProposedRoom) => ({
    x: round(r.x - hw), z: round(hd - r.y - r.depth), width: round(r.width), depth: round(r.depth),
  });

  const rooms: Record<string, unknown>[] = [];
  const extras: Record<string, unknown>[] = [];
  for (const room of layout.rooms) {
    const count = seen[room.kind] ?? 0;
    const area = room.areaId ? areas.get(room.areaId) : undefined;
    if (!area) {
      extras.push({ name: room.name, level: room.level, frame: frameOf(room), color: PAINTS[room.kind][0] });
      continue;
    }
    seen[room.kind] = count + 1;
    const paints = PAINTS[room.kind];
    rooms.push({
      id: slug(room.name, taken), name: room.name, symbol: SYMBOLS[room.kind], style: "interior", level: room.level,
      frame: frameOf(room), paint: paints[count % paints.length],
      ...(room.kind === "garage" ? { floorColor: "8E9096" } : {}),
      furniture: furnitureFor(room.kind, room.width, room.depth, count),
      devices: devicesFor(area, warnings),
    });
  }

  // The garden sits on the free side; with party walls on both sides it stays behind the house.
  const walls = answers.partyWalls;
  const sideRoom = walls.includes("left") && walls.includes("right") ? 0 : 6.2;
  const gardenOnRight = walls.includes("left") && !walls.includes("right");
  const gardenMinX = gardenOnRight ? -hw : -hw - sideRoom;
  const gardenMaxX = gardenOnRight ? hw + sideRoom : hw;
  const backRoom = answers.terrace ? 4.2 : 1.5;
  const frontRoom = lowest < 0 ? 0.9 : 0;
  const garden = {
    x: gardenMinX, z: round(-hd - backRoom), width: round(gardenMaxX - gardenMinX),
    depth: round(answers.depth + backRoom + frontRoom),
  };
  const sideCenter = gardenOnRight ? hw + 3.1 : -hw - 3.1;

  if (answers.terrace) {
    rooms.push({
      id: "terrace", name: "Terrace", symbol: "chair.lounge.fill", style: "terrace", level: 0,
      frame: { x: -hw, z: -hd - 4, width: answers.width, depth: 4 },
      pergola: { width: round(Math.min(5, answers.width - 1)), height: 2.3 },
      furniture: [
        { type: "lounger", x: round(-hw + 1.5), z: 0 }, { type: "lounger", x: round(-hw + 2.8), z: 0 },
      ],
      devices: devicesFor(areas.get(layout.outdoor?.terraceAreaId ?? ""), warnings),
    });
  }
  if (answers.pool && sideRoom > 0) {
    const depth = round(Math.min(6, answers.depth - 2));
    rooms.push({
      id: "pool", name: "Pool", symbol: "water.waves", style: "pool", level: 0,
      frame: { x: round(sideCenter - 1.5), z: round(-depth / 2), width: 3, depth },
      furniture: [], devices: devicesFor(areas.get(layout.outdoor?.poolAreaId ?? ""), warnings),
    });
  } else if (answers.pool) {
    warnings.push("The pool was left out: there is no free side of the house to place it.");
  }
  if (answers.solar) {
    rooms.push({
      id: "solar", name: "Solar", symbol: "sun.max.fill", style: "solar", level: 0,
      frame: { x: -3, z: -hd, width: 6, depth: 3 }, furniture: [], devices: [],
    });
  }
  rooms.push({
    id: "entrance", name: "Entrance", symbol: "tree.fill", style: "garden", level: lowest,
    frame: { x: -hw, z: hd, width: answers.width, depth: 4 }, furniture: [],
    devices: devicesFor(areas.get(layout.outdoor?.entranceAreaId ?? ""), warnings),
  });

  const garage = layout.rooms.find((r) => r.kind === "garage" && r.level === lowest);
  const streetX = round((gardenMinX + gardenMaxX) / 2);
  const roofHalfDepth = round(hd + 0.4);
  const sensors = inventory.sensors ?? {};
  const house = {
    version: 2,
    name: "My Home",
    sensors: {
      alarm: sensors.alarm ?? "", weather: sensors.weather ?? "", sun: sensors.sun ?? "sun.sun",
      solar: sensors.solar ?? [], solarPeak: sensors.solarPeak ?? "", solarEnergy: sensors.solarEnergy ?? "",
      battery: sensors.battery ?? "",
    },
    building: {
      halfWidth: hw, halfDepth: hd, wallHeight: 1.0, lowWall: 0.35, levels, partyWalls: walls,
      // Upper floors float high enough that the terrace behind the house stays visible and tappable.
      ...(answers.terrace && levels.includes(1) ? { levelGap: round(3.3 + (2 * hd + 2) * 0.685) } : {}),
    },
    roof: {
      halfWidth: round(hw + 0.4), halfDepth: roofHalfDepth, ridge: round(Math.max(hw - hd, 0.5)),
      rise: round(Math.min(hw + 0.4, roofHalfDepth) * 0.25), chimney: { x: round(-hw / 2), z: round(hd / 2) },
      ...(answers.solar ? { panels: { columns: 6, rows: 2, along: 0.52 } } : {}),
    },
    site: {
      garden,
      street: {
        x: streetX, width: round(gardenMaxX - gardenMinX + 0.4), earthZ: round(hd + 2), earthDepth: 4,
        roadZ: round(hd + 5), roadDepth: 1.8,
      },
      ...(garage ? {
        ramp: { x: round(garage.x + garage.width / 2 - hw), width: round(Math.max(garage.width - 0.6, 2)) },
      } : {}),
      ...(lowest < 0 ? { steps: { x: stepsX(garage, hw), width: 1.8, count: 5 } } : {}),
      trees: sideRoom > 0
        ? [{ level: 0, x: round(sideCenter - 2), z: round(-hd - 2.4), size: 2 }]
        : [],
      hedges: [],
    },
    extras,
    rooms,
  };
  return { house, warnings };
}
