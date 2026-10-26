import {HttpsError} from "firebase-functions/v2/https";
import {getFirestore} from "firebase-admin/firestore";

/**
 * Furnished stays: 1 to 11 months, paid up front, at a monthly rent. The
 * tenant picks the length (within the landlord's range) and the start date
 * when they say they want the place. Dates are Lagos calendar days, held as
 * "yyyy-mm-dd" so month arithmetic never drifts across the UTC boundary.
 */

const LAGOS_OFFSET_MS = 60 * 60 * 1000; // WAT, no daylight saving
/** How far ahead a tenant may book a start. */
export const MAX_START_AHEAD_DAYS = 90;

export interface StayChoice {
  months: number;
  /** Lagos calendar day, "yyyy-mm-dd". */
  startDay: string;
}

/**
 * The Lagos calendar day an instant falls on.
 * @param {Date} at The instant.
 * @return {string} "yyyy-mm-dd".
 */
export function lagosDay(at: Date): string {
  return new Date(at.getTime() + LAGOS_OFFSET_MS).toISOString().slice(0, 10);
}

/**
 * Midnight in Lagos at the start of a day.
 * @param {string} day "yyyy-mm-dd".
 * @return {Date} That instant.
 */
export function lagosMidnight(day: string): Date {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d) - LAGOS_OFFSET_MS);
}

/**
 * The day a stay of `months` starting on `startDay` ends: the same day-of-month
 * that many months on, clamped to the month's last day (31 Jan + 1 = 28/29
 * Feb).
 * @param {string} startDay "yyyy-mm-dd".
 * @param {number} months Length of the stay.
 * @return {string} The end day, "yyyy-mm-dd".
 */
export function stayEndDay(startDay: string, months: number): string {
  const [y, m, d] = startDay.split("-").map(Number);
  const firstOfEnd = new Date(Date.UTC(y, m - 1 + months, 1));
  const lastDay = new Date(Date.UTC(
    firstOfEnd.getUTCFullYear(), firstOfEnd.getUTCMonth() + 1, 0,
  )).getUTCDate();
  firstOfEnd.setUTCDate(Math.min(d, lastDay));
  return firstOfEnd.toISOString().slice(0, 10);
}

/**
 * A day as people read it: "1 Dec 2026".
 * @param {string} day "yyyy-mm-dd".
 * @return {string} The readable day.
 */
function readableDay(day: string): string {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString("en-GB", {
    day: "numeric", month: "short", year: "numeric", timeZone: "UTC",
  });
}

/**
 * Whether a string is a real calendar day (rejects 2026-02-30).
 * @param {string} day Candidate "yyyy-mm-dd".
 * @return {boolean} True when it names a real day.
 */
function isRealDay(day: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) return false;
  const [y, m, d] = day.split("-").map(Number);
  const t = new Date(Date.UTC(y, m - 1, d));
  return t.getUTCFullYear() === y && t.getUTCMonth() === m - 1 &&
    t.getUTCDate() === d;
}

/**
 * Validates the tenant's choice against the listing. Throws the message the
 * tenant sees; firestore.rules already pins min/max to 1..11 on the listing.
 * @param {object} input The tenant's stayMonths and stayStartDate.
 * @param {object} prop The listing.
 * @param {Date} now Injected for tests.
 * @return {StayChoice} The validated choice.
 */
export function parseStayChoice(
  input: {stayMonths?: unknown; stayStartDate?: unknown},
  prop: {
    minStayMonths?: unknown;
    maxStayMonths?: unknown;
    availableFrom?: unknown;
  },
  now: Date = new Date(),
): StayChoice {
  const min = typeof prop.minStayMonths === "number" ? prop.minStayMonths : 1;
  const max = typeof prop.maxStayMonths === "number" ? prop.maxStayMonths : 11;
  const months = input.stayMonths;
  if (
    typeof months !== "number" || !Number.isInteger(months) ||
    months < min || months > max
  ) {
    throw new HttpsError(
      "invalid-argument",
      `Choose a stay of ${min} to ${max} months.`,
    );
  }

  const startDay = input.stayStartDate;
  if (typeof startDay !== "string" || !isRealDay(startDay)) {
    throw new HttpsError("invalid-argument", "Choose the day you move in.");
  }
  const today = lagosDay(now);
  const from = prop.availableFrom as {toDate?: () => Date} | undefined;
  const availableDay = from && typeof from.toDate === "function" ?
    lagosDay(from.toDate()) :
    today;
  const earliest = availableDay > today ? availableDay : today;
  if (startDay < earliest) {
    throw new HttpsError(
      "invalid-argument",
      earliest === today ?
        "The move-in day cannot be in the past." :
        `This place is available from ${readableDay(earliest)}.`,
    );
  }
  const latest = lagosDay(
    new Date(lagosMidnight(earliest).getTime() + MAX_START_AHEAD_DAYS * 864e5),
  );
  if (startDay > latest) {
    throw new HttpsError(
      "invalid-argument",
      `Choose a move-in day within ${MAX_START_AHEAD_DAYS} days.`,
    );
  }
  return {months, startDay};
}

/**
 * The longest stay the listing allows now. A landlord may lower it later;
 * extension follows the listing, as booking did.
 * @param {unknown} propertyId The rental's propertyId.
 * @return {Promise<number>} Months, 11 when unknown.
 */
export async function listingMaxStay(propertyId: unknown): Promise<number> {
  if (typeof propertyId !== "string" || !propertyId) return 11;
  const p = await getFirestore().collection("properties").doc(propertyId).get();
  const max = p.get("maxStayMonths");
  return typeof max === "number" ? max : 11;
}

/** Statuses a furnished stay can still be extended from. */
const EXTENDABLE = new Set(["active", "expiring_soon"]);

/**
 * The rent for extending a furnished stay by `months`, or the reason it cannot
 * be extended. The deal fee was paid once, with the booking; the tenant also
 * pays pricing.extensionFee on top, which callers add. Used by pricing (to
 * charge) and by completeStayExtension (to check the charge).
 * @param {FirebaseFirestore.DocumentData} r The active_rentals document.
 * @param {number} maxStay The listing's longest stay, in months.
 * @param {unknown} months How many months the tenant asked to add.
 * @param {Date} now Injected for tests.
 * @return {number} The amount to charge, in naira.
 */
export function extensionAmount(
  r: FirebaseFirestore.DocumentData,
  maxStay: number,
  months: unknown,
  now: Date = new Date(),
): number {
  if (r.stayType !== "furnished") {
    throw new HttpsError(
      "failed-precondition",
      "Only a furnished stay can be extended.",
    );
  }
  const end = (r.leaseEndDate as {toDate?: () => Date} | undefined)
    ?.toDate?.();
  if (!EXTENDABLE.has(r.status) || !end || end.getTime() <= now.getTime()) {
    throw new HttpsError(
      "failed-precondition",
      "This stay has ended, so it can no longer be extended.",
    );
  }
  const current = typeof r.stayMonths === "number" ? r.stayMonths : 0;
  const room = Math.max(0, maxStay - current);
  if (
    typeof months !== "number" || !Number.isInteger(months) ||
    months < 1 || months > room
  ) {
    throw new HttpsError(
      "invalid-argument",
      room === 0 ?
        "This stay is already as long as the landlord allows." :
        `You can extend by 1 to ${room} more month${room === 1 ? "" : "s"}.`,
    );
  }
  const monthly = typeof r.monthlyRent === "number" ? r.monthlyRent : 0;
  if (!(monthly > 0)) {
    throw new HttpsError(
      "failed-precondition",
      "This stay has no monthly rent recorded. Contact support.",
    );
  }
  return monthly * months;
}
