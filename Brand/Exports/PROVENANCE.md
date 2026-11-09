# Holdfast icon exports

The selected **Escaping Path Labyrinth** identity uses a single-path labyrinth with one river-blue route beginning at the center and escaping beyond the boundary. It represents movement through complexity without dead ends, with the blue path communicating regained direction.

The source labyrinth was preserved exactly. The route uses vivid sRGB blue `#168BFF` and was computed from the thresholded open corridor before being composited deterministically. It uses a constant fourteen-analysis-pixel width—the widest uniform stroke that clears the route's narrowest bottleneck—with a 23.1-analysis-pixel-radius dot centered on the interior terminal point. After composition, the complete mark was rotated 180 degrees, enlarged uniformly to 110%, and mirrored horizontally; applying those transforms to the maze and route together preserves their registration. The saved verification report confirms one unbranched route, exactly two endpoints, and zero black-wall intersections before the topology-preserving whole-mark transforms.

The verified source was produced on 2026-08-14. The production master was normalized to an opaque 1024×1024 sRGB PNG, then resized deterministically with ImageMagick for each platform slot. Apple assets contain no pre-applied corner mask; iOS and macOS apply their own presentation treatment. The Windows ICO embeds 16, 32, 48, 64, 128, and 256 pixel representations.

Fourteen adaptive Apple variants are generated reproducibly by `Scripts/generate-holdfast-icon-variants.mjs`: seven highlight choices in light and dark modes. The highlight transformation changes only the escaping route, including its antialiased edge. Dark mode inverts the neutral paper-and-maze treatment while compositing the selected route color back unchanged. macOS selects these variants for the running application/Dock icon; iOS registers them as alternate app icons.

`manifest.json` records the source, export locations, dimensions, and SHA-256 checksums for the master and Windows icon.
