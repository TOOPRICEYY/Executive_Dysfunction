#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const source = join(root, "Brand/Exports/Holdfast-AppIcon-1024.png");
const exportDirectory = join(root, "Brand/Exports/Variants");
const iosCatalog = join(root, "Sources/App/Assets.xcassets");
const macCatalog = join(root, "Sources/MacApp/Assets.xcassets");
const magick = process.env.MAGICK ?? "/opt/homebrew/bin/magick";

if (!existsSync(source)) throw new Error(`Missing source icon: ${source}`);
if (!existsSync(magick)) throw new Error(`ImageMagick was not found at ${magick}`);

const accents = {
  ThemeDefault: { light: "#FFD600", dark: "#47F229" },
  SignalYellow: { light: "#FFD600", dark: "#FFD600" },
  PhosphorGreen: { light: "#47F229", dark: "#47F229" },
  ElectricBlue: { light: "#1475FF", dark: "#1475FF" },
  WarningOrange: { light: "#FF7A00", dark: "#FF7A00" },
  HotMagenta: { light: "#FF3DA3", dark: "#FF3DA3" },
  TerminalViolet: { light: "#A87DFF", dark: "#A87DFF" }
};

mkdirSync(exportDirectory, { recursive: true });
const scratch = mkdtempSync(join(tmpdir(), "holdfast-icon-variants-"));

function run(...arguments_) {
  execFileSync(magick, arguments_, { stdio: "inherit" });
}

function writeIOSIconSet(assetName, imagePath) {
  const directory = join(iosCatalog, `${assetName}.appiconset`);
  rmSync(directory, { recursive: true, force: true });
  mkdirSync(directory, { recursive: true });
  copyFileSync(imagePath, join(directory, "AppIcon-1024.png"));
  writeFileSync(join(directory, "Contents.json"), `${JSON.stringify({
    images: [{
      filename: "AppIcon-1024.png",
      idiom: "universal",
      platform: "ios",
      size: "1024x1024"
    }],
    info: { author: "xcode", version: 1 }
  }, null, 2)}\n`);
}

const iosPrimaryIconSizes = [20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180];

function writePrimaryIOSIconSet(imagePath) {
  const directory = join(iosCatalog, "AppIcon.appiconset");
  copyFileSync(imagePath, join(directory, "AppIcon-1024.png"));
  for (const size of iosPrimaryIconSizes) {
    run(imagePath, "-resize", `${size}x${size}`, join(directory, `AppIcon-${size}.png`));
  }
}

function writeMacImageSet(assetName, imagePath) {
  const directory = join(macCatalog, `${assetName}.imageset`);
  rmSync(directory, { recursive: true, force: true });
  mkdirSync(directory, { recursive: true });
  copyFileSync(imagePath, join(directory, "Holdfast-1024.png"));
  writeFileSync(join(directory, "Contents.json"), `${JSON.stringify({
    images: [{ filename: "Holdfast-1024.png", idiom: "universal", scale: "1x" }],
    info: { author: "xcode", version: 1 }
  }, null, 2)}\n`);
}

try {
  const accentMask = join(scratch, "accent-mask.png");
  const lightBase = join(scratch, "light-base.png");
  const darkBase = join(scratch, "dark-base.png");

  // A continuous blue-dominance mask preserves the route's antialiased edge.
  run(source, "-colorspace", "sRGB", "-fx", "max(0,min(1,(b-max(r,g)-0.06)*4.5))", accentMask);
  copyFileSync(source, lightBase);
  // Invert only the neutral mark: warm paper becomes near-black and the maze
  // becomes warm white. The colored route is composited back afterwards.
  run(source, "-negate", "-level", "3%,96%", darkBase);

  for (const [accentName, colors] of Object.entries(accents)) {
    for (const theme of ["Light", "Dark"]) {
      const assetName = `HoldfastIcon${theme}${accentName}`;
      const output = join(exportDirectory, `${assetName}.png`);
      const color = theme === "Dark" ? colors.dark : colors.light;
      const base = theme === "Dark" ? darkBase : lightBase;
      run(base, "-size", "1024x1024", `xc:${color}`, accentMask, "-composite", output);
      writeIOSIconSet(assetName, output);
      writeMacImageSet(assetName, output);
      // The primary AppIcon has to hold the default variant. When it does not,
      // a fresh install shows one icon and the app immediately replaces it with
      // another, which iOS reports to the user as an icon change.
      if (assetName === "HoldfastIconLightThemeDefault") {
        writePrimaryIOSIconSet(output);
      }
    }
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log(`Generated ${Object.keys(accents).length * 2} adaptive Holdfast icon variants.`);
