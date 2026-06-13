# Chapter 95 — Two Sails, One Sea

*Part 14 — A Crowded Sea · Estimated time: 6–8h · learnopengl: no direct equivalent — networking material; Glenn Fiedler's "Gaffer on Games" series is the canonical source*

**What you'll see when done:** a friend's boat on your ocean — heeling on the same gust, lifting on the same swell that lifts you, racing you into Kelpmouth for the same timber spread — over a connection that sends a few hundred bytes a second.

## Where we are

Every chapter since 91 has crowded the sea with company you built. This one crowds it with company you *invited*. Co-op multiplayer is the chapter most courses refuse to write, because networking a simulation is famously a swamp — but you've been draining this swamp since ch10 without knowing it. The fixed timestep made simulation a pure march of identical steps. ch28's discipline put the wave math in exactly one table evaluated identically everywhere. ch62 seeded the spectrum from the world seed, and ch63 evolves it by `e^{iωt}` from *absolute* `sim_time` — not by accumulating anything. Hold those three facts together and the famous problem of this chapter — "how do you possibly send an ocean over the internet?" — falls apart before it forms. You don't. That insight does about 80% of the work; `vendor:ENet` does 15%; this chapter is the remaining 5%, plus the two genuinely new ideas (snapshot interpolation and authority) that every networked game ever shipped is built from.

## Concepts

### Don't sync the ocean

The centerpiece, stated plainly: **your ocean is a pure function of `(seed, sim_time)`.** The Phillips spectrum is generated from the world seed (`rand.reset` in ch62 — same seed, same 131,072 dice). The time evolution multiplies by `e^{iωt}` where `t` is `sim_time` itself — there is no integration, no per-frame state, no history. Hand two machines the same seed and the same clock and they will compute *bit-for-bit the same sea*, forever, without exchanging a single byte about it. Gerstner (ch28), the FFT cascade (ch63), whitecaps (ch64) — all of it, free.

The practical payoff is even better than bandwidth: you never send a boat's height. The state packet carries XZ position only, and each machine floats the remote hull with its own ch32 buoyancy on its own ocean — which is *the same ocean*. The remote boat doesn't replay her waterline; she genuinely rides your waves, spray and heel and all, because determinism made "your waves" and "her waves" the same object. This is the single biggest architectural dividend in the course, and you paid for it in chapters 10, 28, and 62 without being told why. Now you're told why.

One sharp distinction keeps you honest about what *does* need syncing. The ocean is a pure function of time. The **economy and the captains are not** — they accumulate rng draws and trade history step by step, so two machines computing them independently would drift apart at the first divergent tick. Pure-function state: recompute locally. Accumulated state: one machine owns it. That sentence is the entire theory of this chapter's architecture.

### Listen-server, and who owns what

No dedicated server — one player **hosts** (their game *is* the server, hence "listen-server") and one joins. The host's simulation is the truth for everything accumulated: the economy, the captains, the weather rolls. The client owns exactly one thing — their own boat — and *reports* it; everything else they either recompute (ocean) or receive (markets, fleet). When the client wants to trade, they don't touch their local stock numbers: they send a **trade RPC** to the host, the host runs the same `market_trade` everyone else uses (ch94 made it unfoolable on purpose — that pitfall was this chapter knocking), and the result comes back. Latency on a dock transaction is unnoticeable; latency on a boat is the next section.

### Snapshot interpolation: render the past

State packets arrive at 10–20 Hz, jittered by the network. Render the remote boat at the newest packet and she teleports four times a second. Extrapolate forward and she overshoots every turn, then snaps back. The classic answer — Fiedler's, Valve's, everyone's — is to keep a short **buffer of timestamped snapshots** and render the remote boat about 100 ms *in the past*, interpolating between the two snapshots that straddle the render time:

```
 host's boat, live ──────────────────────────────────────▶ time
 snapshots sent:        s1       s2       s3       s4        (15 Hz, ~66 ms apart)
                        │        │  jitter │       │
 arrive at client:      s1        s2        s3        s4
                                              ▲
 client renders at:  ──────────────────────── t = now − 100 ms
                     t always lands BETWEEN two snapshots already
                     in hand → interpolate, never guess
```

The 100 ms delay buys you certainty: by the time you need to draw the boat at time *t*, the snapshots bracketing *t* have already arrived (even one drop just widens an interpolation interval — the curve stays smooth). You trade a tenth of a second of freshness for motion that never lies. For a sailboat — no hitscan weapons, no twitch dodges — this trade is free; nobody can perceive that your friend's hull is 100 ms behind her keyboard, but everyone perceives teleporting.

To know *which* past, you need the two clocks related. A full NTP dance is overkill; a serviceable **clock-offset estimate** is one line per packet: each state packet carries the sender's `sim_time`; on receipt, `offset ≈ pkt.sim_time + rtt/2 − my_sim_time` (ENet measures `rtt` for you, continuously). Smooth it with an EMA and the estimate is stable to a few milliseconds — far better than the 100 ms cushion needs.

### Channels: reliable where it matters, cheap where it doesn't

ENet's gift is per-packet delivery semantics on one UDP socket. Two **channels**, two policies:

- **Channel 0, events, `{.RELIABLE}`** — handshake, trade RPCs, market updates, weather changes, captain spawns. Must arrive, must be ordered; rare enough that retransmission costs nothing.
- **Channel 1, state, `{.UNSEQUENCED}`** — boat snapshots, 15 times a second. A lost one is *worthless* by the time a retransmit could land — the next one supersedes it — so reliability would be actively harmful (a retransmitted stale snapshot arriving late is how remote boats moonwalk). Unsequenced means no ordering guarantee either; your snapshot timestamps already handle reordering, so let the network be its sloppy self.

Separate channels also stop head-of-line blocking: a lost reliable trade packet stalls channel 0 while it retransmits, but channel 1's snapshots keep flowing past it.

### The join handshake

Connecting mid-session means receiving the world: the host answers a new connection with a **Welcome** on the reliable channel — protocol version (refuse mismatches now, thank yourself later), world `seed`, current `sim_time`, the full per-port stock table (5 ports × 6 goods of `i32` — ~120 bytes; ch94's whole economy fits in a UDP packet, which is what integer coins were for), and the captain roster. The client seeds and regenerates the world exactly as ch80's load path does — same terrain, same ports, same FFT spectrum — sets its clock from the offset estimate, applies the stocks, and is *in*: standing on a sea it computed itself, in a market it was handed.

### NAT, honestly

Over a LAN this works the moment it compiles. Over the open internet, your friend's router will silently eat unsolicited UDP — that's NAT, and the workarounds (hole-punching with a rendezvous server, relays, Steam Datagram Relay) are real engineering with real infrastructure, **out of scope here and named as such**. The honest options that need zero new code: same LAN; the host port-forwards `7777/udp`; or — easiest by far — a virtual LAN like Tailscale or ZeroTier, which does the hole-punching *for* you and hands both machines addresses that just work. Scope your promises to that and every promise in this chapter holds.

## Odin notes

`import enet "vendor:ENet"` — bindings ship with the compiler; on Windows the vendored lib links automatically, on Linux/mac install ENet via your package manager. The API is the C library with C names: `enet.initialize()` once at startup (it returns `i32`, 0 on success — check it), `enet.deinitialize()` at exit, and everything else hanging off `^enet.Host` and `^enet.Peer`. Two ownership rules account for every ENet crash you'll ever write: **a successful `peer_send` takes ownership of the packet** (ENet frees it after delivery — never destroy it yourself; do destroy it if send returns < 0), and **a `.RECEIVE` event lends you `event.packet`, which you must `packet_destroy` when done**. Wire format: both ends are the same binary you compiled, so flat `#packed` structs of fixed-size scalars sent as raw bytes are legitimate — no serialization library, no endianness dance (you are not shipping cross-architecture saves; you're whispering between two copies of the same executable). The one absolute rule: nothing with a pointer in it — no `string`, no slices, no `[dynamic]` — crosses the wire. A pointer is an address in someone else's memory; on arrival it's a war crime.

## Build

1. **The session,** in `src/net.odin`:

   ```odin
   NET_PORT     :: 7777
   NET_CHANNELS :: uint(2)
   CH_EVENTS    :: u8(0)        // reliable: handshake, trades, weather, fleet
   CH_STATE     :: u8(1)        // unsequenced: snapshots

   Net_Role  :: enum u8 { Offline, Host, Client }

   Net_State :: struct {
       role:      Net_Role,
       host:      ^enet.Host,
       peer:      ^enet.Peer,        // the other captain (one is plenty for co-op)
       clock_off: f64,               // host sim_time minus mine, smoothed (client)
       remote:    Snapshot_Buffer,   // step 4
       send_tick: u32,
   }

   net_host :: proc(n: ^Net_State) -> bool {
       if enet.initialize() != 0 do return false
       addr := enet.Address{host = enet.HOST_ANY, port = NET_PORT}
       n.host = enet.host_create(&addr, 1, NET_CHANNELS, 0, 0)   // 1 peer, 2 channels
       if n.host == nil { enet.deinitialize(); return false }
       n.role = .Host
       return true
   }

   net_join :: proc(n: ^Net_State, server: cstring) -> bool {
       if enet.initialize() != 0 do return false
       n.host = enet.host_create(nil, 1, NET_CHANNELS, 0, 0)     // nil address = client
       addr := enet.Address{port = NET_PORT}
       enet.address_set_host(&addr, server)                      // name or dotted IP
       n.peer = enet.host_connect(n.host, &addr, NET_CHANNELS, 0)
       n.role = .Client
       return n.peer != nil
   }
   ```

   Launch plumbing: `saltwind --host` and `saltwind --join 192.168.1.7` via `core:os` args (a lobby UI is an exercise, not a requirement).

2. **The pump.** Once per frame, before the fixed-step loop, with timeout 0 — `host_service` with a timeout *blocks*, and your render loop is not a server's main loop:

   ```odin
   net_service :: proc(n: ^Net_State, g: ^Game) {
       if n.host == nil do return
       ev: enet.Event
       for enet.host_service(n.host, &ev, 0) > 0 {
           switch ev.type {
           case .NONE:
           case .CONNECT:
               if n.role == .Host { n.peer = ev.peer; net_send_welcome(n, g) }
           case .RECEIVE:
               net_handle(n, g, ev.channelID, ev.packet.data[:ev.packet.dataLength])
               enet.packet_destroy(ev.packet)            // ours to free — rule two
           case .DISCONNECT:
               n.peer = nil                              // single-handed again; sail on
           }
       }
   }
   ```

   `net_handle` switches on a leading `Msg_Kind :: enum u8` byte — every message struct below starts with one.

3. **The state packet,** sent every 4th fixed tick (15 Hz at `FIXED_DT = 1/60`):

   ```odin
   Boat_State_Msg :: struct #packed {
       kind:      Msg_Kind,    // .State
       sim_time:  f64,         // sender's clock — doubles as the snapshot timestamp
       pos:       [2]f32,      // XZ only. The sea supplies Y — that's the chapter
       yaw:       f32,
       speed:     f32,
       rudder:    f32,
       sail_trim: f32,
   }

   net_send_state :: proc(n: ^Net_State, g: ^Game) {
       n.send_tick += 1
       if n.peer == nil || n.send_tick % 4 != 0 do return
       m := Boat_State_Msg{.State, g.sim_time, g.boat.position.xz,
                           g.boat.yaw, g.boat.speed, g.boat.rudder, g.boat.sail_trim}
       pk := enet.packet_create(&m, size_of(m), {.UNSEQUENCED})
       enet.peer_send(n.peer, CH_STATE, pk)              // success = ENet owns pk now
   }
   ```

   33 bytes, 15 Hz, both directions: under a kilobyte per second. Rudder and trim ride along not for physics but for *looks* — the remote boat's helm and boom animate from them.

4. **Snapshot buffer + interpolation.** A ring of the last 32 snapshots; on every received `Boat_State_Msg`, push `{t = m.sim_time, …}` and refresh the clock offset:

   ```odin
   rtt := f64(n.peer.roundTripTime) / 1000.0             // ENet keeps this current
   est := m.sim_time + rtt * 0.5 - g.sim_time
   n.clock_off = n.clock_off * 0.9 + est * 0.1           // EMA: jitter-proof in ~a second

   INTERP_DELAY :: 0.1
   t := g.sim_time + n.clock_off - INTERP_DELAY          // "remote now", minus the cushion
   ```

   `snapshot_sample(buf, t)` finds the two entries straddling `t` and lerps position and speed; yaw interpolates through `angle_wrap(b.yaw - a.yaw)` — the seam bug from ch92's pitfalls collects its second victim here if you forget. If `t` is ahead of the newest snapshot (connection hiccup), clamp to the newest and let her glide on last-known speed; never extrapolate the turn.

5. **The remote boat in the world.** A `Boat` like any other: sampled XZ/yaw/speed from step 4, then your existing `boat_update_buoyancy` floats and heels her on the local — identical — ocean, and the ch34 wake and ch36 audio treat her as the real boat she almost is. Stand the two builds side by side on one desk and watch one swell pass under both hulls, on both screens, in agreement. *That's* determinism paying out; take a minute with it. She also enters the COLREGS pass (ch92) so captains give way to your friend like anyone else.

6. **The handshake.** On `.CONNECT`, the host sends `Welcome` on `CH_EVENTS` with `{.RELIABLE}`: protocol version (a `NET_PROTO :: 3`-style constant you bump on every wire change — on mismatch, disconnect with a message, not a desync), `seed: u64`, `sim_time: f64`, `stocks: [NUM_PORTS][NUM_GOODS]i32`, and per-captain `{ordinal: u32, progress: f32, state: u8, at_port, dest_port: i8}`. The client regenerates the world from the seed exactly as ch80's load does, adopts the clock, applies stocks, and rebuilds the captain roster — *names included*, because ch93 derived them from `(seed, ordinal)` and ordinals just arrived. The fleet you both see is one fleet.

7. **Host authority, working.** The client's trade screen stops calling `market_trade` and sends `Trade_Msg :: struct #packed {kind: Msg_Kind, port: i8, good: Good_Id, qty: i32}` on the reliable channel. The host validates (docked there? affordable? in stock?), runs `market_trade`, replies with `{cost, ok, new_stock}`, and the client applies the *result*. Keep client prices honest between trades: the host broadcasts the stock table on `CH_EVENTS` once per sim-minute and after every trade — 120-odd bytes, and the ch94 sparklines on both screens agree. Captains stay host-simulated; the host streams each one's `{ordinal, pos, yaw, progress}` on `CH_STATE` at ~4 Hz, and the client runs them as Coarse-LOD ghosts through the same snapshot machinery as step 4 — one buffer type, three users.

8. **Pause, jointly.** One stray rule with teeth: the host's pause must freeze *both* worlds, or the client sails on across a stopped clock and every offset estimate goes haywire. Send `.Paused`/`.Resumed` as reliable events; the client gates its accumulator on them. (Client pause in co-op just opens the menu without stopping time — the convention every co-op game settles on.)

## Checkpoint

- Two machines, one LAN: the joining player spawns onto the host's world — same islands, same fleet names, same prices — with a sub-second handshake.
- The remote boat sails smoothly through a deliberate 5-second packet drought (yank the cable): glide, not teleport; resume, not snap.
- Both screens show the same swell lifting both hulls; a debug print of `ocean_height_at({0,0})` at the same `sim_time` matches across machines to float precision.
- Client buys 10 timber at Gullhaven: host's sparkline dents within a sim-minute, client's matches on the next broadcast, and the watchdog (ch94) shows no coins minted from thin air.
- Host pauses: both worlds freeze, both resume in step. Disconnect mid-sail: the survivor's game continues without a hitch as a solo session.

## Pitfalls

- **The remote boat moonwalks or jitters despite the buffer.** You're driving interpolation time from wall clock or raw `m.sim_time` instead of `g.sim_time + clock_off − INTERP_DELAY`, or you sent state `{.RELIABLE}` — retransmitted stale snapshots arriving out of phase are *worse* than drops. Unsequenced, always, for state.
- **Crash (or heap corruption) seconds after connecting.** Ownership rules, both directions: you destroyed a packet after a successful `peer_send` (ENet frees it — double free), or never destroyed `event.packet` after `.RECEIVE` (leak that ends in mystery). Grep your code for both names and audit every site.
- **The oceans disagree.** Someone evaluates waves at accumulated frame time instead of absolute `sim_time`, or a stray bare `rand.float32()` (context rng, not the seeded one) snuck into spectrum or world gen — ch94's determinism audit just became a two-machine contract. The FFT itself can't drift: `e^{iωt}` has no memory.
- **Everything works on `localhost`, nothing works across the room.** Firewall eating `7777/udp` (Windows Defender prompts on first listen — players miss it), or you tested with the loopback address on both ends. Test on two physical machines early; `localhost` has zero latency, zero loss, and zero NAT, which is to say zero information.
- **A struct arrives as garbage.** Missing `#packed` (field padding differs from your mental layout), a `string` or slice smuggled into a message, or the two builds are different versions — which is why `Welcome` carries `NET_PROTO` and why you bump it every time the wire format moves.
- **Trades occasionally double-apply on the client.** The client applied its *request* optimistically and then also applied the host's broadcast. One authority, one application: the client's market state changes only on messages from the host, including for its own trades.

## Exercises

1. **A bad-day simulator:** wrap `net_send_state` in a debug-keyed delay queue adding 150 ms ± 50 ms of jitter and 5% drop. Tune `INTERP_DELAY` against it and watch the buffer absorb what would have been chaos — then try `{.RELIABLE}` state packets under the same conditions and watch the moonwalk this chapter warned about.
2. **Signal flags:** a tiny chat — Enter opens a one-line input (ch48 text), sends a fixed `[120]u8` message on the reliable channel, shows it over the sender's boat for 6 seconds. Co-op without "nice gybe" is incomplete.
3. **Spectate the fleet:** when docked, Tab cycles your camera through the host-streamed captains. You already have their snapshots; this is one camera mode and a name label, and it turns the fleet into television.
4. **Stretch: four sails.** Raise `peerCount` in `host_create`, keep a `[dynamic]` of peers and remote boats, and replace `peer_send` with `host_broadcast` for state. The architecture barely notices — which is the sign it was right — until you meter upstream bandwidth at N players and discover why real games send deltas. Measure it, write the number in a comment, and leave delta compression for another life.

## Commit

`git commit -m "ch95: ENet co-op — deterministic shared ocean, snapshot interpolation, host-authoritative economy"`

← [Chapter 94 — The Invisible Hand, Visible](ch94-the-invisible-hand-visible.md) · [Chapter 96 — MILESTONE: A Crowded Sea](ch96-milestone-a-crowded-sea.md) →
