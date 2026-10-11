# Icon layers (for Icon Composer / Liquid Glass)

iOS 26 icons can be layered so the system adds Liquid Glass depth, highlights and the
dark, tinted and clear variants. Open Icon Composer (Xcode › Open Developer Tool), create a
new icon and add these, back to front:

1. `1-background.svg`: the night background with its pink glow. Fills the canvas; the system masks it.
2. `2-ribbon-back.svg`: the W's two up-strokes (shaded, the last one fading). Glass on.
3. `3-ribbon-front.svg`: the W's two down-strokes in white. Glass and specular on; keep it the top layer.

Save as `AppIcon.icon` in `WSLCRM/Resources/`. The flat `AppIcon.appiconset` (with its dark
and tinted images) stays as the fallback for iOS 17 and 18.
