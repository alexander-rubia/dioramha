import { assemble, checkLayout, type Answers, type Inventory, type Layout } from "./house.ts";

interface Env {
  AI: { run(model: string, input: unknown): Promise<any> };
  MODEL: string;
  /** Shared key while the assistant is private. Set with `wrangler secret put ASSISTANT_KEY`. */
  ASSISTANT_KEY: string;
}

const MAX_BODY_BYTES = 200_000;

const SYSTEM_PROMPT = `You design simple floor plans for a smart-home app.
Reply with one JSON object and nothing else, in this shape:
{"rooms":[{"name":string,"kind":"living"|"kitchen"|"bedroom"|"bathroom"|"study"|"laundry"|"garage"|"other",
"level":number,"x":number,"y":number,"width":number,"depth":number,"areaId":string|null}],
"outdoor":{"terraceAreaId":string|null,"poolAreaId":string|null,"entranceAreaId":string|null}}

Rules:
- Measurements are meters. x runs from the left of the house to the right, seen from the street. y runs from the front (street, y=0) to the back.
- Every room stays inside the house and rooms on the same level never overlap.
- Rooms should be close to square: never more than twice as long as they are wide. Minimum sizes in meters: living 3x4, kitchen 2.4x3, bedroom 2.8x3.2, bathroom 1.6x2, study 2.4x2.8, laundry 1.6x2, garage 3x5.
- Fill each level completely with rectangles. Use kind "other" and areaId null for halls, stairs and storage.
- Every indoor area appears in exactly one room, using its exact id. Outdoor areas go in "outdoor", never in rooms.
- Level 0 is the ground floor, -1 a basement, 1 the floor above. Put living rooms and kitchens on level 0, and bedrooms above when there is an upper floor, unless the notes say otherwise. Put a garage at the front of the lowest level.
- Keep the room names short, in the language of the area names.`;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

async function sameKey(given: string, expected: string): Promise<boolean> {
  const encode = (text: string) => crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  const [a, b] = await Promise.all([encode(given), encode(expected)]);
  return crypto.subtle.timingSafeEqual(a, b);
}

/** Models answer in several shapes, sometimes with text around the JSON. */
export function parseLayout(result: any): Layout | null {
  const content = result?.response ?? result?.choices?.[0]?.message?.content;
  if (content && typeof content === "object") return content as Layout;
  if (typeof content !== "string") return null;
  const start = content.indexOf("{");
  const end = content.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try {
    return JSON.parse(content.slice(start, end + 1)) as Layout;
  } catch {
    return null;
  }
}

function checkRequest(body: any): string | null {
  const a = body?.answers;
  if (!Array.isArray(body?.inventory?.areas)) return "inventory.areas is required.";
  if (!a || !Array.isArray(a.levels) || !a.levels.includes(0)) return "answers.levels must include 0, the ground floor.";
  if (!Array.isArray(a.partyWalls)) return "answers.partyWalls is required.";
  if (!(a.width >= 3 && a.width <= 40 && a.depth >= 3 && a.depth <= 40)) return "answers.width and answers.depth must be 3 to 40 meters.";
  return null;
}

async function draft(body: { inventory: Inventory; answers: Answers }, env: Env) {
  const model = env.MODEL;
  const { inventory, answers } = body;
  // Only what the layout needs: states and values never leave the phone in the first place.
  const summary = {
    house: answers,
    areas: inventory.areas.map((a) => ({ id: a.id, name: a.name })),
  };
  const messages: { role: string; content: string }[] = [
    { role: "system", content: SYSTEM_PROMPT },
    { role: "user", content: JSON.stringify(summary) },
  ];
  let problems: string[] = [];
  for (let attempt = 1; attempt <= 3; attempt++) {
    const result = await env.AI.run(model, { messages, max_tokens: 4000, temperature: 0.2 });
    const layout = parseLayout(result);
    problems = layout ? checkLayout(layout, answers, inventory) : ["The reply was not valid JSON."];
    if (layout && problems.length === 0) return { ...assemble(layout, answers, inventory), model, attempts: attempt };
    messages.push(
      { role: "assistant", content: JSON.stringify(layout ?? {}) },
      { role: "user", content: `Fix these problems and reply with the whole JSON again:\n${problems.join("\n")}` },
    );
  }
  return { error: "The model did not produce a valid layout.", problems, model, attempts: 3 };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health") return json({ ok: true });
    if (url.pathname !== "/v1/house/draft") return json({ error: "Not found." }, 404);
    if (request.method !== "POST") return json({ error: "Use POST." }, 405);
    if (!env.ASSISTANT_KEY) return json({ error: "The assistant is not configured." }, 503);
    const given = (request.headers.get("authorization") ?? "").replace(/^Bearer /, "");
    if (!(await sameKey(given, env.ASSISTANT_KEY))) return json({ error: "Unauthorized." }, 401);
    const text = await request.text();
    if (text.length > MAX_BODY_BYTES) return json({ error: "The request is too large." }, 413);
    let body: any;
    try {
      body = JSON.parse(text);
    } catch {
      return json({ error: "The body must be JSON." }, 400);
    }
    const invalid = checkRequest(body);
    if (invalid) return json({ error: invalid }, 400);
    try {
      const reply = await draft(body, env);
      return json(reply, "error" in reply ? 422 : 200);
    } catch (error) {
      // The message may quote the request, so only its type is reported.
      return json({ error: "The model could not be reached.", type: (error as Error).name }, 502);
    }
  },
};
