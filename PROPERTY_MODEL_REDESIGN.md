# Property Model Redesign — structure / unit / use

Status: **design only, nothing built.** Written 2026-07-31.
Trigger: storey buildings and commercial listings don't fit the current model.

---

## The problem

`propertyType` is a single string doing three unrelated jobs:

| Axis | Question it answers | Examples |
|---|---|---|
| **Structure** | What is the building, physically? | bungalow, storey building, block of flats |
| **Unit** | What is actually being let? | the whole building, one floor, a flat, a room |
| **Use** | What will it be used for? | home, office, shop, school, hospital |

The current list — `flat`, `duplex`, `selfContain`, `bungalow`, `room`, `shop`, `office` —
mixes all three axes into one choice, so several real situations cannot be expressed:

- **A two-storey building let whole, as a school or hospital.**
  Whole-building unit + institutional use. No type says this.
- **A flat on the 2nd floor, with the other half of the same building let as an office.**
  One building, two units, *two different uses*. A single type per listing cannot say it.
- **Which floor a unit is on.** There is no `floor` field anywhere in the codebase.
  In Lagos this is not cosmetic: no lift, water pressure at the top, security on the
  ground floor, an elderly tenant.

`shop` and `office` were the clearest symptom. They are **uses**, not types — putting them
on the same axis as `bungalow` is why a shop listing ends up with a bedroom counter.

## Current state (as of 2026-07-31)

- Type chips: `add_property_screen.dart` (details step) and `edit_property_screen.dart`.
- **`shop` / `office` chips are hidden** as of 2026-07-31. The type *values* are still
  handled in `_updateAutoTitle`, `_updateAutoDescription` and `property_card.dart`, so
  restoring the two chips is all that's needed to bring them back.
- Only those two generators ever branched on `shop`/`office`. Everything else assumed a
  home: the six counters in the details step are unconditional (Bedrooms, Bathrooms,
  Toilets, Living Room, Guest Room, Kitchen), `_amenitiesList` is residential (Wardrobe,
  Kitchen Cabinets, Water Heater, Swimming Pool), plus `maxTenants` and a yearly rent
  period.
- `BuildingModel` **already** groups N unit listings under one building with a single
  ownership document verified once for all of them. The structure needed for storey
  buildings and mixed use is already there — it is only under-described to landlords
  ("In a building / Shares one document" never says *"a flat in a storey building is
  you"*).

## Proposed model

**On the building** (`BuildingModel`):
- `structure` — `bungalow` | `storeyBuilding` | `blockOfFlats` | `compound` | `other`
- `totalFloors` — int, optional

**On the listing** (`PropertyModel`):
- `unitScope` — `wholeBuilding` | `floor` | `flat` | `room`
- `floor` — `ground` | `1` | `2` | `3`… (only meaningful when in a building)
- `use` — `residential` | `office` | `shop` | `school` | `hospital` | `otherCommercial`

`propertyType` stays for now as the residential *shape* (flat / duplex / selfContain /
bungalow / room) — meaningful only when `use == residential`.

The details step then branches on **`use`**, not on a flat type list.

### Field sets by use

**Residential** — unchanged: bedrooms, bathrooms, toilets, living rooms, guest rooms,
kitchens, residential amenities.

**Commercial / institutional** — replaces the counters:
- **floor area (sq m)** — the single most important number, not captured anywhere today
- toilets
- open-plan vs partitioned
- commercial amenities: 3-phase power, parking / loading access, security, water
- service charge as its own field
- lease terms: commercial lets in Nigeria are often multi-year upfront, not the yearly
  assumption baked into the current pricing step

## Migration

Post-wipe there are **zero** properties, so there is no back-fill. Defaults for any future
legacy doc: `use = residential`, `unitScope = flat`, `floor = null`.

## Sale is a separate product — deliberately out of scope

The whole spine is rental: inspection fee → rent → tenancy → renewal → move-out → caution
deposit, with Paystack split settlement built around rent.

A sale shares only the *listing* and the *inspection*. It has no tenancy, no move-out, no
rent, no caution deposit; it does have offers and negotiation, title search, a lawyer or
escrow, Land Registry transfer, and sums perhaps 50× a year's rent — which changes the
fraud exposure completely. It is not a `forSale` flag; it is a second product.

**Minimum viable version, if wanted early:** listing intent `forSale` → **enquiry only, no
money through the platform.** Captures the listings and the demand, buyer contacts the
landlord, nothing touches the payment flow. Roughly 10% of the work and none of the risk.
The full transaction is a post-launch decision, ideally with a lawyer involved.

## Touch points when this is built

- `lib/shared/models/property_model.dart`, `lib/shared/models/building_model.dart`
- `lib/features/landlord/presentation/screens/add_property_screen.dart` (details step,
  grouping section, preview), `edit_property_screen.dart`
- `lib/features/property/presentation/screens/property_detail_screen.dart` (feature row)
- `lib/features/property/presentation/widgets/property_card.dart` (icons, beds/baths line)
- Tenant search/filters, admin dashboard listing views
- `firestore.rules` field allowlists

## Open questions

1. Does a whole-building letting need its own inspection framing (an agent inspecting a
   school is not walking a flat)?
2. Does commercial change the inspection **fee** model? `InspectionPricing` is
   transport-cluster based and use-agnostic today.
3. Should `use` be visible in tenant search as a filter, or does commercial belong in a
   separate browse surface entirely?
