# Chat-Zig Roadmap

> AI-powered etch-a-sketch + chat for learning material

## Vision

Transform chat-zig from a one-shot "AI draws, you watch" demo into a
**collaborative visual learning tool** — a bidirectional whiteboard where the
user and AI build understanding together through drawing and conversation.

---

## Current State

- Chat with Anthropic Claude (haiku / sonnet / opus)
- Canvas panel with 11 `DrawCommand` variants (fills, strokes, lines, text)
- Comptime-generated Anthropic tool schema from `DrawCommand` union
- Async HTTP on worker threads with dispatch back to main thread
- File attachments (images, PDFs, text)
- Dark / light theme with semantic color tokens
- Glass UI effect with transparent titlebar

### Key Limitations

| Limitation                                       | Impact                                                   |
| ------------------------------------------------ | -------------------------------------------------------- |
| Canvas clears every turn                         | No ability to build up a diagram over multiple exchanges |
| AI-only drawing                                  | User can't sketch, annotate, or point at things          |
| No playback / history                            | Can't step through how something was drawn               |
| Limited primitives (no arrows, curves, polygons) | Can't express most educational diagrams                  |
| AI has no memory of what's on canvas             | Can't reference or modify prior drawings                 |

---

## Gooey Framework — What's Already Available

Before diving into the plan, here's an inventory of Gooey capabilities that
chat-zig can leverage today without any framework changes.

### Interactive Canvas (canvas_drawing.zig pattern)

Gooey already supports user drawing on the canvas. The `canvas_drawing.zig`
example demonstrates the full pattern:

1. **Wrap the canvas in a clickable box** — `on_click_handler` fires on click:

   ```zig
   ui.box(.{
       .on_click_handler = cx.command(AppState, AppState.addDotAtMouse),
   }, .{
       ui.canvas(CANVAS_WIDTH, CANVAS_HEIGHT, paintCanvas),
   })
   ```

2. **Read mouse position from Gooey** — `g.last_mouse_x` / `g.last_mouse_y`
   are tracked automatically by the framework.

3. **Convert to canvas-local coordinates** — subtract the canvas bounds origin:

   ```zig
   const local_x = g.last_mouse_x - bounds.x;
   const local_y = g.last_mouse_y - bounds.y;
   ```

4. **Continuous drawing via `on_event`** — the app-level `on_event` callback
   receives `mouse_dragged` events (fires continuously while mouse button is
   held), enabling freehand stroke capture.

### Input Events Available

`InputEvent` is a tagged union with everything we need:

- `mouse_down` / `mouse_up` — click start/end with button + modifiers
- `mouse_moved` — hover tracking
- `mouse_dragged` — continuous position updates while button held
- `mouse_entered` / `mouse_exited` — canvas boundary detection
- `scroll` — could map to zoom/pan
- `key_down` / `key_up` — keyboard shortcuts, tool switching

Each mouse event carries `position: Point(f64)`, `button: MouseButton`,
`click_count: u32`, and `modifiers: Modifiers` (shift/ctrl/alt/cmd).

### DrawContext Primitives

`DrawContext` (the canvas paint API) already has far more than the 11 commands
exposed to the AI:

| Category             | Methods                                                                                                                                    |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| **Rectangles**       | `fillRect`, `fillRoundedRect`, `strokeRect`                                                                                                |
| **Circles/Ellipses** | `fillCircle`, `fillEllipse`, `fillCircleAdaptive`, `fillEllipseAdaptive`, `fillCircleWithSegments`, `strokeCircle`, `strokeEllipse`        |
| **Triangles**        | `fillTriangle`                                                                                                                             |
| **Lines**            | `line` (optimized axis-aligned + diagonal), `strokeLine`, `strokeLineStyled`                                                               |
| **Polylines**        | `polyline`, `polylineClipped` — multi-segment connected paths                                                                              |
| **Point Clouds**     | `pointCloud`, `pointCloudClipped`, `pointCloudColored`, `pointCloudColoredArrays` — instanced batch rendering                              |
| **Paths**            | `beginPath`, `fillPath`, `strokePath`, `strokePathStyled`, `cachePath`, `fillCached`, `fillCachedAt`, `fillStaticPath`, `fillStaticPathAt` |
| **Gradients**        | `fillPathLinearGradient`, `fillPathRadialGradient`, `fillRectLinearGradient`, `fillRectRadialGradient`, `fillCircleRadialGradient`         |
| **Text**             | `drawText`, `drawTextVCentered`, `measureText`                                                                                             |

Notably, `polyline` and `pointCloudColoredArrays` are ideal for rendering
user freehand strokes efficiently — one GPU draw call for an entire stroke.

`StrokeStyle` supports `LineCap` (.butt, .round, .square) and `LineJoin`
(.miter, .round, .bevel) for polished stroke rendering.

---

## Phase 1 — Canvas Persistence & Playback

_Foundation work. Small changes, large impact on feel._

### 1.1 Stop Auto-Clearing the Canvas

Currently `applyCanvasResult` in `state.zig` calls `clearCanvas()` every turn:

```zig
// state.zig L564-565
canvas_state.clearCanvas();
```

Instead:

- Remove the automatic `clearCanvas()` call
- Let the existing `set_background` tool act as the explicit clear (AI calls
  it when it wants a fresh canvas)
- Update `canvas_system_prompt` in `canvas_tools.zig`: "Only call
  `set_background` when you want to start fresh. Otherwise, new commands
  layer on top of what's already drawn."

**Effort:** ~30 minutes | **Impact:** Every conversation becomes a progressive diagram

### 1.2 Playback Scrubber

Add a slider beneath the canvas that controls how many commands are visible.

- Add `visible_count: usize` to `canvas_state.zig` (defaults to `command_count`)
- `replay()` renders `commands[0..visible_count]` instead of
  `commands[0..command_count]`
- UI: horizontal slider in `CanvasPanel` that maps `0..command_count` →
  `visible_count`
- Keyboard: left/right arrow keys step ±1 when canvas is focused

This lets users scrub through any drawing as a step-by-step tutorial.

**Effort:** ~2 hours | **Impact:** Every AI drawing becomes a replayable lesson

### 1.3 Per-Turn Undo

Track turn boundaries in the command buffer:

- Add `turn_boundaries: [MAX_TURNS]usize` array — stores `command_count` at
  the start of each AI response batch
- "Undo last turn" pops `command_count` back to the previous boundary
- "Redo" restores forward (commands are still in the buffer, just hidden)
- Wire to Cmd+Z / Cmd+Shift+Z and an undo button in the canvas header

**Effort:** ~1–2 hours | **Impact:** Safe exploration — try things and revert

---

## Phase 2 — User Drawing (The "Etch-a-Sketch")

_Bidirectional canvas. User draws, AI sees and responds._

This is entirely possible with existing Gooey primitives — no framework
changes needed.

### 2.1 Freehand Stroke Capture

Using the `canvas_drawing.zig` pattern + `mouse_dragged` events:

- **On `mouse_down`**: begin a new stroke, record first point
- **On `mouse_dragged`** (via app-level `on_event`): append points to the
  active stroke. Gooey fires `mouse_dragged` continuously while the button is
  held, giving smooth freehand input.
- **On `mouse_up`**: finalize the stroke

Storage (static allocation per CLAUDE.md):

```zig
const MAX_USER_STROKES = 256;
const MAX_POINTS_PER_STROKE = 512;

const UserStroke = struct {
    points: [MAX_POINTS_PER_STROKE][2]f32 = undefined,
    point_count: usize = 0,
    color: Color,
    width: f32,
};
```

Rendering: each stroke calls `ctx.polyline(points[0..count], width, color)`.
Polyline is already in DrawContext and handles the coordinate transform +
scene allocation internally. For many small strokes, this is efficient — each
`polyline` call is one draw operation.

### 2.2 Drawing Tool Palette

Minimal toolbar above or beside the canvas:

| Tool          | Input Mapping                                 |
| ------------- | --------------------------------------------- |
| **Freehand**  | `mouse_dragged` → polyline                    |
| **Line**      | click start + click end (rubber-band preview) |
| **Rectangle** | click-drag corner to corner                   |
| **Circle**    | click center + drag radius                    |
| **Arrow**     | click start + click end (with arrowhead)      |
| **Eraser**    | `mouse_dragged` → remove strokes under cursor |
| **Text**      | click to place, type to enter text            |

Tool switching via toolbar buttons or keyboard shortcuts (F, L, R, C, A, E, T).

Color picker: a small row of preset colors + the current theme accent.

### 2.3 Canvas State Serialization (AI Sees User Drawings)

For the AI to understand what the user drew, serialize the canvas state into
the system prompt:

```
The canvas currently contains:

AI drawings (from tool_use):
- fill_rect at (10, 10) size 100×50, color=primary
- draw_text "Hello" at (120, 80), font_size=16

User drawings (freehand):
- Stroke #1: 23 points from (50,100) to (200,150), red, width=3
- Stroke #2: arrow from (200,150) to (300,200), blue, width=2
```

Generate this from `AiCanvas.commands[0..command_count]` + `UserStroke` array.
Cap at ~2K tokens to avoid blowing the context window.

### 2.4 Canvas Snapshot as Image (Stretch)

Instead of text serialization, render the canvas to a pixel buffer and send as
an image via the existing file attachment pipeline. Gives the AI true "vision"
of spatial relationships. Requires render-to-texture support in Gooey (not yet
available — would be a framework addition).

---

## Phase 3 — Richer Drawing Primitives

_Unlock real educational diagrams. These go into Gooey's `DrawCommand` union
and automatically appear in the Anthropic tool schema via comptime generation._

### 3.1 Arrows

The single most impactful missing primitive for learning material.

```zig
draw_arrow: struct {
    x1: f32, y1: f32,  // tail
    x2: f32, y2: f32,  // head
    color: ThemeColor,
    width: f32,
    head_size: f32,     // arrowhead length in pixels
}
```

Render: line body via `ctx.line()` + filled triangle arrowhead via
`ctx.fillTriangle()` at (x2,y2) pointing in the line direction.

Enables: flowcharts, cause/effect, force diagrams, labeling, graph edges.

### 3.2 Bezier Curves

```zig
draw_bezier: struct {
    x1: f32, y1: f32,    // start
    cx1: f32, cy1: f32,  // control point 1
    cx2: f32, cy2: f32,  // control point 2
    x2: f32, y2: f32,    // end
    color: ThemeColor,
    width: f32,
}
```

Render: evaluate the cubic bezier into a polyline (adaptive subdivision),
then `ctx.polyline()`. Gooey's `Path` API with `beginPath` / `strokePath`
may also work here.

Enables: function plots, curved arrows, organic shapes, splines.

### 3.3 Polyline (AI-accessible)

DrawContext already has `polyline()`, but the AI can't use it because
`DrawCommand` has no polyline variant. Adding one requires a `PointPool`
(similar to `TextPool`) since slices can't be stored in the fixed-size union.

```zig
draw_polyline: struct {
    points_idx: u16,  // index into PointPool
    point_count: u16,
    color: ThemeColor,
    width: f32,
    closed: bool,
}
```

PointPool: fixed-capacity `[MAX_POOL_POINTS][2]f32` with bump allocation.

### 3.4 Arc

```zig
draw_arc: struct {
    cx: f32, cy: f32,
    radius: f32,
    start_angle: f32,  // radians
    end_angle: f32,
    color: ThemeColor,
    width: f32,
}
```

Render: evaluate arc into polyline segments, then `ctx.polyline()`.

### Priority Order

| Command         | Learning Value | Implementation Complexity        |
| --------------- | -------------- | -------------------------------- |
| `draw_arrow`    | ★★★★★          | Low — line + triangle            |
| `draw_bezier`   | ★★★★           | Medium — subdivision to polyline |
| `draw_polyline` | ★★★★           | Medium — needs PointPool         |
| `draw_arc`      | ★★★            | Low — trig to polyline           |
| `fill_polygon`  | ★★★            | High — triangulation             |

---

## Phase 4 — Canvas State & Object Model

_Let the AI reference and modify specific elements._

### 4.1 Named Objects / IDs

Add an optional `id` field to draw commands. AI can tag elements:

```json
{
  "tool": "fill_circle",
  "id": "earth",
  "cx": 250,
  "cy": 200,
  "radius": 30,
  "color": "primary"
}
```

Later: "change the color of 'earth' to blue" → look up by ID, mutate in place.

Storage: `ObjectIdPool` — maps string IDs to command indices. Fixed capacity
(1024 entries × 64B = 64KB).

### 4.2 Spatial Queries

"What's at (100, 200)?" → hit-test against command bounding boxes.

User clicks on canvas → system prompt includes "User clicked at (100, 200),
which is near 'earth' (fill_circle at cx=250, cy=200, r=30)."

Enables pointing-based interaction — user clicks, AI explains that element.

### 4.3 Command Mutation Tools

New tools for the AI:

- `modify_object: { id, field, value }` — change a property
- `remove_object: { id }` — hide/remove a specific element
- `move_object: { id, dx, dy }` — translate an element

Enables iterative refinement without redrawing from scratch.

### 4.4 Layer System

Commands belong to named layers (default: `"base"`):

- `show_layer` / `hide_layer` / `set_layer` tools
- User can toggle layer visibility in the UI
- Enables progressive reveal: "Show me the skeleton first, then muscles,
  then skin"

Storage: `layer_id: u8` per command + `layer_visible: [32]bool` flag array.

---

## Phase 5 — Learning-Specific Features

_Purpose-built for education._

### 5.1 Lesson Mode

Structured learning flow driven by a JSON schema:

```json
{
  "title": "The Water Cycle",
  "steps": [
    {
      "prompt": "Let's start with evaporation.",
      "ai_instruction": "Draw the ocean at the bottom, sun top-right, arrows going up labeled 'evaporation'",
      "quiz": null
    },
    {
      "prompt": "Now condensation...",
      "ai_instruction": "Add clouds in the upper area with small droplets forming",
      "quiz": "What causes water vapor to form clouds?"
    }
  ]
}
```

- Each step can have: canvas instructions, text explanation, optional quiz
- Progress bar shows current step
- Pre-built lessons ship as assets; users can author their own

### 5.2 Quiz Mode

- AI draws something incomplete or unlabeled
- User fills in the blank by drawing (Phase 2) or typing
- AI evaluates the answer via canvas serialization or text input
- Modes:
  - **Label the diagram** — user places text on canvas
  - **Draw the missing part** — user sketches, AI evaluates
  - **Multiple choice** — AI draws options, user clicks one
  - **Free response** — user explains in chat

### 5.3 Progress Tracking

- Track lessons completed, quiz scores, time spent
- Local storage: `~/.chat-zig/progress.json`
- Simple dashboard in the app

### 5.4 Export & Save

- **Save canvas as PNG** — render to pixel buffer, write to file
- **Save session** — serialize command history + chat transcript
- **Load session** — replay a saved session (reuses playback scrubber)
- **Export to PDF** — canvas snapshots + chat text as study notes

---

## Phase 6 — Streaming & Polish

_Performance and feel._

### 6.1 Streaming Draw Commands

Currently the entire API response is buffered before parsing. Instead:

- Stream the Anthropic response (`text/event-stream` SSE format)
- Parse `tool_use` blocks as they arrive
- Push each `DrawCommand` to the canvas immediately
- The user watches the drawing build up in real-time

### 6.2 Animation Commands

```zig
pause: struct { duration_ms: u16 }
```

AI can pace its drawing: "draw the base... pause... now add the label."

The playback scrubber (Phase 1.2) interacts with timing — scrub position maps
to time as well as command index.

### 6.3 Canvas Resize / Zoom / Pan

- `scroll` events → zoom in/out on the canvas
- Click-drag with modifier (e.g., Space+drag) → pan
- Canvas size adapts to window (currently fixed 500×400)
- Coordinate system stays stable (AI still targets 500×400 logical space)

### 6.4 Multiple Canvases

- Tabbed canvases: "Canvas 1: Cell Diagram", "Canvas 2: Organelle Detail"
- AI specifies which canvas to target via a `canvas_id` tool parameter
- Side-by-side comparison mode

---

## Technical Notes

### Gooey Framework Changes Required

| Feature                                                   | Gooey Change                                     | Phase |
| --------------------------------------------------------- | ------------------------------------------------ | ----- |
| New `DrawCommand` variants (arrow, bezier, polyline, arc) | Add to union + `AiCanvas.replayOne()`            | 3     |
| `PointPool` for polyline/polygon commands                 | New pool type alongside `TextPool`               | 3     |
| Canvas-to-PNG export                                      | Render-to-texture / pixel readback               | 5.4   |
| SSE streaming HTTP                                        | `text/event-stream` parser or raw chunked reader | 6.1   |

Everything in Phase 1 and Phase 2 requires **zero** Gooey framework changes —
it's all application-level code using existing APIs.

### Memory Budget (CLAUDE.md Compliance)

All buffers statically allocated at init:

| Buffer                                   | Size Estimate                | Phase |
| ---------------------------------------- | ---------------------------- | ----- |
| `UserStroke[256]` (freehand strokes)     | 256 × (512 × 8B + 16B) ≈ 1MB | 2     |
| `TurnBoundaries[256]` (undo stack)       | 256 × 8B = 2KB               | 1.3   |
| `PointPool` (AI polyline/polygon points) | 64K points × 8B = 512KB      | 3.3   |
| `ObjectIdPool` (named objects)           | 1024 × 64B = 64KB            | 4.1   |
| `LayerState` (visibility flags)          | 32 × 1B = 32B                | 4.4   |
| `LessonBuffer` (loaded lesson JSON)      | 64KB                         | 5.1   |

Total additional static memory: ~1.6MB — well within budget.

### Assertion Invariants (CLAUDE.md #3)

Every new function gets ≥2 assertions. Key invariants to enforce:

- `visible_count <= command_count` (playback scrubber)
- `turn_boundary[i] <= turn_boundary[i+1]` (undo stack monotonicity)
- `stroke.point_count <= MAX_POINTS_PER_STROKE` (user drawing)
- Canvas serialization output fits within token budget
- Mouse coordinates within canvas bounds before conversion
- Point counts within `PointPool` capacity

---

## Milestone Summary

| Milestone                    | Phases        | Key Deliverable                              |
| ---------------------------- | ------------- | -------------------------------------------- |
| **v0.2 — Persistent Canvas** | 1.1, 1.2, 1.3 | Accumulates across turns, scrubber, undo     |
| **v0.3 — Etch-a-Sketch**     | 2.1, 2.2, 2.3 | User draws on canvas, AI sees and responds   |
| **v0.4 — Diagram Ready**     | 3.1, 3.2, 3.3 | Arrows, curves, polylines — real diagrams    |
| **v0.5 — Smart Canvas**      | 4.1, 4.2, 4.3 | Named objects, spatial queries, mutation     |
| **v0.6 — Lessons**           | 5.1, 5.2, 5.3 | Structured learning flows, quizzes, progress |
| **v1.0 — Polish**            | 5.4, 6.x      | Export, streaming, animation, multi-canvas   |

### Quick Start

Phase 1.1 is a one-line change (remove `clearCanvas()` from
`applyCanvasResult`). Phase 2.1 uses the proven `canvas_drawing.zig` pattern
with `on_click_handler` + `on_event` for `mouse_dragged`. Both ship without
any Gooey framework modifications.
