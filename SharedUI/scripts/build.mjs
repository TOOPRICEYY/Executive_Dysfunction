import { context } from "esbuild";
import { mkdir, copyFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
const root = new URL("../", import.meta.url);
process.chdir(fileURLToPath(root));
await mkdir("dist", { recursive: true });
await copyFile("index.html", "dist/index.html");
await copyFile("node_modules/react/LICENSE", "dist/React-LICENSE.txt");
await copyFile("node_modules/react-dom/LICENSE", "dist/ReactDOM-LICENSE.txt");
await copyFile("node_modules/@phosphor-icons/react/LICENSE", "dist/Phosphor-LICENSE.txt");
const ctx = await context({
  entryPoints: ["src/main.tsx"],
  bundle: true,
  outfile: "dist/app.js",
  format: "iife",
  target: ["safari16", "chrome109"],
  minify: !process.argv.includes("--serve"),
  sourcemap: false,
  define: { "process.env.NODE_ENV": '"production"' },
});
await ctx.rebuild();
if (process.argv.includes("--serve")) {
  await ctx.watch();
  const { port } = await ctx.serve({
    servedir: "dist",
    host: "127.0.0.1",
    port: 4173,
  });
  console.log(
    `Shared Holdfast UI: http://127.0.0.1:${port}/?preview=1 (no enforcement)`,
  );
} else {
  await ctx.dispose();
}
