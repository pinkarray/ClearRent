/**
 * One-shot script to grant the `admin` custom claim to a user — the
 * out-of-band equivalent of the setAdminClaim callable, for when you'd
 * rather run it locally than through the admin webapp.
 *
 * Usage (from functions/, with serviceAccountKey.json present):
 *
 *   Grant admin to an EXISTING user (they've already signed into the
 *   admin webapp / app at least once):
 *     ADMIN_EMAIL=person@example.com npx ts-node scripts/set-admin.ts
 *
 *   Create the account first, then grant admin (person has no account yet
 *   and the admin webapp has no self-signup):
 *     ADMIN_EMAIL=person@example.com ADMIN_PASSWORD=TempPass123 \
 *       npx ts-node scripts/set-admin.ts
 *
 * Sets { admin: true, superAdmin: false } to mirror the setAdminClaim
 * callable, where the two claims are mutually exclusive. Idempotent.
 *
 * After running, the new admin must sign out and back in for the claim to
 * take effect (custom claims are baked into the ID token at sign-in).
 */

import {initializeApp, cert} from "firebase-admin/app";
import {getAuth, UserRecord} from "firebase-admin/auth";
import * as path from "path";

const KEY_PATH = path.resolve(__dirname, "../serviceAccountKey.json");

async function main(): Promise<void> {
  const email = process.env.ADMIN_EMAIL?.trim();
  const password = process.env.ADMIN_PASSWORD?.trim();

  if (!email) {
    console.error("ERROR: ADMIN_EMAIL env var is required.");
    console.error(
      "Run: ADMIN_EMAIL=<email> [ADMIN_PASSWORD=<pw>] " +
        "npx ts-node scripts/set-admin.ts",
    );
    process.exit(1);
  }

  initializeApp({credential: cert(KEY_PATH)});
  const auth = getAuth();

  // Find the user by email, or create them if a password was supplied.
  let user: UserRecord;
  try {
    user = await auth.getUserByEmail(email);
  } catch (err) {
    const code = (err as {code?: string}).code;
    if (code !== "auth/user-not-found") throw err;
    if (!password) {
      console.error(`ERROR: no user with email ${email}.`);
      console.error(
        "Either have them sign into the admin webapp once first, or " +
          "re-run with ADMIN_PASSWORD=<pw> to create the account.",
      );
      process.exit(1);
    }
    user = await auth.createUser({email, password, emailVerified: true});
    console.log(`✓ Created account for ${email} (uid ${user.uid}).`);
  }

  const existing = user.customClaims ?? {};

  // Safety: never silently demote a super admin through the admin script.
  if (existing.superAdmin === true) {
    console.error(
      `ERROR: ${email} (uid ${user.uid}) is a super admin. Refusing to ` +
        "overwrite that. Use setAdminClaim if you really mean to change it.",
    );
    process.exit(1);
  }

  if (existing.admin === true) {
    console.log(`User ${email} (uid ${user.uid}) is already an admin. No-op.`);
    return;
  }

  await auth.setCustomUserClaims(user.uid, {
    ...existing,
    admin: true,
    superAdmin: false,
  });

  console.log(`✓ admin claim set on ${email} (uid ${user.uid}).`);
  console.log(
    "  They must sign out and back in for the claim to take effect.",
  );
}

main().catch((err) => {
  console.error("set-admin failed:", err);
  process.exit(1);
});
