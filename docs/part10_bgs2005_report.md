# Part 10: BGS2005 transformation - read-only report

Read-only report on `addons/features/auto_survey/bgs2005_transformer.py`'s
ITRF2020→BGS2005 transform chain: independent re-verification of its
Helmert parameters, a quantified look at the ~5cm residual's epoch
component, and fix options. No code changes.

## 1. Helmert parameters - independently re-verified

The module's own docstring (written in an earlier session with no live
internet access) flags its parameters as unverified against official
registries in real time, asking that any drift >10cm trigger re-checking
them first. This session has live web access; both pipeline steps were
re-checked against current official sources.

### Step 1: ITRF2020 → ITRF2014

Fetched from IGN's own transformation page
(<https://itrf.ign.fr/en/solutions/transformations>), epoch 2015.0:

| | Code | Published (IGN) | Units |
|---|---|---|---|
| T1 | `x=-0.0014` | -1.4 | mm |
| T2 | `y=-0.0009` | -0.9 | mm |
| T3 | `z=0.0014` | 1.4 | mm |
| D | `s=-0.00042` | -0.42 | ×10⁻⁹ |
| dT2 | `dy=-0.0001` | -0.1 | mm/yr |
| dT3 | `dz=0.0002` | 0.2 | mm/yr |
| R1/R2/R3 | `rx=ry=rz=0` | 0.00 | mas |

**Exact match**, every component.

### Step 2: ITRF2014 → ETRF2014

Confirmed via EPSG:8407 / EUREF Technical Note 1, epoch 2010.0:

| | Code | Published | Units |
|---|---|---|---|
| R1 | `rx=0.001785` | 1.785 | mas |
| R2 | `ry=0.011151` | 11.151 | mas |
| R3 | `rz=-0.01617` | -16.170 | mas |
| dR1 | `drx=0.000085` | 0.085 | mas/yr |
| dR2 | `dry=0.000531` | 0.531 | mas/yr |
| dR3 | `drz=-0.00077` | -0.770 | mas/yr |

**Exact match** (PROJ's `+rx/+ry/+rz` are arcseconds; 1 mas = 0.001
arcsec, confirmed consistent with the code's values).

### Output CRS: EPSG:9391

Confirmed via epsg.io: "BGS2005 / UTM zone 35N", base CRS BGS2005
(EPSG:7798), extent "Bulgaria - onshore east of 24°E" - distinct from
the generic UTM 35N (EPSG:32635/25835), using the Bulgarian national
datum. Matches the module's own claim exactly.

**Conclusion: no drift found. Both Helmert steps and the output CRS
code are correct as currently coded**, independently re-verified
against IGN, EPSG/EUREF, and epsg.io.

## 2. Epoch handling - architecture check

`extract_observation_epoch()` computes the mean of a RINEX file's own
`TIME OF FIRST OBS`/`TIME OF LAST OBS` header lines (the actual
observation midpoint, not "now" or any fixed value), converts to decimal
year, and passes it as `t_obs` into `itrf2020_to_bgs2005()`. Both Helmert
steps are applied with this SAME `t_obs` in one `pipeline.transform()`
call - each step's own `t_epoch` (2015.0, then 2010) is its reference
baseline for rate extrapolation; `t_obs` is what the rates get
extrapolated TO. This is the architecturally correct way to apply a
rate-dependent (14/15-parameter) Helmert chain, and the call site
(`survey_controller.py:1434-1445`) correctly derives `t_obs` from the
SAME `obs_file` the position came from, not a hardcoded or
processing-time value. **No issue found here.**

## 3. The ~5cm residual - a quantified epoch-gap hypothesis

The module's docstring attributes the confirmed ~4.6-5.7cm residual
(against a real RTK measurement, cross-checked against three independent
parameter sources) to "RTK accuracy + a known difference between the
generic EUREF model and BGS2005's specific national realization/
densification grid." That explanation is plausible but non-quantified.

**A second, independently confirmable factor exists and is quantifiable:
BGS2005 is defined at a FIXED epoch, not the observation epoch.**

Per Инструкция № РД-02-20-12 (БГС2005's own defining instruction) and
independently confirmed via search: BGS2005 realizes ETRS89 with
reference coordinates fixed at **epoch 2005.0**. АГКК's own BGSTrans
software description (independently confirmed) states it transforms via
a 10,000-control-point correction grid, achieving cm-to-dm accuracy -
consistent with the module's own 473-point/BGSTrans claim, but says
nothing about re-projecting a NEW observation to BGS2005's own epoch
first.

This project's transform chain does the opposite: it extrapolates
ITRF2020/ITRF2014/ETRF2014 rates forward to `t_obs` (today's survey
date, e.g. 2026.6-2026.8), then outputs that as if it were already a
BGS2005 (epoch-2005.0) coordinate. **The gap between 2005.0 and `t_obs`
is roughly 21.6-21.8 years as of this report** (and grows every year a
station re-surveys) - any real intraplate motion the point has
accumulated over that span, in the EUREF/ETRF frame, is never removed;
it rides straight into the broadcast coordinate as a systematic offset
that looks identical to a transformation error.

**Magnitude estimate.** Independently confirmed via search: Bulgarian
GNSS/EPN station horizontal velocities in ETRF2000/ETRF2014 range
**~0.2-3.8 mm/year**, consistent across several independent geodynamics
studies of the Balkan Peninsula (Vassileva 2013 and related FIG/EPN
analyses). One of those sources reported SOFI specifically at
approximately 2.0 mm/yr horizontal (components roughly -2.0mm/yr
north, +0.4mm/yr east) - **this specific SOFI figure could not be
re-confirmed against EUREF's own primary velocity page in this session
(blocked by a 403) or against the original 2013 paper directly (not
reachable), so treat it as indicative, not confirmed**; the 0.2-3.8
mm/yr RANGE itself is corroborated across multiple independent sources
and is the figure this estimate actually relies on.

Taking the station's apparent velocity as within that confirmed range
(0.2-3.8 mm/yr) and a ~21.7-year epoch gap:

```
displacement = velocity × Δt
            = (0.2 to 3.8) mm/yr × 21.7 yr
            = 4.3 mm  to  82.5 mm
            ≈ 0.4 cm  to  8.3 cm
```

**This range comfortably brackets the confirmed ~4.6-5.7cm residual.**
A station near the middle-to-upper end of the confirmed Bulgarian
velocity range (roughly 2-3 mm/yr, consistent with the ~2mm/yr figure
found for SOFI, even unconfirmed) would accumulate **~4.3-6.5cm** over
21.7 years - squarely inside the observed residual.

**This does not prove the epoch gap is THE explanation** - it is one
candidate, consistent in magnitude, not independently separated from
the RTK-accuracy/generic-grid factors the module's docstring already
names. But it is the only one of the three explanations that is
directly quantifiable from this project's own code (the actual `t_obs`
used, every update) and independently-published velocity data, and its
estimated magnitude alone is sufficient to explain the entire observed
residual without needing RTK error or grid-densification differences to
contribute much at all. It deserves to be checked first, not assumed
away.

## 4. Fix options (report only - no code changes made)

**Option A: propagate to epoch 2005.0 before transforming.**
Add a THIRD step to the pipeline: after ITRF2014→ETRF2014 (which is
itself already epoch-dependent via its own rates), apply the station's
own intraplate velocity (N/E/U, mm/yr) to move the point from `t_obs`
back to 2005.0, using either:
  - A regional/plate velocity model (e.g. a published Eurasian-plate
    intraplate field, or Bulgaria's own crustal velocity studies cited
    above) - approximate, no local measurement needed, but only as good
    as the model's resolution for this specific point.
  - A locally-estimated velocity, if this station (or a nearby EPN
    station) has multi-year position time series to fit a rate from -
    more accurate for THIS point specifically, but needs that history to
    already exist.
  Data needed: a velocity field/model file (N/E/U mm/yr, gridded or
  per-station) plus a fourth Helmert-pipeline step (or a direct ENU
  rate application, same technique Part 6a's `arp_to_marker()` already
  uses for a conceptually similar local-frame adjustment).

**Option B: apply АГКК's official BGSTrans/grid-based transform
directly**, instead of the three-step Helmert chain this module
currently implements. This is the one explicitly intended by Чл.22,
ал.1 and would, by construction, already include whatever epoch
handling and densification correction BGSTrans's own 10,000-point grid
applies - eliminating the residual at its root rather than
approximating around it. Data needed: either the BGSTrans software/grid
file itself (if АГКК publishes or licenses it for integration) or a
documented specification of its grid format precise enough to
reimplement the lookup/interpolation independently. This is almost
certainly the higher-effort option (an external grid dependency, or a
reverse-engineered format) but is the one most likely to make this
project's output directly traceable to the Инструкция's own reference
implementation rather than an independent approximation of it.

**Recommendation for next step (not a code change, a research task):**
confirm the SOFI (or a station near the installation site) velocity
figure against EUREF's own primary velocity solution (retry outside
this session's current access restrictions, or request the figure
directly from NIMH/EUREF), since that single number would turn this
section's estimate from "a plausible range" into "the actual number for
this specific residual."
