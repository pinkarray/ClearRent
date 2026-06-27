/**
 * One-shot script to bootstrap the superAdmin custom claim on a single user.
 *
 * Usage:
 *   1. Place serviceAccountKey.json in functions/ (gitignored).
 *   2. From functions/, run:
 *        SUPER_ADMIN_UID=<your-uid> npx ts-node scripts/bootstrap-superadmin.ts
 *   3. Sign out of the admin webapp and sign back in to pick up the claim.
 *
 * Idempotent — re-running on the same UID is a no-op.
 * The UID is read from an env var so it never appears in source.
 */

import {initializeApp, cert} from "firebase-admin/app";
import {getAuth} from "firebase-admin/auth";
import * as path from "path";

const KEY_PATH = path.resolve(__dirname, "../serviceAccountKey.json");

async function main(): Promise<void> {
  const uid = process.env.SUPER_ADMIN_UID;
  if (!uid || uid.trim().length === 0) {
    console.error("ERROR: SUPER_ADMIN_UID env var is required.");
    console.error(
      "Run: SUPER_ADMIN_UID=<uid> npx ts-node scripts/bootstrap-superadmin.ts",
    );
    process.exit(1);
  }

  initializeApp({credential: cert(KEY_PATH)});
  const auth = getAuth();

  // Read existing claims and merge — don't clobber anything Firebase
  // Auth may have set (e.g. provider-specific metadata).
  const user = await auth.getUser(uid);
  const existing = user.customClaims ?? {};

  if (existing.superAdmin === true) {
    console.log(`User ${uid} already has superAdmin claim. No-op.`);
    return;
  }

  await auth.setCustomUserClaims(uid, {
    ...existing,
    superAdmin: true,
  });

  console.log(`✓ superAdmin claim set on ${uid}.`);
  console.log(
    "  Sign out and back in on the admin webapp for the claim to take effect.",
  );
}

main().catch((err) => {
  console.error("Bootstrap failed:", err);
  process.exit(1);
});