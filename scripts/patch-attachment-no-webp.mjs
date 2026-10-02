// attachment-local: never re-encode an image to WebP. Idempotent.
//
//   node patch-attachment-no-webp.mjs [path/to/attachment-local/lib/index.js]
//
// WHY. llama.cpp decodes images with stb_image, which has no WebP support. A
// request carrying one comes back as
//     400 {"code":400,"message":"Failed to load image or audio file"}
// and the whole turn fails - the image never reaches the model.
//
// The harness re-encodes an attachment whenever it cannot pass through
// untouched, and `canPassThroughNormalization` (normalization.ts:36) refuses
// pass-through for, among other things, ANY file carrying metadata. An ordinary
// screenshot does: the one that exposed this had `sRGB gAMA pHYs` chunks. The
// ladder then picks the codec purely by alpha:
//     const mediaType = hasAlpha ? 'image/webp' : 'image/jpeg'
// so every screenshot with an alpha channel - which is what a PNG screenshot
// normally is - became WebP and was refused by the model server. A JPEG
// screenshot, or a PNG without alpha, went through, which is why this looked
// intermittent rather than broken.
//
// WHAT THIS CHANGES. Alpha images are re-encoded as PNG instead of WebP. PNG is
// what the pass-through path already emits for the same pictures, keeps the
// alpha channel the surrounding code promises never to drop, and stb_image reads
// it. No `palette: true`: a paletted PNG is indexed colour, and the encoder's
// own check ("Encoded model-request image does not match its verified 8-bit sRGB
// metadata") rejects it. The quality ladder then yields the same bytes at every
// step, which costs nothing - the first fitting candidate is taken.
//
// Not a change to make upstream: WebP is the better format wherever the provider
// reads it. This is a local engine's limitation, so it is a local layer.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';

const path = process.argv[2]
  || `${process.env.DSH_ROOT ?? `${process.env.HOME}/tools/deepseek-harness`}/packages/attachment/attachment-local/lib/index.js`;

const MARK = '/* dsh-local: no webp for stb_image */';

let s = readFileSync(path, 'utf8');
if (s.includes(MARK)) { console.log('attachment: webp already avoided'); process.exit(0); }

const EDITS = [
  // 1. the codec choice
  [`\tconst mediaType = hasAlpha ? "image/webp" : "image/jpeg";`,
   `\tconst mediaType = hasAlpha ? "image/png" : "image/jpeg"; ${MARK}`],
  // 2. the encoder for that codec
  [`\tconst { data, info } = await (mediaType === "image/webp" ? pipeline.webp({\n\t\tquality,\n\t\teffort: 0\n\t}) : pipeline.jpeg({ quality })).toBuffer({ resolveWithObject: true });`,
   `\tconst { data, info } = await (mediaType === "image/png" ? pipeline.png({\n\t\tcompressionLevel: 9\n\t}) : mediaType === "image/webp" ? pipeline.webp({\n\t\tquality,\n\t\teffort: 0\n\t}) : pipeline.jpeg({ quality })).toBuffer({ resolveWithObject: true });`],
];

for (const [anchor, replacement] of EDITS) {
  const n = s.split(anchor).length - 1;
  if (n !== 1) {
    console.error(`${path}: MATCH COUNT ${n} for ${JSON.stringify(anchor.slice(0, 50))} - the harness changed, re-check before patching`);
    process.exit(1);
  }
  s = s.replace(anchor, replacement);
}

// Built output of the harness itself, not a pnpm hardlink; a plain write is
// right here, but unlinking first costs nothing and is what every sibling does.
rmSync(path, { force: true });
writeFileSync(path, s);
console.log(`${path}: alpha images re-encode as PNG, not WebP`);
