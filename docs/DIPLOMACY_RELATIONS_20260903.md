# Diplomacy refinement — 2026-09-03

## Reference and scope

The official repositories were inspected read-only, not modified:

- Classic `yiotro/Antiyoy`, commit `f22acaa0d08cc908b9d236bfabc28f93d059ad3e`: diplomatic transitions, friendship penalties and bot diplomacy.
- Online/HD `yiotro/antiyoy_hd`, commit `120bd3c60eef1eccdda583cd5d9d70b1c493e4f5`: `Letter`, `Condition`, `Relation`, `SceneComposeLetter`, `DiplomaticAiNormal`, `Appraiser`.

Online represents a letter as multiple conditions with an executor for each condition. Its AI constructs and appraises letters as a whole. This is the reference for independently directed exchange rows, not a claim of exact engine parity. See [official Letter source](https://github.com/yiotro/antiyoy_hd/blob/main/src/yio/tro/onliyoy/game/core_model/Letter.java) and [Classic diplomatic AI](https://github.com/yiotro/Antiyoy/blob/master/core/src/yio/tro/antiyoy/gameplay/diplomacy/DiplomaticAI.java).

The directed numeric opinion, three-row limit, military alliances and peace-conference integration are this mod's rules requested by the user. In particular, the inspected official `Relation` stores diplomatic status/lock, not this new numeric opinion system. There is no assertion that Online itself has an exact three-condition cap.

## Player-visible rules

- Every ordered pair has an opinion in `[-100,100]`, separate from neutral/friend/enemy/military-alliance status. Both directions and recent reasons appear in country information.
- An embassy costs $10 (expense, not a transfer), gives the recipient +12 opinion and the initiator +3. A protest gives −15/−5. The acting country has a three-round cooldown per target. Embassy visits require cash, no war and no black mark.
- Friendship and military commitments, betrayal, war, peace, black marks/removal, completed deals, actually paid aid/subsidies, unpaid subsidies and common enemies affect opinion. Ongoing friendship/war and gradual neutral drift update each round.
- AI requires at least +25 opinion for a military alliance. Human-to-human consent has no score gate. Legal truce, black-mark, coalition and active-campaign restrictions still apply to everyone. A friendly button sends a proposal; it does not unilaterally consent for another human.
- Ordinary peacetime AI can offer friendship, an alliance, cash aid, subsidies, emergency aid requests and bounded safe border-land purchases/sales. Six-round sender/recipient spacing and at most two outstanding proposals in a human inbox limit interruptions. AI values directions correctly, rejects unfunded promises as cash, preserves its last land, and does not use the obsolete all-friends-victory prevention policy.
- Up to three conditions per letter. Each arrow independently selects who gives/executes it, including all three in one direction. Only the active condition's details or picker expands. Incoming letters show every condition.
- All conditions are checked against one pre-contract state, then checked again on acceptance. Invalid/stale conditions cause no partial transfer. Land rows are combined for connectivity checks; duplicate land/naval assets, conflicting diplomatic transitions and conflicting friendship durations are rejected. Multiple initially legal war obligations may coexist.
- Existing Classic-compatible unfunded monetary promises still create debt. AI does not value that debt as immediate cash. Paid-aid and accepted-trade opinion rewards have separate saved once-per-pair-per-round guards, independent of the bounded recent-event list.
- Existing custom alliance safeguards are retained: real transit contributors, origin-paid guest/occupation armies, bloc wars, immutable active campaign/conference membership, frozen disputed pool, unanimous settlement/counteroffers, five-round fallback and ten-round postwar ban.

## UI and compatibility

Country information, black-mark confirmation, exchange and inbox letter details transition within their existing Classic panel using `AnimatedSwitcher` fade/slide; they do not push separate full-screen routes. Classic assets, compact text, colored bands and a single visible back arrow replace the affected generic/old surfaces. This is a Hero-like shared-panel transition, not a claim of using Flutter `Hero` itself. The `game-ui-frontend` skill guided that layout and preservation of visible map area.

Optional `diplomacySocial` and `DiplomacyProposal.terms` fields preserve legacy save/proposal loading. Strict import validates dimensions, score/cooldown ranges, event limits and condition syntax. Undo and authoritative LAN patches carry social state. LAN protocol is now **2**: host and clients must use the updated build, preventing an older client from interpreting a new three-condition letter as an empty legacy exchange. LAN acceptance compares the entire proposal payload, not just the sender/round, so a replaced letter cannot be accepted under old terms.

## Verification

- First complete suite: 297/297 passed before final hardening cases.
- Focused final social/UI/LAN suite: 33/33 passed, including 320×720, 390×844 and 1280×720 layouts, route-count assertions, all-one-way terms, human consent, bot variety, save/undo/patch round trips, reward-history eviction, matching friendship durations, two war obligations and stale LAN conditions.
- Updated and inspected four diplomacy goldens; two visual test cases passed.
- Final `flutter analyze`: no issues.
- Web release and Windows release builds succeeded.
- Browser smoke: loaded a saved giant 15-color match, opened country information, returned within the panel, inspected the black-mark panel, opened exchange and added the third condition. The `game-playtest` skill guided visible screenshot verification.

The logged full-suite rerun passed **302/302** in 2m44s (`build/diplomacy-final-tests.log`). One prior run concurrent with release compilation reported one failure, which did not recur; its cause was not established and no test thresholds were relaxed. The main game suite separately passed 139/139 and AI 14/14. After the final narrow fix preventing a new-friendship bonus when downgrading a military alliance, the social/alliance suite passed **47/47**.

The rebuilt browser page was reloaded and the country-information panel visibly verified with its correct back arrow. Browser warning/error log was empty. Final URL: `http://localhost:7357/?build=20260903-diplomacy-relations`.

## Useful future additions (not implemented)

1. A paid, fixed-duration non-aggression pact, distinct from friendship and military access.
2. Temporary port access/leases with explicit naval support costs and expiry behavior.
3. A defensive guarantee that triggers only when the protected state is attacked, unlike the current full military bloc.

These would each need contract expiry, AI appraisal, LAN and save tests before becoming selectable conditions.
