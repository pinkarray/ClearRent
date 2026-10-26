import {HttpsError} from "firebase-functions/v2/https";

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
