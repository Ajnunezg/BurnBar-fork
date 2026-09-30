/**
 * Tenant identities shared by the BOLA harness and its generated victim seeds.
 * A leaf module so bolaVictimSeeds.generated.ts need not import the harness
 * that imports it (dependency-cruiser no-circular).
 */
export const ALICE_UID = "alice-bola-uid";
export const BOB_UID = "bob-bola-uid";
