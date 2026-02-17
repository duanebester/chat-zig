# Chat-Zig Market Research

> Last updated: July 2025

---

## Executive Summary

Chat-zig occupies a whitespace at the intersection of **AI tutoring**, **visual learning**, and **interactive canvas tools**. No existing product combines an AI that draws while it teaches with a bidirectional canvas where the user draws back. The AI in Education market is projected to grow from **$2.21B (2024) to $5.82B by 2030** at 17.5% CAGR, with generative AI and content generation tools as the fastest-growing segments. The visual learning niche within this market is underserved — incumbents are either text-only (Khanmigo), pre-authored (Brilliant), or watch-only (3Blue1Brown). Chat-zig's unique position: **"What if 3Blue1Brown was interactive and powered by AI?"**

**Go-to-market strategy: Mac-first.** High-end private schools, well-funded STEM programs, and university departments overwhelmingly run Macs. These are also the customers with the highest willingness to pay and the shortest sales cycles. Gooey's native macOS/Metal renderer delivers a premium experience that signals quality and justifies premium pricing. Web (WASM/WebGPU) expands reach later once the product is validated — it's the scale vehicle, not the launch vehicle.

---

## Market Size & Growth

### AI in Education (Global)

| Metric                      | Value         | Source                    |
| --------------------------- | ------------- | ------------------------- |
| Market size (2024)          | $2.21 billion | MarketsandMarkets TC 6243 |
| Market size (2030)          | $5.82 billion | MarketsandMarkets TC 6243 |
| CAGR (2024–2030)            | 17.5%         | MarketsandMarkets TC 6243 |
| North America share (2024)  | 43%           | MarketsandMarkets TC 6243 |
| N. America CAGR (2024–2030) | 15.9%         | MarketsandMarkets TC 6243 |

### Fastest-Growing Segments

| Segment                  | CAGR                        | Why it matters for Chat-zig                           |
| ------------------------ | --------------------------- | ----------------------------------------------------- |
| Content generation tools | 19.1%                       | AI generating visual content = our core value         |
| Generative AI technology | Highest among tech segments | Our comptime tool schema feeds generative AI directly |
| Personalized learning    | 34.5% market share (2024)   | Visual explanations adapt to what the user asks/draws |
| K-12 end users           | Largest segment             | Visual learning is critical for younger students      |
| EdTech companies         | Fastest-growing end user    | Opportunity to license/embed the canvas component     |
| Asia Pacific             | Fastest-growing region      | Long-term expansion via WASM web deployment           |

### Adjacent Markets

| Market                             | Size                                                        | Relevance                                      |
| ---------------------------------- | ----------------------------------------------------------- | ---------------------------------------------- |
| Intelligent Tutoring Systems       | Subset of AI in Ed, growing rapidly                         | Chat-zig is an ITS with a visual canvas        |
| Online Tutoring                    | ~$10B+ globally                                             | Visual tutoring is premium-priced vs text-only |
| Digital Whiteboard / Collaboration | ~$6B by 2028                                                | Canvas tools crossing into education           |
| STEM Education                     | ~$100B globally                                             | Visual/spatial reasoning is critical for STEM  |
| Apple in Education                 | ~30% US tablet market, dominant in private/independent K-12 | Mac labs + iPads = our launch market           |

---

## Competitive Landscape

### Direct Competitors

#### 1. Khanmigo (Khan Academy) — AI Tutor, Text-Only

| Attribute              | Detail                                                                                                                                              |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| **What it does**       | GPT-4-based chatbot for math, science, humanities, coding                                                                                           |
| **Price**              | $4/month (students), free for teachers (Microsoft partnership)                                                                                      |
| **Scale**              | ~65,000 students across 53 school districts (pilot, March 2024)                                                                                     |
| **Strengths**          | Khan Academy brand trust, free for teachers, massive content library                                                                                |
| **Weaknesses**         | **Text-only — no visual canvas**. WSJ testing found basic calculation errors. No drawing, no diagramming, no spatial reasoning support              |
| **Funding**            | Non-profit, backed by Gates Foundation, Google ($2M), Musk ($5M), Microsoft                                                                         |
| **Chat-zig advantage** | We draw. They don't. For any topic requiring spatial understanding (geometry, physics, biology, data structures), a visual canvas is transformative |

**Key insight:** Khanmigo validates the AI tutor market but leaves the entire visual/spatial learning dimension unaddressed. Khan Academy's origin was literally Sal Khan drawing on an electronic blackboard — Khanmigo lost that DNA.

#### 2. Brilliant.org — Interactive Problem Solving

| Attribute              | Detail                                                                                                                                                                |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **What it does**       | Step-by-step interactive lessons in math, CS, data, science                                                                                                           |
| **Price**              | Freemium, ~$25/month premium                                                                                                                                          |
| **Scale**              | 10M+ learners worldwide, 100K+ 5-star app reviews                                                                                                                     |
| **Strengths**          | Beautiful pre-authored interactive visualizations, gamification, strong retention                                                                                     |
| **Weaknesses**         | **Visuals are pre-authored, not AI-generated**. Fixed lesson paths. Can't ask "draw me a binary tree" and get a custom visual. Content creation is expensive and slow |
| **Chat-zig advantage** | Our AI generates visuals on demand for any topic. Brilliant needs human authors to create each lesson; we need one prompt                                             |

**Key insight:** Brilliant proves that "learn by doing" with visuals works and people will pay $25/month for it. Their bottleneck is content creation — every visualization is hand-authored. AI-generated visuals remove that bottleneck entirely.

#### 3. 3Blue1Brown (Grant Sanderson) — Animated Math Videos

| Attribute              | Detail                                                                                                                                                        |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **What it does**       | YouTube channel with animated math visualizations using Manim engine                                                                                          |
| **Price**              | Free (YouTube ad-supported)                                                                                                                                   |
| **Scale**              | 6M+ YouTube subscribers, hundreds of millions of views                                                                                                        |
| **Strengths**          | Extraordinarily compelling visual explanations, massive cultural impact, proves that "seeing math" changes understanding                                      |
| **Weaknesses**         | **Watch-only, not interactive**. Fixed content. Can't ask questions. Can't draw back. Can't explore at your own pace                                          |
| **Chat-zig advantage** | We're interactive 3Blue1Brown. The playback scrubber mimics video playback, but users can pause, ask questions, draw their understanding, and get AI feedback |

**Key insight:** 3Blue1Brown is proof-of-concept that visual math explanation is massively demanded. The gap is interactivity — you can't pause a 3b1b video and say "wait, draw that again but for a different function." Chat-zig can.

### Adjacent / Inspirational Products

#### 4. tldraw "Make Real" — Canvas + AI Code Generation

| Attribute        | Detail                                                                                                                                                                                                                                            |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **What it does** | Draw a UI sketch on a canvas → GPT-4V generates working HTML/CSS                                                                                                                                                                                  |
| **Viral moment** | 10,000+ GitHub stars in 2 weeks (Nov 2023)                                                                                                                                                                                                        |
| **Key insight**  | **"Canvas as conversation space"** — the canvas becomes a bidirectional medium where human and AI iterate together. tldraw's Steve Ruiz: "The canvas is transformed into a conversation space where you and the AI can workshop an idea together" |
| **Relevance**    | Proves the human↔AI canvas paradigm is compelling and viral. tldraw did it for UI code; Chat-zig does it for learning                                                                                                                             |

#### 5. Napkin.ai — Text to Visual Diagrams

| Attribute        | Detail                                                                                                                     |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------- |
| **What it does** | Paste text → generates infographics, diagrams, flowcharts                                                                  |
| **Price**        | Free tier + paid plans                                                                                                     |
| **Strengths**    | Beautiful output, 60+ languages, export to PPT/PNG/PDF/SVG                                                                 |
| **User quotes**  | School administrators: "invaluable for teaching"; Design professor: "such a gem"                                           |
| **Weaknesses**   | **No learning loop**. Generates a static visual, not an interactive lesson. No AI tutor, no quiz, no back-and-forth        |
| **Relevance**    | Shows demand for AI-generated educational visuals. Chat-zig goes further — our visuals are part of a teaching conversation |

#### 6. Duolingo — Gamified Language Learning

| Attribute        | Detail                                                                                                                                                  |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **What it does** | AI-powered language learning with gamification                                                                                                          |
| **Scale**        | $7B+ market cap, identified as "Star" player in AI education                                                                                            |
| **Key lessons**  | Daily streak mechanics drive retention. Bite-sized lessons (5 min). Aggressive gamification. Free tier + $7/month subscription. Mobile-first            |
| **Relevance**    | Gold standard for EdTech retention loops. Chat-zig should study their engagement patterns: daily streaks, XP, leaderboards, bite-sized lesson structure |

#### 7. Excalidraw — Open-Source Whiteboard

| Attribute        | Detail                                                                                                                                                                                        |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **What it does** | Free, open-source virtual whiteboard with hand-drawn style                                                                                                                                    |
| **Scale**        | 100K+ GitHub stars, widely used in tech/education                                                                                                                                             |
| **Relevance**    | Shows massive demand for simple, accessible canvas tools on the web. The "hand-drawn" aesthetic is beloved. Excalidraw is WASM-based — validates web canvas as a viable distribution strategy |

### Competitive Matrix

| Capability                | Khanmigo   | Brilliant    | 3Blue1Brown       | tldraw       | Napkin        | **Chat-zig**     |
| ------------------------- | ---------- | ------------ | ----------------- | ------------ | ------------- | ---------------- |
| AI tutor (conversational) | ✅         | ❌           | ❌                | ❌           | ❌            | **✅**           |
| AI-generated visuals      | ❌         | ❌           | ❌ (pre-authored) | ✅ (UI code) | ✅ (diagrams) | **✅**           |
| Interactive canvas        | ❌         | ✅ (fixed)   | ❌                | ✅           | ❌            | **✅**           |
| User can draw back        | ❌         | ❌           | ❌                | ✅           | ❌            | **✅ (roadmap)** |
| Step-by-step playback     | ❌         | ✅ (fixed)   | ✅ (video)        | ❌           | ❌            | **✅ (roadmap)** |
| Real-time drawing         | ❌         | ❌           | ❌                | ❌           | ❌            | **✅ (roadmap)** |
| Quiz / assessment         | ✅         | ✅           | ❌                | ❌           | ❌            | **✅ (roadmap)** |
| Web accessible            | ✅         | ✅           | ✅                | ✅           | ✅            | **🔜 (WASM)**    |
| Free tier                 | ❌ ($4/mo) | ✅ (limited) | ✅                | ✅ (BYOK)    | ✅            | **TBD**          |

**Chat-zig is the only product that checks ALL boxes.** No one else combines AI tutoring + AI-generated visuals + interactive canvas + user drawing + playback.

---

## Target Market Analysis

### Primary Target: Mac-Equipped STEM Students & Schools

| Characteristic         | Detail                                                                                                                                                         |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Who**                | Students at private/independent schools, well-funded public STEM programs, and university CS/science/engineering departments — overwhelmingly Mac environments |
| **Pain point**         | "I can't visualize this concept" — spatial reasoning is the #1 barrier in STEM                                                                                 |
| **Current solutions**  | YouTube videos (passive), textbook diagrams (static), ChatGPT (text-only), tutoring ($40-80/hr)                                                                |
| **Willingness to pay** | $8–20/month for students/parents, $5–10/seat/month for institutions (private schools have discretionary budgets)                                               |
| **Distribution**       | Native macOS app via direct download, teacher word-of-mouth, HN/Twitter demos, education conferences                                                           |

### Why Mac-First STEM?

1. **Visual reasoning is essential.** You cannot learn organic chemistry, vector calculus, tree data structures, or circuit diagrams from text alone
2. **AI + drawing creates the most value here.** An AI that can draw a force diagram, a cell membrane, or a sorting algorithm step-by-step is radically better than text-only tutoring
3. **High-end schools have Macs.** Private/independent schools ($20K–50K+/year tuition), university STEM labs, and well-funded suburban districts run Mac labs. These are the customers most willing to pay and fastest to adopt
4. **Short sales cycles.** A private school department head can try the app Tuesday and purchase 30 seats Thursday. No 12-month district procurement process
5. **Native macOS/Metal = premium experience.** CoreText rendering, native Cmd+Z, system integration, no browser sandbox. This signals quality and justifies premium pricing vs. web-based competitors
6. **Measurable outcomes.** Unlike soft skills, STEM learning gains can be measured with quiz scores — enabling product-market-fit validation
7. **iPad + Apple Pencil is the endgame input device.** "AI draws, student draws back with Apple Pencil" is a demo that sells itself. iPads are widespread in the same schools that have Mac labs

### Secondary Target: Educators / Content Creators (Mac Users)

| Characteristic         | Detail                                                                                                                  |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| **Who**                | Teachers at Mac-equipped schools, private tutors (overwhelmingly use personal Macs), YouTube educators, course creators |
| **Pain point**         | Creating visual lesson content is time-consuming and expensive (hours per diagram)                                      |
| **Value proposition**  | "Generate a visual lesson in 30 seconds instead of 3 hours"                                                             |
| **Willingness to pay** | $20–50/month for individual teachers, enterprise pricing for institutions                                               |
| **Distribution**       | Education conferences (ATLIS for independent schools, NAIS), teacher communities, free educator tier                    |

### Tertiary Target: Developers & Lifelong Learners

| Characteristic   | Detail                                                                                                        |
| ---------------- | ------------------------------------------------------------------------------------------------------------- |
| **Who**          | Software engineers (Mac dominant — ~25% of developers), adults learning new skills, curiosity-driven learners |
| **Pain point**   | Want to understand complex topics visually without enrolling in a course                                      |
| **Comparable**   | Brilliant.org's core audience                                                                                 |
| **Distribution** | Hacker News, Reddit, Twitter/X, YouTube demos. This audience already has Macs and Anthropic API keys (BYOK)   |

---

## Market Trends Supporting Chat-zig

### 1. Generative AI in Education is the Fastest-Growing Segment

The MarketsandMarkets report identifies generative AI as the fastest-growing technology segment in AI education. Chat-zig's comptime-generated tool schema means the AI's drawing vocabulary expands automatically as new `DrawCommand` variants are added — zero manual schema maintenance.

### 2. Content Generation Tools Growing at 19.1% CAGR

AI that creates educational content (visuals, quizzes, lessons) is the fastest-growing software category. Chat-zig's AI generates visual content in real-time — each conversation produces a unique, personalized visual lesson.

### 3. "Canvas as Conversation" Paradigm is Proven Viral

tldraw's "Make Real" experiment (10K GitHub stars in 2 weeks) proved that people are excited about AI-canvas interaction. Chat-zig applies the same paradigm to education — a higher-value, stickier use case than UI prototyping.

### 4. The "Visual AI Tutor" Gap

| What exists                                            | What's missing                                  |
| ------------------------------------------------------ | ----------------------------------------------- |
| AI tutors (text-only): Khanmigo, ChatGPT               | AI tutors that draw                             |
| Visual learning (pre-authored): Brilliant, 3Blue1Brown | Visual learning generated on demand             |
| AI diagram generators: Napkin, Mermaid                 | AI diagrams embedded in a teaching conversation |
| Interactive whiteboards: Excalidraw, tldraw            | Teaching-aware whiteboards                      |

Chat-zig fills the center of this Venn diagram.

### 5. Khan Academy's Origin Story is Chat-zig's Thesis

Sal Khan started by drawing on a virtual blackboard while tutoring his cousin. Those doodle-while-explaining videos became a $30M/year nonprofit serving millions. Khanmigo (their AI product) dropped the visual component entirely — it's text-only chat. **Chat-zig is reclaiming the original Khan Academy magic with AI.**

---

## Monetization Strategy

### Pricing Model: Native Mac App — Freemium + BYOK

| Tier                   | Price                     | What you get                                                                                  |
| ---------------------- | ------------------------- | --------------------------------------------------------------------------------------------- |
| **Free (BYOK)**        | $0 + user's own API key   | Full canvas, unlimited conversations, user pays Anthropic directly. Native macOS app download |
| **Starter**            | $12/month                 | Bundled API credits (~100 conversations/month), lesson library, progress tracking             |
| **Pro**                | $20/month                 | Unlimited conversations, lesson authoring, export/save, priority models                       |
| **Education**          | $8/student/month (volume) | Classroom seat management, pre-built STEM lesson packs, teacher dashboard                     |
| **Education (annual)** | $60/student/year          | Same as above, discounted for annual school budgets                                           |

Note: Pricing reflects the premium-school market. Private school parents spend $20K–50K/year on tuition — $8/month for an AI visual tutor is a rounding error. This is not a race-to-the-bottom consumer app.

### Why BYOK as Free Tier?

1. **Zero marginal cost** — users pay Anthropic directly, we have no API bill
2. **Proven model** — tldraw's "Make Real" launched this way and went viral
3. **Developer/early-adopter friendly** — the Hacker News audience already has Macs and API keys
4. **Funnel to paid** — once hooked, students/parents prefer not to manage API keys
5. **Native Mac app signals quality** — a .app download feels premium vs. a browser tab

### Revenue Projections (Conservative, Mac-First)

| Milestone           | Timeline    | Users                                              | Revenue (MRR) |
| ------------------- | ----------- | -------------------------------------------------- | ------------- |
| Launch (BYOK only)  | Month 1–3   | 500–2,000 free (devs, HN)                          | $0            |
| Paid tier launch    | Month 4–6   | 3,000 free / 150 paid                              | $2,400        |
| First school pilots | Month 6–9   | 5,000 free / 500 paid + 2 school pilots (60 seats) | $7,500        |
| Growth              | Month 9–15  | 10,000 free / 1,500 paid + 10 schools (500 seats)  | $22,000       |
| iPad launch + web   | Month 15–24 | 30,000 free / 5,000 paid + 30 schools              | $65,000       |

### Unit Economics

| Metric                                     | Estimate                       |
| ------------------------------------------ | ------------------------------ |
| CAC (organic)                              | ~$0 (viral/content-driven)     |
| CAC (paid, if needed)                      | $5–15 per user                 |
| LTV (Starter, 6-month avg retention)       | $72                            |
| LTV (Pro, 8-month avg retention)           | $160                           |
| LTV (Education seat, 10-month school year) | $60–80/student                 |
| LTV/CAC ratio                              | >3x at organic, >3x at paid    |
| School deal size                           | $480–$4,800/year (10–60 seats) |

---

## Distribution Strategy

### Phase 1: Native Mac App — Developers & Early Adopters (Month 1–3)

| Channel         | Action                                                                       | Expected outcome                                                                  |
| --------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| **Hacker News** | "Show HN: AI tutor that draws while it teaches (native Mac, built with Zig)" | 5K–50K visits. Zig + Metal angle is novel and HN-friendly. This audience has Macs |
| **GitHub**      | Open-source the client, BYOK model, `brew install chat-zig`                  | Stars, contributors, trust                                                        |
| **Twitter/X**   | 30-second screen recordings of the AI drawing on macOS                       | Viral potential (tldraw's demo videos were massively shared)                      |
| **Reddit**      | r/programming, r/learnmath, r/compsci, r/zig                                 | Targeted technical audience, Mac-heavy                                            |

### Phase 2: Mac-Equipped Schools & Teachers (Month 3–9)

| Channel                         | Action                                                           | Expected outcome                                             |
| ------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------ |
| **Independent school networks** | Direct outreach to STEM department heads at NAIS member schools  | Private schools buy fast — one champion teacher = 30 seats   |
| **ATLIS / NAIS conferences**    | Demo at Association of Technology Leaders in Independent Schools | These are Mac-first school IT leaders                        |
| **YouTube**                     | "Watch an AI teach the water cycle by drawing it"                | Evergreen discovery, demonstrates product magic              |
| **Teacher communities**         | Free educator accounts, share pre-built lesson packs             | Teacher-to-student distribution (one teacher = 30+ students) |
| **Tutoring centers**            | Partner with Kumon, Mathnasium, private tutors (Mac users)       | Tutors become evangelists, use in 1:1 sessions               |

### Phase 3: iPad App + Expansion (Month 9–18)

| Channel                            | Action                                                                               | Expected outcome                                                                   |
| ---------------------------------- | ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| **iPad app**                       | Same Metal backend, Apple Pencil support for "draw back"                             | iPads are huge in education; Apple Pencil is the perfect input for student drawing |
| **App Store**                      | Apple features education apps prominently; "AI + Apple Pencil" is a compelling story | App Store editorial feature potential                                              |
| **University CS/STEM departments** | Outreach to departments with Mac labs (CS, design, engineering, biology)             | Land-and-expand within universities                                                |
| **Education conferences**          | ISTE, ASU+GSV — now with iPad demo                                                   | Decision-maker access with a polished cross-device story                           |

### Phase 4: Web (WASM/WebGPU) — Scale Vehicle (Month 18+)

| Channel                | Action                                                  | Expected outcome                                                                            |
| ---------------------- | ------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| **WASM deployment**    | Gooey's WebGPU target for Chrome/Edge browsers          | Expand beyond Mac-only schools. WebGPU coverage will be broader by then (~80%+ Chrome/Edge) |
| **Chromebook schools** | Free tier for public school districts                   | Volume play after product is validated and revenue established                              |
| **Embeddable widget**  | Teachers embed lesson canvases in Google Classroom, LMS | Reduce adoption friction for web-first schools                                              |

### Why Mac-First Wins

- **Premium market, premium pricing.** Private school parents spend $20K–50K/year on tuition. $8/month for an AI tutor is nothing. Race-to-the-bottom web pricing isn't necessary
- **Native Metal = best experience.** CoreText rendering, system-native Cmd+Z/menus, no browser sandbox overhead. The app _feels_ like it belongs on Mac
- **Short sales cycles.** Private school department heads have discretionary budgets. No 12-month district procurement
- **iPad is the expansion play.** Same Metal backend, Apple Pencil for student drawing. The most natural input device for a visual learning tool
- **Web comes later, from a position of strength.** Validate the product, build revenue, then expand to WASM/WebGPU for Chromebook schools. Don't try to solve distribution and product-market-fit simultaneously

---

## Risks & Mitigations

| Risk                                       | Severity | Mitigation                                                                                                                                                                                                                                                 |
| ------------------------------------------ | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **OpenAI/Anthropic ships a visual canvas** | High     | Move fast. Ship before incumbents. Our native Metal performance + polished Mac experience is a moat. Open-source builds community lock-in                                                                                                                  |
| **Khan Academy adds drawing to Khanmigo**  | High     | Khanmigo is GPT-based text chat embedded in their existing web platform. Adding a real-time native canvas is a massive engineering effort for them. We're canvas-native                                                                                    |
| **Mac-only limits addressable market**     | Medium   | Intentional constraint. High-end schools (our target) have Macs. iPad expansion (same Metal backend) doubles reach. Web/WASM is the Phase 4 scale play once product is validated                                                                           |
| **API costs make freemium unviable**       | Medium   | BYOK free tier has zero API cost. Paid tier margins depend on negotiated API rates. Can switch models (Claude Haiku is cheap)                                                                                                                              |
| **Zig ecosystem is small**                 | Low      | Zig is invisible to users — they see a polished Mac app. It's a feature for us (performance, static allocation) and for HN marketing                                                                                                                       |
| **Education sales cycles are long**        | Medium   | Target private/independent schools first — they buy fast (days, not months). Avoid public district procurement until web tier is ready                                                                                                                     |
| **AI hallucinations in teaching**          | Medium   | Use structured lesson mode where AI follows pre-validated curricula. Canvas serialization lets us verify what's drawn matches expectations                                                                                                                 |
| **Drawing quality isn't good enough**      | Low      | Current 11 primitives (rect, circle, line, text) can teach a surprising amount. Arrows unlock the rest. Perfection isn't required — Khan Academy started with crude doodles                                                                                |
| **WebGPU coverage for future web tier**    | Low      | WebGPU is supported in Chrome/Edge (~78% global). Firefox remains flag-gated but market share is small (~3%). By the time we need web (Month 18+), coverage will be broader. For Chat-zig's 2D canvas, GPU demands are trivial — less than a YouTube embed |

---

## Comparable Exits & Valuations

| Company           | Valuation / Exit                     | Stage  | Relevance                                                                                                                   |
| ----------------- | ------------------------------------ | ------ | --------------------------------------------------------------------------------------------------------------------------- |
| **Duolingo**      | ~$7B market cap (public)             | Mature | Gamified learning. Chat-zig applies similar mechanics to visual STEM                                                        |
| **Brilliant.org** | ~$800M (estimated, private)          | Growth | Interactive STEM learning. Similar positioning but pre-authored content                                                     |
| **Quizlet**       | Acquired for ~$1B (2023)             | Mature | Study tools with AI features. Demonstrates EdTech acquisition appetite                                                      |
| **Course Hero**   | Acquired for ~$1.5B (2021)           | Mature | Homework help platform. Visual explanations were key differentiator                                                         |
| **Photomath**     | Acquired by Google for ~$115M (2022) | Growth | AI that sees math problems via camera. Visual + AI + education                                                              |
| **Khan Academy**  | Non-profit, $30M+ annual revenue     | Mature | Proves visual education at scale. Chat-zig is the for-profit, AI-native successor to the original whiteboard-tutoring model |

---

## Key Insights for Product Strategy

### 1. The "3Blue1Brown but Interactive" Pitch Resonates

Grant Sanderson proved that millions of people want to _see_ math and science. His bottleneck is that every animation takes hours/days to author with Manim. Chat-zig lets _any_ student get a personalized visual explanation in seconds. This is the pitch that will resonate with investors, educators, and users.

### 2. The Playback Scrubber Is the Killer Feature

No competitor has this. When an AI draws a cell diagram in 15 steps, the scrubber lets you replay it as a micro-lesson. This single feature transforms every chat response into reusable educational content. It's also deeply demo-able — 5-second GIF of scrubbing through a diagram is social media gold.

### 3. Teacher Adoption Drives Student Adoption

In K-12, teachers are the distribution channel. One teacher who loves the product brings 30+ students. Khanmigo's Microsoft partnership (free for teachers) proves this model. Chat-zig should have a generous free tier for educators.

### 4. BYOK Launches Fast, Paid Tier Captures Value

tldraw launched with BYOK and went massively viral. It removed all friction — no signup, no payment, just paste your key and go. Chat-zig should do the same. The paid tier exists for people who want convenience (no API key management), bundled credits, and premium features.

### 5. The Comptime Schema Generator Is a Technical Moat

Adding a new drawing primitive to Chat-zig (e.g., `draw_arrow`) requires:

1. Add a variant to `DrawCommand` union
2. Implement `replayOne()` for that variant

That's it. The Anthropic tool schema, JSON parser, and system prompt update automatically via comptime. Competitors using Python/TypeScript must manually maintain schema ↔ renderer ↔ parser consistency. This means Chat-zig can iterate on drawing vocabulary faster than anyone.

### 6. Native Mac Is a Strength, Not a Limitation

The schools most likely to discover, try, and pay for an AI visual tutor are the ones with Macs on every desk. Native macOS/Metal delivers the best possible experience — CoreText rendering, system integration, no browser overhead. This signals quality and justifies premium pricing. The Mac-equipped education market (private schools, universities, tutoring centers) is large enough to build a real business before needing web distribution.

### 7. iPad + Apple Pencil Is the Killer Input Device

The roadmap's Phase 2 (user draws back) becomes transformative on iPad with Apple Pencil. Freehand stroke capture with a stylus is fundamentally better than mouse drawing. iPads with Apple Pencil are widespread in the same high-end schools that have Mac labs. Gooey's Metal backend means the same renderer works on both macOS and iPadOS — the expansion is natural, not a rewrite.

---

## Recommended Product Positioning

### Tagline Options

1. **"An AI tutor that draws while it teaches — and you can draw back."**
2. **"Watch AI explain anything, step by step, on a visual canvas."**
3. **"The visual learning tool that teaches by drawing."**
4. **"3Blue1Brown meets ChatGPT."**

### Positioning Statement

> For STEM students and educators at Mac-equipped schools who struggle to visualize abstract concepts, Chat-zig is a native AI-powered visual tutor that draws real-time diagrams while explaining topics step-by-step. Unlike text-only AI tutors (Khanmigo, ChatGPT) or pre-authored visual courses (Brilliant), Chat-zig generates personalized visual explanations on demand, lets you draw back to demonstrate understanding, and delivers a premium native experience on macOS and iPad.

### Category Creation

Chat-zig doesn't fit neatly into existing categories. It's not just:

- An AI chatbot (it draws)
- A whiteboard (it teaches)
- A video lesson (it's interactive)
- A quiz app (it's generative)

**Proposed category: "Visual AI Tutor"** — own it, define it, be the first result when people search for it.

---

## Summary: Why Now, Why This, Why Us

| Question           | Answer                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Why now?**       | Generative AI capable of using tools (function calling) only became reliable in 2023-2024. The AI in Education market is growing 17.5% CAGR. No incumbent has combined AI tutoring with a real-time visual canvas.                                                                                                                                                                                                       |
| **Why this?**      | Visual learning is the #1 gap in AI education. Every major player (Khan, Brilliant, Duolingo) either has no canvas or has pre-authored-only visuals. The "canvas as conversation" paradigm is proven viral (tldraw).                                                                                                                                                                                                     |
| **Why us?**        | Gooey framework gives us a native macOS/Metal canvas — the best possible rendering for the Mac-dominated premium education market. Comptime schema generation is a technical moat for rapid iteration. Built on Zig — zero runtime overhead, static memory, no GC pauses. Same Metal backend expands to iPad (Apple Pencil) and later to web (WASM/WebGPU). The only team building a visual AI tutor from the canvas up. |
| **Why Mac-first?** | High-end schools have Macs. They pay fast, pay premium, and have the shortest sales cycles. Native app quality signals trust in education. iPad + Apple Pencil is the natural expansion and the ideal input device for bidirectional visual learning. Web is the scale play once the product is proven.                                                                                                                  |

---

## Appendix: Platform Strategy Detail

### WASM/WebGPU Status (for Phase 4 planning)

Gooey's WASM target uses WebGPU (WGSL shaders, `navigator.gpu` API). No WebGL or Canvas2D fallback exists. Current browser support:

| Browser             | WebGPU Status                                    |
| ------------------- | ------------------------------------------------ |
| Chrome 113+         | ✅ Supported                                     |
| Edge 113+           | ✅ Supported                                     |
| Safari 26+          | ◐ Partial                                        |
| Firefox             | ❌ Disabled by default (flag-gated through v150) |
| Chrome Android      | ✅ Supported                                     |
| iOS Safari 26+      | ✅ Supported                                     |
| **Global coverage** | **~78%**                                         |

For Chat-zig's 2D canvas (500×400, rectangles/circles/lines/text), GPU demands are trivial — less intensive than a YouTube embed. The bottleneck is API availability, not GPU intensity. By Phase 4 (Month 18+), coverage will be broader as Firefox ships WebGPU and Safari stabilizes.

### Native macOS/Metal Advantages

| Capability         | Native (Metal)                               | Web (WebGPU)                          |
| ------------------ | -------------------------------------------- | ------------------------------------- |
| Text rendering     | CoreText — best in class                     | Custom glyph atlas, less polished     |
| Performance        | Fastest. Direct GPU, no browser overhead     | Good, but browser sandbox + JS bridge |
| System integration | Cmd+Z, native menus, file system, Spotlight  | Browser-constrained                   |
| Distribution       | .app bundle, `brew install`, direct download | URL (requires WebGPU-capable browser) |
| User perception    | Premium native app                           | "It's a web app"                      |
| iPad expansion     | Same Metal backend, Apple Pencil support     | N/A                                   |

---

## Appendix: Data Sources

1. MarketsandMarkets, "AI In Education Market" (Report TC 6243, Nov 2024) — $2.21B→$5.82B, 17.5% CAGR
2. Wikipedia, "Khan Academy / Khanmigo" — 65K student pilot, $4/month, GPT-4 based
3. Brilliant.org — 10M+ users, interactive STEM learning, ~$25/month premium
4. 3Blue1Brown (about page) — animated math visualization, YouTube, Manim engine
5. tldraw "Make Real" blog post (Nov 2023) — 10K+ GitHub stars in 2 weeks, canvas+AI paradigm
6. Napkin.ai — text-to-visual tool, educator adoption, free tier
7. Duolingo — $7B+ market cap, "Star" player per MarketsandMarkets competitive matrix
8. Wall Street Journal (Feb 2024) — Khanmigo testing found basic math errors
9. Fast Company (Mar 2024) — Khanmigo at 65K students, still learning new skills
10. caniuse.com/webgpu — WebGPU browser support data (~78% global coverage, Chrome/Edge supported, Firefox flag-gated)
11. Gooey `src/platform/web/renderer.zig` — WebRenderer uses WebGPU with WGSL shaders, no fallback
