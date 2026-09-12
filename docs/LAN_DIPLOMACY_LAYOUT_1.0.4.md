# DALA 1.0.4

## LAN

The default listening port is **7777**. The host and guest can change it in
**LAN settings**; it persists between visits and launches. Entering
`192.168.1.20` connects to the configured port. An explicit
`192.168.1.20:8888` overrides the guest's default for that connection. Both
devices must use the same port. Room codes and mod compatibility checks remain
required.

The host shows one primary IP and a separate port. Wi-Fi/hotspot interfaces
rank ahead of Ethernet, virtual/VPN interfaces and loopback. Additional IPs are
collapsed. Copy copies the IP alone. `127.0.0.1` is labelled as usable only on
the host itself; when no LAN address exists the UI explains how to enable the
network. Interface ranking is a preference, not route discovery: an unusual
VPN or multiple simultaneous networks may require an address from the extra
list.

The server binds exclusively. If another room occupies the chosen port, it
reports the failure and suggests changing the setting; it does not silently
choose a random port. Bare IPv4/hostnames, bracketed IPv6, explicit ports and
WebSocket/HTTP URLs share a single validated parser.

## Bot diplomacy

- Recurring expenses use the **entire contract duration**. A payment for six
  turns cannot buy twenty turns of the same subsidy. Renewals replace the old
  obligation, matching the actual settlement rules.
- All land, building, army and naval transfers contribute to a forecast of
  operating income after the exchange. Subsidies and treasury reserves are
  checked against that forecast. Even a free army is rejected if it would
  create a deficit the recipient cannot fund. Incoming promises use the
  payer's sustainable surplus and trust, not their nominal face value.
- Land prices are chosen inside the overlap of seller and buyer valuations.
  A distressed seller can still sell frontier land for useful immediate cash.
  Existing legality checks protect capitals, connected provinces, allied
  ownership and territorial sovereignty.
- War forecasts include sustainable recruitment funded by both cash and
  income, every current enemy front and the target's military coalition.
  Each sovereign is counted once. Independent countries already fighting the
  target contribute discounted support; bribes cannot buy a plainly doomed
  war or an attack on an ally.
- Hard bots can choose a clearly favorable campaign ahead of a small land
  trade. Legal ceasefires, friendship compensation and turn pacing still
  apply.
- Humans receive the same beneficial free pact candidates as bots. Bounded
  partner search reserves consideration for a relevant human even in a crowded
  world. Bilateral contact cooldowns and the two-offer human inbox limit remain
  in force.

These are deterministic strategic estimates, not a guarantee that a bot will
predict every future move. LAN remains host-authoritative. Search retains its
64-plan budget and linear board snapshot; no random behavior or extra full-map
copy is introduced for negotiation.

## Screens

`DalaViewport` continuously scales the application's design coordinates using
both screen dimensions against a 390×640 design reference. Text, buttons, pointer hit testing, dialogs, safe-area
insets and keyboard bounds use the same transform. There are no phone-width
tiers for this scale. Device pixel ratio is adjusted for terrain raster caches;
the board is not flattened into a scaled screenshot. OS text scaling remains
available, and menus can scroll when more space is needed.

LAN headers now occupy their own layout space. Scrolling controls cannot move
behind the back button or title. LAN action buttons have minimum rather than
fixed heights, allowing translated or enlarged labels to wrap.

## Verification

Automated coverage includes real TCP/WebSocket hosting on 7777, bare-IP joining,
busy-port refusal, custom-port parsing, preference persistence, seven new AI
economic/strategic cases, and existing multiplayer/diplomacy tests.

Responsive checks exercise home, new game, settings, LAN, port editing with a
keyboard, mod library, game HUD, pause and diplomacy. Menu sizes include
280×540, 320×568, 393×851, 600×960 and 844×390 with normal, 1.5× and 2× text.
The transform itself is checked at eight intermediate widths from 240 to 720,
including scaled pointer hits, insets and raster pixel ratio.

Representative captures are generated in `build/responsive-qa/`. This release
does not claim new physical-phone FPS measurements.

Release checks: the complete suite passed **596 tests**. After the final
width-and-height fit adjustment and LAN label spacing fix, all **25 LAN/UI
checks** passed again.
The full analyzer and the final viewport analysis reported no issues.
Android arm64 and web release builds succeeded. The Android package is
`kz.antiyoy.antiyoy_self`, version `1.0.4`, build `5`.
