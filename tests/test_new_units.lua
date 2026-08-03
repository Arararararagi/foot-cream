-- tests/test_new_units.lua — the newly added units: carat (with the gold-
-- fineness guard), ton (with the figurative/tonnage classifier), verst/arshin/
-- pood (Russian), and gill.

local T = require("run")

-- ── Carat ───────────────────────────────────────────────────────────────────
T("two carats -> 0.4 g", function()
    assert_conv("The ring held two carats of diamonds.", "two carats", "= 0.4 g")
end)

T("a three-carat diamond -> 0.6 g", function()
    assert_conv("She wore a three-carat diamond.", "three-carat", "= 0.6 g")
end)

T("24 carat gold is fineness, not weight", function()
    assert_no_match("The chain was 24 carat gold.", "24 carat")
end)

T("karat (with a k) is never a unit", function()
    assert_no_match("It was eighteen-karat gold.", "eighteen-karat")
end)

-- ── Ton ─────────────────────────────────────────────────────────────────────
T("ten tons (US) -> 9 000 kg", function()
    assert_conv("The truck carried ten tons of coal.", "ten tons", "= 9 000 kg")
end)

T("ten tons (UK) -> 10 000 kg", function()
    assert_conv("The truck carried ten tons of coal.", "ten tons", "= 10 000 kg",
        { uk_volumes = true, language = "en-GB" })
end)

T("two tons of fun is figurative (no conversion)", function()
    assert_no_match("We had two tons of fun at the party.", "two tons")
end)

T("a hundred tons of paperwork is figurative (no conversion)", function()
    assert_no_match("There was a hundred tons of paperwork.", "hundred tons")
end)

T("registered tonnage is not a weight (no conversion)", function()
    assert_no_match("The ship had a displacement of forty tons.", "forty tons")
end)

-- ── Russian units ───────────────────────────────────────────────────────────
T("a hundred versts -> 110 km", function()
    assert_conv("They traveled a hundred versts.", "hundred versts", "= 110 km")
end)

T("three arshins -> 2.1 m", function()
    assert_conv("The cloth measured three arshins.", "three arshins", "= 2.1 m")
end)

T("five poods -> 80 kg", function()
    assert_conv("The merchant sold five poods of flour.", "five poods", "= 80 kg")
end)

-- ── Gill ────────────────────────────────────────────────────────────────────
T("two gills (US) -> 0.2 liters", function()
    assert_conv("He drank two gills of ale.", "two gills", "= 0.2 liters")
end)

T("two gills (UK) -> 0.3 liters", function()
    assert_conv("He drank two gills of ale.", "two gills", "= 0.3 liters",
        { uk_volumes = true, language = "en-GB" })
end)
