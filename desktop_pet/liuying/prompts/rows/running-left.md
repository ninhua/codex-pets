Create one horizontal animation strip for Codex pet `liuying`, state `running-left`.

Use the attached canonical base for identity. Use the attached layout guide only for slot count, spacing, centering, and padding; do not draw the guide.

Output exactly 8 full-body frames in one left-to-right row on flat pure green #00FF00. Treat the row as 8 invisible equal-width slots: one centered complete pose per slot, evenly spaced, with no overlap, clipping, empty slots, labels, or borders.

Identity: same pet in every frame: Use all five uploaded references for character identity only. Preserve silver-white hair with pale lavender shadows, long flowing side ponytail, soft loose strands, black headband with small angular teal ornament, translucent teal leaf hair accessory on one side, small black ribbon bow, large dreamy cyan-pink-violet-blue gradient eyes, warm gentle smile, compact elegant chibi full body. Outfit: refined black and white fantasy academy uniform, dark cropped jacket, gold buttons and tiny gold trim, white ruffled collar, black ribbon tie, bright teal pendant-like chest strips, layered dark skirt or dress shape, white frill edges, teal accent details. Do not copy backgrounds, mecha, city, fireworks, sparkles, watermarks, UID text, other characters, scenery, logos, UI, shadows, glow, motion blur, or detached effects.. Preserve silhouette, face, proportions, markings, palette, material, style, and props.
Style: Pet-safe sprite: compact full-body mascot, readable in a 192x208 cell, clear silhouette, simple face, stable palette/materials, and crisp edges for chroma-key extraction. Style `auto`: Infer the most appropriate pet-safe style from the user request and reference images, then keep that exact style consistent across every row. User style notes: High-quality anime chibi desktop pet sprite, soft cel shading, polished game mascot style, clean line art, oversized head and tiny body, readable compact silhouette, centered full-body poses inside 192x208 cells, flat removable chroma-key background, transparent-background-ready..
Animation continuity: keep apparent pet scale and baseline stable within the row unless the state itself intentionally changes vertical position, such as `jumping`. Move the pose within the slot instead of redrawing the pet larger or smaller frame to frame.

State action: Dragging-left loop: show directional movement to the left through body and limb poses only.

State requirements:
- Show directional drag movement to the left through body, limb, and prop movement only.
- The row must unmistakably face and travel left.
- The movement cadence must alternate visibly across the 8 frames instead of repeating one nearly static stride.
- Do not draw speed lines, dust clouds, floor shadows, motion trails, or detached motion effects.

Clean extraction: crisp opaque edges, safe padding, no scenery, text, guide marks, checkerboard, shadows, glows, motion blur, speed lines, dust, detached effects, stray pixels, or chroma-key colors inside the pet.
