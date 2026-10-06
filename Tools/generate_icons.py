import json, os, shutil, sys
# Regenerates the per-tint app icons from the layers in AppIcon.icon/Assets.
# Usage: python3 Tools/generate_icons.py Screenloss/Resources
root = sys.argv[1]
tints = {  # mirrors AppTint.color
    "Mint": (0.39, 0.89, 0.62), "Blue": (0.30, 0.62, 1.0), "Indigo": (0.55, 0.52, 1.0),
    "Yellow": (0.98, 0.82, 0.30),
}
layers = ["photo", "arrows"]  # back to front, each its own glass group
# The photo is a frosted plate the arrows sit on.
opacity = {"photo": 0.55, "arrows": 1.0}
translucency = {"photo": None, "arrows": None}
def p3(c): return "display-p3:%.5f,%.5f,%.5f,1.00000" % c
def light(c): return tuple(v + (1 - v) * 0.3 for v in c)
def dark(c, k): return tuple(v * k for v in c)
down = {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}
assets = os.path.join(root, "AppIcon.icon/Assets")
svgs = {name: open(os.path.join(assets, f"{name}.svg")).read() for name in layers}
for name, c in tints.items():
    bundle = os.path.join(root, "AppIcon.icon" if name == "Mint" else f"AppIcon-{name}.icon")
    if bundle != os.path.join(root, "AppIcon.icon"):
        shutil.rmtree(bundle, ignore_errors=True)
    os.makedirs(os.path.join(bundle, "Assets"), exist_ok=True)
    for layer, data in svgs.items():
        open(os.path.join(bundle, f"Assets/{layer}.svg"), "w").write(data)
    def group(layer):
        return {
            "layers": [{
                "fill-specializations": [
                    {"value": {"solid": p3((1, 1, 1))}},
                    {"appearance": "dark", "value": {"linear-gradient": [p3(light(c)), p3(dark(c, 0.85))], "orientation": down}},
                ],
                "glass": True, "hidden": False, "opacity": opacity[layer],
                "image-name": f"{layer}.svg", "name": layer,
                "position": {"scale": 6.6, "translation-in-points": [0, 0]},
            }],
            "shadow": {"kind": "neutral", "opacity": 0.2},
            "translucency": {"enabled": translucency[layer] is not None, "value": translucency[layer] or 0},
        }
    icon = {
        "fill-specializations": [
            {"value": {"linear-gradient": [p3(light(c)), p3(dark(c, 0.78))], "orientation": down}},
            {"appearance": "dark", "value": {"linear-gradient": [p3((0.18, 0.18, 0.19)), p3((0, 0, 0))], "orientation": down}},
        ],
        # Icon Composer lists groups front to back.
        "groups": [group(layer) for layer in reversed(layers)],
        "supported-platforms": {"squares": "shared"},
    }
    json.dump(icon, open(os.path.join(bundle, "icon.json"), "w"), indent=2)
    print(bundle)
