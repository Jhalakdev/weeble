import { randomBytes } from 'node:crypto';

const ENCODING = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

// Minimal ULID generator — 26-char Crockford base32, time-sortable.
export function ulid() {
  const time = Date.now();
  const rand = randomBytes(10);
  let out = '';

  // 48-bit timestamp → 10 chars
  let t = time;
  for (let i = 9; i >= 0; i--) {
    out = ENCODING[t % 32] + out;
    t = Math.floor(t / 32);
  }

  // 80-bit randomness → 16 chars
  let randStr = '';
  for (let i = 0; i < 10; i++) {
    randStr += ENCODING[rand[i] % 32];
  }
  // Pad to 16 chars with extra randomness derived from the bytes
  while (randStr.length < 16) {
    randStr += ENCODING[randomBytes(1)[0] % 32];
  }
  return out + randStr.slice(0, 16);
}

export function urlSafeToken(bytes = 24) {
  return randomBytes(bytes).toString('base64url');
}
