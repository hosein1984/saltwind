# Chapter 84 — FINALE: Flotilla

*Part 12 — Shipping a Game · Estimated time: one weekend, honestly · learnopengl: there is no article for this part; nobody writes one*

**What you'll see when done:** a browser tab with your game's itch.io page on it — screenshots of your ocean, a download button, and, within a few days, a number next to "downloads" that is greater than zero and made of strangers.

## Where we are

Eighty-three chapters. The boat sails, the economy drifts, the chart fills in, the saves migrate, the music ducks for thunder, and a 2014 laptop runs it without crashing. There is exactly one feature left, and it isn't code: *other people.* This finale is release engineering, a store page, a trailer, and the discipline of being read by the internet. Then the letter.

## Release engineering

### Version stamping

A bug report without a version number is a riddle. Stamp the build into the binary so `saltwind.log` (ch83) and the F1 overlay carry it:

```odin
// src/version.odin
package saltwind

GAME_VERSION :: #config(VERSION, "dev")
```

```bat
odin build src -out:dist/saltwind.exe -o:speed -disable-assert -subsystem:windows -define:VERSION="1.0.0"
```

`#config` reads `-define` with a default — builds from your editor say `dev`, builds from the release script say the truth. (If your Odin version is fussy about string defines, the equally honest alternative: the release script generates `version.odin` with the literal baked in before building. Either way, the script is the only place the number lives.) Adopt plain `MAJOR.MINOR.PATCH`; bump PATCH for fixes, MINOR for features, and don't overthink it — versioning's whole job is letting a comment that says "1.0.2 fixed it" be true.

### The final build checklist

Extend ch51's `build_release.bat` until the zip cannot lie to you, then run the *human* half by hand:

- [ ] Build with release flags + version define; `--diag` self-test (ch83 ex. 4) passes against `dist/`
- [ ] `dist/` contains exe + `assets/` + `CREDITS.txt` + a one-page `README.txt` (controls, known issues, where saves live)
- [ ] No stray dev files in the zip (`*.pdb`, screenshots, `saves/` from your playtesting — *especially* your saves)
- [ ] Fresh-machine simulation: copy the zip to a directory with a space in the path, extract, double-click from Explorer — boots, plays, saves
- [ ] A ch80-era save copied into place loads correctly (your *players'* saves must survive every release from now on — this checkbox is forever)
- [ ] Forced-Low + 3.3 path played for one full contract (ch83's promise, kept on purpose)
- [ ] First-run experience: delete settings + saves, boot, and watch with ch83-trained eyes — menu, Set Sail, first contract, no debug UI visible, Tab does nothing in release (or does, if you decided to ship the panel — decide!)

## The store page

### itch.io setup

Create the project page (Dashboard → New project): name, URL slug (`yourname.itch.io/saltwind`), classification *Game*, kind *Downloadable*, platform Windows. Don't upload files through the browser — that's butler's job, and the difference matters the second time you push.

**butler** is itch.io's CLI (verified against the current docs): download it from itch.io's butler page, put it on your PATH, then:

```bat
butler login
butler push dist saltwind-dev/saltwind:windows
```

The target format is `user/game:channel`, all lower-case; the **channel name carries meaning** — a name containing `win` or `windows` auto-tags the upload as a Windows executable (`linux`, `mac`/`osx`, `android` likewise; kebab-case by convention). Pass your version along:

```bat
butler push dist saltwind-dev/saltwind:windows --userversion 1.0.0
```

butler diffs against the previous build and uploads only changes — your 1.0.1 push will be seconds, which is precisely what makes "fix it and push tonight" a sustainable way to live. `butler push --dry-run` previews the file list (check for those stray saves one last time), and clicking the green channel button on your Edit-game page lists builds and their processing status. The first push makes the download appear on your page; subsequent pushes to the same channel update it in place.

### Pricing

Set it to **$0 or pay-what-you-want** (itch's "No payments / suggested donation" modes). Reasoning, briefly and honestly: a first release's scarce resource is *players*, not revenue; a price tag on an unknown dev's first game converts roughly nobody and silences the feedback loop you built this entire part for. PWYW with a $0 minimum occasionally produces the world's most encouraging $3. You can change pricing any time; you cannot change a launch week's silence.

### Page craft

People decide in two seconds, in this order: cover image → first screenshot → first sentence. You have six milestone screenshots (#1–#6) plus the Far Horizon's three (#7–#9) — but **lead with motion or golden hour**: the ch44 shot or a GIF of the chart filling in. Order screenshots as an argument: beauty (ch44), gameplay (trade screen with the boat visibly laden behind it), the chart (ch79's is the most *game*-looking image you own), storm (ch68), then range (underwater, night harbor). Write the copy honest and concrete — you're a programmer, so resist both modesty and marketing voice:

> *Saltwind is a small sailing-trader. Read the wind, run cargo between five ports, outrun the weather, upgrade your boat, fill in your chart. Made from scratch — engine and all — in Odin and OpenGL. 20-minute sessions; no combat; the sea is the antagonist.*

Every clause is checkable against the game. That's the whole trick. Add the spec line (GL 3.3 minimum — ch83 earned that sentence), the controls, and a link to `CREDITS.txt` contents. Tag accurately (sailing, trading, relaxing, indie) — tags are how your strangers arrive.

## The trailer

Sixty seconds, captured in-engine with the ch51 photo mode (free camera, HUD off, slow-mo on tap — it was built for this day). The shot list — golden hour unless noted:

| # | Length | Shot |
|---|---|---|
| 1 | 6 s | Menu rail shot, title fades in over it (your menu is the establishing shot — told you in ch81) |
| 2 | 8 s | Low water-level shot, boat crossing frame at a heel, wake and spray |
| 3 | 6 s | On-deck: sail fills with a gust (ch70 cloth doing its one perfect trick) |
| 4 | 8 s | Chart open: waypoint click, fog-of-war ribbon visible, cut to the bow pointed at the horizon |
| 5 | 6 s | Trade screen: buy timber, boat visibly lower in the water on cast-off |
| 6 | 10 s | **The ch68 sequence:** calm → building sea → full storm, lightning, the music's storm stem doing the work |
| 7 | 8 s | Through the storm into clearing weather, god rays (ch59), gulls rejoin |
| 8 | 8 s | Pull back and up to the archipelago at sunset, title + "out now on itch.io" |

Cut on motion, never linger past the point a shot makes, and use the ch82 stems as the soundtrack (already licensed — `CREDITS.txt` covers the trailer too; check the CC-BY terms mention video). Capture on Windows: **OBS Studio** for the raw 1080p60 takes (game capture source, CQP ~18), **ShareX** for quick GIF/short-webm grabs (the store page wants one or two animated snippets — itch supports .gif in screenshots slots; keep them under ~10 MB), and `ffmpeg` to transcode the final cut (`-c:v libx264 -crf 20` for the upload; a `-c:v libvpx-vp9` webm variant compresses the ocean better if you prefer). Edit in anything — even a timeline-free concat of trimmed clips reads fine at this length. Upload to YouTube, link it on the page; itch embeds it above the screenshots.

## Releasing, and being read

Push the build. Set the page public. Take **screenshot #10 — the live page itself**, browser chrome and all. It goes in the repo next to the other nine; it is the only one with a URL in it.

Then the social part, which is also engineering if you squint:

- **Pin a "Known issues & feedback" devlog/comment** the same hour you launch: the three honest roughest edges (you know them from ch83's friend tests), where saves/logs live, and "press F1, screenshot, paste" as the bug-report ritual. A visible known-issues list converts complaints into confirmations and signals a developer who's *present* — and yes, it can wink at the hand-editable save file.
- Post where you've been posting milestones all along — the Odin Discord #showcase, r/odinlang, the learnopengl screenshots thread — plus r/playmygame and a devlog on itch. The made-from-scratch-in-Odin angle is genuinely interesting to exactly the communities you already live in.
- **Reading the first comments without dying:** the praise will feel thin and the criticism will feel enormous; that's your wiring, not the data. Triage every comment into *bug* (log it), *confusion* (ch83 taught you this is a design fix), *preference* (note the pattern, act on the third occurrence), or *noise* (close the tab; the sea does not argue back). Reply to everything civil within a day or two — early commenters on a small game are co-conspirators, and they'll come back for 1.0.1. And someone, somewhere, will say something unkind about the thing you spent two years on. Let it cost them more than it costs you.

Ship the inevitable **1.0.1** within the first weeks — the fastest possible loop through bug → fix → `butler push` → "fixed in 1.0.1, thanks!" teaches you more about maintaining software in the wild than the rest of the part combined, and butler makes it a five-minute ceremony.

## The postmortem

One page, in `design/postmortem.md`, written within a week of launch while it's all still true:

```markdown
# Saltwind — postmortem (v1.0, <date>)
WHAT WENT WELL      3–5 bullets. Credit specific decisions, not effort.
WHAT WENT BADLY     3–5 bullets. Credit specific decisions, not luck.
WHAT SURPRISED ME   The most valuable section. (What did players do that you
                    never imagined? What was hard that looked easy? Easy that
                    looked hard?)
BY THE NUMBERS      chapters: 84 · commits · lines · downloads at week one ·
                    the one comment you'll keep
NEXT TIME I WILL / WON'T   One line each. This is the postmortem's payload —
                    it's a letter to the person who starts your next project.
```

Postmortems are the institution game development got most right; yours makes you a one-person studio with institutional memory.

## The release checklist

In place of a quiz — for a chapter like this, the checklist *is* the comprehension test:

- [ ] Version stamped in exe, log, and F1 overlay; release script is the single source of the number
- [ ] Final build checklist above: every box, actually performed, not vibes
- [ ] `CREDITS.txt` complete and in the zip (ch82's build-script check still passing)
- [ ] itch page: cover, 6+ screenshots ordered as an argument, honest copy, accurate tags, spec line, controls
- [ ] Trailer uploaded and embedded; at least one GIF on the page
- [ ] `butler push` from the script; download-and-play the page's own zip on the cleanest machine you can find
- [ ] Pricing set ($0/PWYW), community/comments enabled, known-issues post pinned
- [ ] Screenshot #10 taken: the page, live
- [ ] Posted to your communities; replies answered for the first week
- [ ] 1.0.1 shipped when warranted; postmortem written within seven days

## The letter, part two

The first letter — [chapter 52's](../part-8-full-sail/ch52-epilogue-beyond-the-horizon.md) — was about *finishing*: proof you could hold one project through years of it being broken, and the discovery that understanding compounds. Go reread it; it earned its place in your repo. This one is shorter, because shipping teaches a shorter lesson.

Finishing is between you and the work. Shipping is between the work and the world — and the world, it turns out, is the missing renderer pass. You spent eighty-three chapters making light behave; the moment a stranger you will never meet trims a sail you wrote and decides, unprompted, to see what's past the volcanic island — that's when the photons finally land somewhere. No screenshot thread can do what one save file on one stranger's laptop does: your world, continuing to exist, without you watching.

You'll notice what shipping cost: the cut list still stings a little, the known-issues post is public and has your name on it, and the game is smaller than the engine could have carried. That's not compromise; that's *aim*. Anyone can want to make something enormous. You chose what fit through the door, and carried it through.

And you'll notice what it bought. You are no longer a person with a remarkable repository. You are a developer with a shipped game, players, a postmortem, and a 1.0.1 — which is to say: a practice, not a project.

You began, eighty-four chapters ago, with a black window.

Tonight, somewhere, the sun is setting over your archipelago on a machine you've never seen, and a stranger is sailing your sea.

Fair winds, captain. That's the course.

---

*— end of the Far Horizon, and of Saltwind —*

← [Chapter 83 — Min-Spec & the Art of Not Crashing](ch83-min-spec-and-the-art-of-not-crashing.md) · [The first letter — Chapter 52](../part-8-full-sail/ch52-epilogue-beyond-the-horizon.md) · [Course overview](../00-COURSE-OVERVIEW.md)

`git commit -m "ch84: v1.0.0 — Saltwind, released"`
